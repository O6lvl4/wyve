#lang racket/base
;; Execute kernels as LLVM: synthesize a C driver, compile driver + IR with
;; clang, run the binary. Inputs are deterministic; written buffers and
;; return values are printed so a .wyv file is directly runnable.
(require racket/match racket/string racket/system racket/file
         "ast.rkt" "sema.rkt" "talk.rkt")
(provide run-kernels)

(define (c-type t)
  (match t
    ['void "void"]
    ['float "float"]
    ['usize "size_t"]
    [(Ptr c? p) (format "~a~a*" (if c? "const " "") (c-type p))]))

(define (gen-driver kernels)
  (define o (open-output-string))
  (fprintf o "#include <stdio.h>\n#include <stdlib.h>\n\n")
  (for ([k (in-list kernels)])
    (define decl (kernel-decl k))
    (fprintf o "extern ~a ~a(~a);\n"
             (c-type (Sig-ret decl)) (kernel-symbol k)
             (string-join
              (for/list ([p (in-list (sig-params decl))])
                (format "~a ~a" (c-type (Param-ty p)) (Param-name p)))
              ", ")))
  (fprintf o "\nint main(void) {\n")
  (for ([k (in-list kernels)] [ki (in-naturals)])
    (gen-call o k ki))
  (fprintf o "  return 0;\n}\n")
  (get-output-string o))

(define (gen-call o k ki)
  (define decl (kernel-decl k))
  (define eff (Contracts-effect (Sig-contracts decl)))
  (define pfx (format "k~a_" ki))
  (fprintf o "  {\n")
  (fprintf o "    size_t n = 1024;\n")
  (define args
    (for/list ([p (in-list (sig-params decl))] [pi (in-naturals)])
      (match (Param-ty p)
        [(Ptr _ 'float)
         (define v (format "~a~a" pfx (Param-name p)))
         ;; every usize parameter receives n, so a kernel may address up to
         ;; n*n elements (2D row-major); allocate for the worst case
         (fprintf o "    float* ~a = malloc(n * n * sizeof(float));\n" v)
         (fprintf o "    for (size_t i = 0; i < n * n; i++) ~a[i] = (float)(i % n) * 0.5f + ~a.0f;\n" v pi)
         v]
        ['float "2.0f"]
        ['usize "n"])))
  (define call (format "~a(~a)" (kernel-symbol k) (string-join args ", ")))
  (cond
    [(eq? (Sig-ret decl) 'void)
     (fprintf o "    ~a;\n" call)]
    [else
     (fprintf o "    float ~ar = ~a;\n" pfx call)
     (fprintf o "    printf(\"~a -> %g\\n\", (double)~ar);\n" (kernel-symbol k) pfx)])
  ;; report written buffers
  (for ([p (in-list (sig-params decl))])
    (when (and (Ptr? (Param-ty p))
               (if eff
                   (member (Param-name p) (Effect-writes eff))
                   (not (Ptr-const? (Param-ty p)))))
      (define v (format "~a~a" pfx (Param-name p)))
      (fprintf o "    { double s = 0; for (size_t i = 0; i < n; i++) s += ~a[i];\n" v)
      (fprintf o "      printf(\"~a: ~a[0..3] = %g %g %g %g  checksum = %g\\n\",\n" (kernel-symbol k) (Param-name p))
      (fprintf o "             (double)~a[0], (double)~a[1], (double)~a[2], (double)~a[3], s); }\n" v v v v)))
  (for ([p (in-list (sig-params decl))])
    (when (Ptr? (Param-ty p))
      (fprintf o "    free((void*)~a~a);\n" pfx (Param-name p))))
  (fprintf o "  }\n"))

(define (run-kernels kernels ir)
  (define clang (find-clang))
  (define dir (build-path (find-system-path 'temp-dir)
                          (format "wyve-run-~a" (current-milliseconds))))
  (make-directory* dir)
  (define ll (build-path dir "kernels.ll"))
  (define drv (build-path dir "driver.c"))
  (define exe (build-path dir "a.out"))
  (display-to-file ir ll #:exists 'replace)
  (display-to-file (gen-driver kernels) drv #:exists 'replace)
  (define err-out (open-output-string))
  (define ok
    (parameterize ([current-error-port err-out])
      (system* clang "-O2" "-Wno-override-module"
               "-o" (path->string exe)
               (path->string drv) (path->string ll))))
  (unless ok
    (error 'wyve (format "clang failed to link the driver (a wyvec bug):\n~a" (get-output-string err-out))))
  ;; the child writes to the fd directly; flush Racket's buffered port first
  ;; so the conversation appears before the execution output
  (flush-output)
  (system* (path->string exe))
  (delete-directory/files dir #:must-exist? #f)
  (void))
