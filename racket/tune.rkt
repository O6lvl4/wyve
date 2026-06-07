#lang racket/base
;; Schedule search — rung (c) of the north star: find schedules humans
;; didn't write. Sweeps the knob space (width x interleave, plus "LLVM
;; chooses"), compiles each variant, verifies it against the optimizer's
;; remarks, measures it, and suggests the winning contract.
(require racket/match racket/string racket/list racket/file racket/system
         racket/port racket/format
         "ast.rkt" "sema.rkt" "codegen.rkt" "rewrite.rkt" "talk.rkt" "diag.rkt")
(provide tune-module)

(define (silently thunk)
  (parameterize ([current-output-port (open-output-nowhere)]
                 [current-error-port (open-output-nowhere)])
    (thunk)))

;; ------------------------------------------------- timing driver synthesis

(define (c-type t)
  (match t
    ['void "void"]
    ['float "float"]
    ['usize "size_t"]
    [(Ptr c? p) (format "~a~a*" (if c? "const " "") (c-type p))]))

(define (gen-tune-driver k n batch meas)
  (define decl (kernel-decl k))
  (define o (open-output-string))
  (fprintf o "#include <stdio.h>\n#include <stdlib.h>\n#include <time.h>\n\n")
  (fprintf o "extern ~a ~a(~a);\n"
           (c-type (Sig-ret decl)) (kernel-symbol k)
           (string-join (for/list ([p (in-list (sig-params decl))])
                          (format "~a ~a" (c-type (Param-ty p)) (Param-name p)))
                        ", "))
  (fprintf o "static double now_ns(void){struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);return (double)ts.tv_sec*1e9+(double)ts.tv_nsec;}\n")
  (fprintf o "static volatile double sink;\n\n")
  (fprintf o "int main(void){\n  size_t n = ~a;\n" n)
  (define args
    (for/list ([p (in-list (sig-params decl))] [pi (in-naturals)])
      (match (Param-ty p)
        [(Ptr _ 'float)
         (define v (Param-name p))
         (fprintf o "  float* ~a = NULL; posix_memalign((void**)&~a, 64, n*sizeof(float));\n" v v)
         (fprintf o "  for (size_t i = 0; i < n; i++) ~a[i] = (float)i * 0.001f + ~a.0f;\n" v pi)
         v]
        ['float "1.0f"]
        ['usize "n"])))
  (define call (format "~a(~a)" (kernel-symbol k) (string-join args ", ")))
  (define stmt (if (eq? (Sig-ret decl) 'void)
                   (format "~a;" call)
                   (format "sink += ~a;" call)))
  (fprintf o "  for (int w = 0; w < 10; w++) { ~a }\n" stmt)
  (fprintf o "  double best = 1e30;\n")
  (fprintf o "  for (int m = 0; m < ~a; m++) {\n" meas)
  (fprintf o "    double t0 = now_ns();\n")
  (fprintf o "    for (int b = 0; b < ~a; b++) { ~a }\n" batch stmt)
  (fprintf o "    double dt = (now_ns() - t0) / ~a;\n" batch)
  (fprintf o "    if (dt < best) best = dt;\n  }\n")
  (fprintf o "  printf(\"%.6f\\n\", best / (double)n);\n  return 0;\n}\n")
  (get-output-string o))

;; -------------------------------------------------------- variant measure

;; returns (values ns-per-elem note) — ns is #f when the variant is invalid
(define (measure-variant mod file sym n batch meas dir tag)
  (define-values (kernels diags) (check mod))
  (cond
    [(pair? diags) (values #f "rejected by wyvec")]
    [else
     (define k (findf (λ (kk) (string=? (kernel-symbol kk) sym)) kernels))
     (define ir (emit-module file kernels))
     (define ll (build-path dir (format "~a.ll" tag)))
     (define obj (build-path dir (format "~a.o" tag)))
     (define yaml (build-path dir (format "~a.yaml" tag)))
     (define drv (build-path dir (format "~a.c" tag)))
     (define exe (build-path dir (format "~a.bin" tag)))
     (display-to-file ir ll #:exists 'replace)
     (display-to-file (gen-tune-driver k n batch meas) drv #:exists 'replace)
     (define clang (find-clang))
     (define ok
       (and (silently (λ () (system* clang "-O2" "-march=native" "-Wno-override-module"
                                     (format "-foptimization-record-file=~a" (path->string yaml))
                                     "-foptimization-record-passes=loop-vectorize"
                                     "-c" "-o" (path->string obj) (path->string ll))))
            (silently (λ () (system* clang "-O2" "-march=native"
                                     "-o" (path->string exe)
                                     (path->string drv) (path->string obj))))))
     (cond
       [(not ok) (values #f "clang failed")]
       [else
        (define out (with-output-to-string (λ () (system* (path->string exe)))))
        (define t (string->number (string-trim out)))
        (define rs (parse-remarks (if (file-exists? yaml) (file->string yaml) "")))
        (define p (findf (λ (r) (and (eq? (remark-verdict r) 'passed)
                                     (string=? (remark-function r) sym)
                                     (string=? (remark-pass r) "loop-vectorize")))
                         rs))
        (define note
          (if p
              (format "vf ~a, ic ~a"
                      (or (remark-arg p "VectorizationFactor") "?")
                      (or (remark-arg p "InterleaveCount") "?"))
              "not vectorized"))
        (values t note)])]))

;; ----------------------------------------------------------------- search

(define (tune-module mod file
                     #:n [n 2048]
                     #:widths [widths '(4 8 16)]
                     #:interleaves [ils '(1 2 4 8)]
                     #:batch [batch 2000]
                     #:meas [meas 30])
  (define-values (kernels diags) (check mod))
  (when (pair? diags)
    (for ([d (in-list diags)]) (eprintf "~a" (diag-render d file)))
    (error 'wyve "fix the contracts before tuning"))
  (for ([k (in-list kernels)])
    (tune-kernel mod file k n widths ils batch meas)))

(define (tune-kernel mod file k n widths ils batch meas)
  (define sym (kernel-symbol k))
  ;; variants: (label w-or-'asis il ns note)
  (define grid
    (append
     (list (list "as written" 'asis #f))
     (list (list "llvm chooses" #f #f))
     (for*/list ([w (in-list widths)] [il (in-list ils)])
       (list (format "width ~a, interleave ~a" w il) w il))))
  (printf "\ntuning ~a — n=~a, ~a schedules, native CPU\n" sym n (length grid))
  (flush-output)
  (define dir (build-path (find-system-path 'temp-dir)
                          (format "wyve-tune-~a" (current-milliseconds))))
  (make-directory* dir)
  (define results
    (for/list ([v (in-list grid)] [i (in-naturals)])
      (match-define (list label w il) v)
      (define m (if (eq? w 'asis) mod (set-vectorize-knobs-mod mod w il)))
      (define-values (t note) (measure-variant m file sym n batch meas dir (format "v~a" i)))
      (printf ".")
      (flush-output)
      (list label w il t note)))
  (printf "\n")
  (delete-directory/files dir #:must-exist? #f)
  (define ok (filter (λ (r) (list-ref r 3)) results))
  (define sorted (sort ok < #:key (λ (r) (list-ref r 3))))
  (define written (findf (λ (r) (string=? (car r) "as written")) results))
  (define base (and written (list-ref written 3)))
  (for ([r (in-list sorted)] [rank (in-naturals)])
    (match-define (list label _w _il t note) r)
    (printf "  ~a~a ns/elem   ~a [~a]~a\n"
            (if (zero? rank) "→ " "   ")
            (real->decimal-string t 4)
            (~a label #:min-width 24)
            note
            (if (string=? label "as written") "  ← the contract as written" "")))
  (match-define (list blabel bw bil bt _bnote) (car sorted))
  (when (and base (not (string=? blabel "as written")))
    (cond
      [(< bt (* base 0.995))
       (printf "  winner beats the written contract by ~ax\n"
               (real->decimal-string (/ base bt) 2))
       (define v (Contracts-vectorize (Sig-contracts (kernel-decl k))))
       (define req (and v (Vectorize-require? v)))
       (printf "  suggested: @vectorize(~a~a~a)\n"
               (if req "require" "")
               (if bw (format "~awidth: ~a" (if req ", " "") bw) "")
               (if bil (format ", interleave: ~a" bil) ""))]
      [else
       (printf "  the written contract is already within noise of the best schedule\n")])))
