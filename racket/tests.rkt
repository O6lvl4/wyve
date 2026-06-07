#lang racket/base
;; The examples directory is normative, for this implementation too.
;; Offline checks only (talk/run need clang). Run from the repo root:
;;   racket racket/tests.rkt
(require racket/file racket/string "cli.rkt" "diag.rkt")

(define failures 0)
(define (expect! name ok?)
  (if ok?
      (printf "ok   ~a\n" name)
      (begin (set! failures (add1 failures)) (printf "FAIL ~a\n" name))))

(define (compile-file f)
  (compile-source (file->string f) f))

;; valid examples compile, with contracts visible in the IR
(for ([name (in-list '("saxpy" "reduce" "stencil" "live"))])
  (define f (format "examples/~a.wyv" name))
  (define-values (_mod _kernels ir diags) (compile-file f))
  (expect! (format "~a compiles" name) (null? diags))
  (when (null? diags)
    (expect! (format "~a IR has noalias" name) (string-contains? ir "noalias"))
    (expect! (format "~a IR has vectorize metadata" name)
             (string-contains? ir "llvm.loop.vectorize.enable"))
    (expect! (format "~a IR has width 8" name)
             (string-contains? ir "llvm.loop.vectorize.width\", i32 8"))))

;; reduce grants reassoc
(let-values ([(_m _k ir diags) (compile-file "examples/reduce.wyv")])
  (expect! "reduce IR has fadd reassoc" (and (null? diags) (string-contains? ir "fadd reassoc"))))

;; invalid examples are rejected with their documented codes
(let-values ([(_m _k _ir diags) (compile-file "examples/invalid/dependence.wyv")])
  (expect! "dependence rejected with WVN014"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN014")) diags)))
  (expect! "dependence message is canonical"
           (ormap (λ (d) (string-contains? (diag-msg d) "previous iteration")) diags)))

(let-values ([(_m _k _ir diags) (compile-file "examples/invalid/effect-violation.wyv")])
  (expect! "effect violation rejected with WVN003"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN003")) diags)))
  (expect! "effect message is canonical"
           (ormap (λ (d) (string-contains? (diag-msg d) "declares only reads(src)")) diags)))

(printf "~a\n" (if (zero? failures) "all tests passed" (format "~a FAILURES" failures)))
(exit (if (zero? failures) 0 1))
