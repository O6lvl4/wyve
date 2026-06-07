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
;; (reduce's width 16 / interleave 4 schedule was found by `wyvec tune`)
(for ([spec (in-list '(("saxpy" 8) ("reduce" 16) ("stencil" 8) ("live" 8)))])
  (define name (car spec))
  (define width (cadr spec))
  (define f (format "examples/~a.wyv" name))
  (define-values (_mod _kernels ir diags) (compile-file f))
  (expect! (format "~a compiles" name) (null? diags))
  (when (null? diags)
    (expect! (format "~a IR has noalias" name) (string-contains? ir "noalias"))
    (expect! (format "~a IR has vectorize metadata" name)
             (string-contains? ir "llvm.loop.vectorize.enable"))
    (expect! (format "~a IR has width ~a" name width)
             (string-contains? ir (format "llvm.loop.vectorize.width\", i32 ~a" width)))))

;; reduce grants reassoc
(let-values ([(_m _k ir diags) (compile-file "examples/reduce.wyv")])
  (expect! "reduce IR has fadd reassoc" (and (null? diags) (string-contains? ir "fadd reassoc"))))

;; optimizer knobs land as loop metadata
(let-values ([(_m _k ir diags) (compile-file "examples/tuned.wyv")])
  (expect! "tuned compiles" (null? diags))
  (expect! "tuned IR has interleave.count 4"
           (and (null? diags) (string-contains? ir "llvm.loop.interleave.count\", i32 4"))))

(define knob-kernel
  (string-append
   "@interface K\n"
   "~a\n"
   "+ (void)f:(@noalias const float *)x y:(@noalias float *)y count:(usize)n;\n"
   "@end\n"
   "@implementation K\n"
   "+ (void)f:(@noalias const float *)x y:(@noalias float *)y count:(usize)n\n"
   "{ for (usize i = 0; i < n; i++) { y[i] = x[i]; } }\n"
   "@end\n"))

(define (compile-knob contracts)
  (compile-source (format knob-kernel contracts) "knob.wyv"))

(let-values ([(_m _k ir diags) (compile-knob "@vectorize(disable)")])
  (expect! "disable lands as enable=false"
           (and (null? diags) (string-contains? ir "llvm.loop.vectorize.enable\", i1 false"))))

(let-values ([(_m _k ir diags) (compile-knob "@unroll(count: 4)")])
  (expect! "unroll lands as unroll.count 4"
           (and (null? diags) (string-contains? ir "llvm.loop.unroll.count\", i32 4"))))

(let-values ([(_m _k ir diags) (compile-knob "@vectorize(predicate, scalable)")])
  (expect! "predicate+scalable land as metadata"
           (and (null? diags)
                (string-contains? ir "vectorize.predicate.enable")
                (string-contains? ir "vectorize.scalable.enable"))))

(let-values ([(_m _k _ir diags) (compile-knob "@vectorize(require, disable)")])
  (expect! "require+disable is rejected" (pair? diags)))

(let-values ([(_m _k _ir diags) (compile-knob "@unroll(count: 1)")])
  (expect! "unroll count 1 is rejected" (pair? diags)))

;; @tile: proven scheduling above LLVM
(let-values ([(_m _k ir diags) (compile-file "examples/matmul.wyv")])
  (expect! "matmul compiles (2 kernels)" (null? diags))
  (expect! "tiling applied (tile-loop allocas)"
           (and (null? diags) (string-contains? ir "%i.t.addr")))
  (expect! "ragged tile edges use select"
           (and (null? diags) (string-contains? ir "select i1"))))

(let-values ([(_m _k _ir diags) (compile-file "examples/invalid/tile-unprovable.wyv")])
  (expect! "unprovable tiling rejected with WVN020"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN020")) diags))))

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
