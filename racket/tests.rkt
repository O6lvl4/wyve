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
(for ([spec (in-list '(("saxpy" 8) ("reduce" 16) ("stencil" 8) ("live" 8) ("align" 8)))])
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

;; @align(n) lands as the `align` parameter attribute
(let-values ([(_m _k ir diags) (compile-file "examples/align.wyv")])
  (expect! "align IR has `align 64` on pointers"
           (and (null? diags) (string-contains? ir "align 64"))))

;; @vectorize(manual): wyvec emits the vector loop itself, so @stream's
;; nontemporal rides a vector store (the only lowering that beats plain
;; vectorization — bench/NOTES.md)
(let-values ([(_m _k ir diags) (compile-file "examples/manual.wyv")])
  (expect! "manual compiles" (null? diags))
  (when (null? diags)
    (expect! "manual IR has <8 x float> vector ops"
             (string-contains? ir "<8 x float>"))
    (expect! "manual IR has vector store with align 64"
             (regexp-match? #px"store <8 x float>[^\n]*align 64" ir))
    (expect! "manual IR has nontemporal on the vector store"
             (regexp-match? #px"store <8 x float>[^\n]*!nontemporal" ir))))

;; @vectorize(manual) refuses non-elementwise loops (a reduction)
(let-values ([(_m _k _ir diags) (compile-file "examples/invalid/manual-reduction.wyv")])
  (expect! "manual reduction rejected with WVN040"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN040")) diags))))

;; @simd: explicit shuffle-shaped vector code (transpose)
(let-values ([(_m _k ir diags) (compile-file "examples/transpose.wyv")])
  (expect! "transpose compiles" (null? diags))
  (when (null? diags)
    (expect! "transpose IR has <4 x float> vectors" (string-contains? ir "<4 x float>"))
    (expect! "transpose IR has shufflevector"
             (>= (length (regexp-match* #px"shufflevector" ir)) 8))))

;; @simd vector arithmetic: a radix-2 FFT butterfly
(let-values ([(_m _k ir diags) (compile-file "examples/butterfly.wyv")])
  (expect! "butterfly compiles" (null? diags))
  (when (null? diags)
    (expect! "butterfly IR has vector fadd" (string-contains? ir "fadd <4 x float>"))
    (expect! "butterfly IR has vector fsub" (string-contains? ir "fsub <4 x float>"))))

;; @simd refuses loops (that is the @vectorize world)
(let-values ([(_m _k _ir diags) (compile-file "examples/invalid/simd-loop.wyv")])
  (expect! "simd loop rejected with WVN041"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN041")) diags))))

;; @stream lowers write-only stores to nontemporal (implemented; see
;; bench/NOTES.md for why it is not yet recommended over vectorization)
(let-values ([(_m _k ir diags)
              (compile-source
               (string-append
                "@interface S\n@effect(reads(x), writes(dst))\n@stream\n"
                "+ (void)copy:(@noalias const float *)x dst:(@noalias float *)dst count:(usize)n;\n@end\n"
                "@implementation S\n+ (void)copy:(@noalias const float *)x dst:(@noalias float *)dst count:(usize)n\n"
                "{ for (usize i = 0; i < n; i++) { dst[i] = x[i]; } }\n@end\n")
               "stream.wyv")])
  (expect! "stream IR has nontemporal store"
           (and (null? diags) (string-contains? ir "!nontemporal"))))

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

;; @tile / @interchange / @parallel / @fp(contract): scheduling above LLVM
(let-values ([(_m kernels ir diags) (compile-file "examples/matmul.wyv")])
  (expect! "matmul compiles (5 kernels)" (and (null? diags) (= (length kernels) 5)))
  (expect! "tiling applied (tile-loop allocas)"
           (and (null? diags) (string-contains? ir "%i.t.addr")))
  (expect! "ragged tile edges use select"
           (and (null? diags) (string-contains? ir "select i1")))
  (expect! "parallel dispatches via libdispatch"
           (and (null? diags) (string-contains? ir "dispatch_apply_f")))
  (expect! "parallel body keeps original attrs (alwaysinline)"
           (and (null? diags) (string-contains? ir "alwaysinline")))
  (expect! "fp(contract) lands as FMA-enabling flag"
           (and (null? diags) (string-contains? ir "fmul contract"))))

;; @parallel refuses non-loop-shaped kernels (a reduction body)
(define parallel-bad
  (string-append
   "@interface BadPar\n"
   "@effect(reads(x))\n"
   "@parallel(i)\n"
   "+ (float)sum:(@noalias const float *)x count:(usize)n;\n"
   "@end\n"
   "@implementation BadPar\n"
   "+ (float)sum:(@noalias const float *)x count:(usize)n\n"
   "{\n"
   "    float acc = 0.0f;\n"
   "    for (usize i = 0; i < n; i++) {\n"
   "        acc += x[i];\n"
   "    }\n"
   "    return acc;\n"
   "}\n"
   "@end\n"))

(let-values ([(_m _k _ir diags) (compile-source parallel-bad "badpar.wyv")])
  (expect! "parallel reduction rejected with WVN025"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN025")) diags))))

(let-values ([(_m _k _ir diags) (compile-file "examples/invalid/tile-unprovable.wyv")])
  (expect! "unprovable tiling rejected with WVN020"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN020")) diags))))

;; interchange refuses kernels that read the accumulated array
(define interchange-bad
  (string-append
   "@interface Bad\n"
   "@effect(reads(b, c), writes(c))\n"
   "@interchange(p, j)\n"
   "+ (void)f:(@noalias const float *)b c:(@noalias float *)c n:(usize)n k:(usize)k;\n"
   "@end\n"
   "@implementation Bad\n"
   "+ (void)f:(@noalias const float *)b c:(@noalias float *)c n:(usize)n k:(usize)k\n"
   "{\n"
   "    for (usize i = 0; i < n; i++) {\n"
   "        for (usize j = 0; j < n; j++) {\n"
   "            float acc = 0.0f;\n"
   "            for (usize p = 0; p < k; p++) {\n"
   "                acc += b[p * n + j] + c[i * n + j];\n"
   "            }\n"
   "            c[i * n + j] = acc;\n"
   "        }\n"
   "    }\n"
   "}\n"
   "@end\n"))

(let-values ([(_m _k _ir diags) (compile-source interchange-bad "bad.wyv")])
  (expect! "interchange with c read rejected with WVN020"
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

;; @stream on a read-modify-write array has no write-only target
(let-values ([(_m _k _ir diags) (compile-file "examples/invalid/stream-rmw.wyv")])
  (expect! "stream on rmw rejected with WVN031"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN031")) diags))))

;; @align with a non-power-of-two alignment is rejected
(let-values ([(_m _k _ir diags)
              (compile-source
               (string-append
                "@interface A\n+ (void)f:(@align(48) float *)x count:(usize)n;\n@end\n"
                "@implementation A\n+ (void)f:(@align(48) float *)x count:(usize)n\n"
                "{ for (usize i = 0; i < n; i++) { x[i] = x[i]; } }\n@end\n")
               "badalign.wyv")])
  (expect! "non-power-of-two @align rejected with WVN030"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN030")) diags))))

(printf "~a\n" (if (zero? failures) "all tests passed" (format "~a FAILURES" failures)))
(exit (if (zero? failures) 0 1))
