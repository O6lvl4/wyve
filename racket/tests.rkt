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

;; kernel-to-kernel calls
(let-values ([(_m kernels ir diags) (compile-file "examples/pipeline.wyv")])
  (expect! "pipeline compiles (2 kernels)" (and (null? diags) (= (length kernels) 2)))
  (when (null? diags)
    (expect! "pipeline emits call void @Scale_by"
             (string-contains? ir "call void @Scale_by"))))

;; calling an unknown kernel is rejected
(let-values ([(_m _k _ir diags)
              (compile-source
               (string-append
                "@interface P\n@effect(writes(y))\n+ (void)run:(@noalias float *)y count:(usize)n;\n@end\n"
                "@implementation P\n+ (void)run:(@noalias float *)y count:(usize)n\n"
                "{ [Nope go:y count:n]; }\n@end\n")
               "badcall.wyv")])
  (expect! "call to unknown kernel rejected" (pair? diags)))

;; Stage 2 — @noalias proven at the call boundary
(let-values ([(_m _k _ir diags) (compile-file "examples/invalid/alias-call.wyv")])
  (expect! "in-place call to a @noalias kernel rejected with WVN050"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN050")) diags))))

;; passing a non-@noalias pointer to a @noalias parameter is unprovable
(let-values ([(_m _k _ir diags)
              (compile-source
               (string-append
                "@interface S\n@effect(reads(x), writes(y))\n+ (void)go:(@noalias const float *)x y:(@noalias float *)y count:(usize)n;\n@end\n"
                "@implementation S\n+ (void)go:(@noalias const float *)x y:(@noalias float *)y count:(usize)n\n"
                "{ for (usize i = 0; i < n; i++) { y[i] = x[i]; } }\n@end\n"
                "@interface C\n@effect(reads(a), writes(b))\n+ (void)run:(const float *)a b:(@noalias float *)b count:(usize)n;\n@end\n"
                "@implementation C\n+ (void)run:(const float *)a b:(@noalias float *)b count:(usize)n\n"
                "{ [S go:a y:b count:n]; }\n@end\n")
               "nonna.wyv")])
  (expect! "non-@noalias argument to @noalias parameter rejected with WVN050"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN050")) diags))))

;; math builtins lower to LLVM intrinsics
(let-values ([(_m _k ir diags) (compile-file "examples/activation.wyv")])
  (expect! "activation compiles" (null? diags))
  (when (null? diags)
    (expect! "min/max -> llvm.minnum/maxnum"
             (and (string-contains? ir "llvm.minnum") (string-contains? ir "llvm.maxnum")))
    (expect! "sqrt/abs -> llvm.sqrt/fabs"
             (and (string-contains? ir "llvm.sqrt") (string-contains? ir "llvm.fabs")))
    (expect! "intrinsics are declared" (string-contains? ir "declare float @llvm."))))

(define (compile-math body)
  (compile-source
   (string-append
    "@interface M\n@effect(reads(x), writes(y))\n+ (void)f:(@noalias const float *)x y:(@noalias float *)y count:(usize)n;\n@end\n"
    "@implementation M\n+ (void)f:(@noalias const float *)x y:(@noalias float *)y count:(usize)n\n"
    "{ for (usize i = 0; i < n; i++) { " body " } }\n@end\n")
   "math.wyv"))

(let-values ([(_m _k _ir diags) (compile-math "y[i] = clampx(x[i], 0.0f);")])
  (expect! "unknown builtin rejected" (pair? diags)))
(let-values ([(_m _k _ir diags) (compile-math "y[i] = sqrt(x[i], x[i]);")])
  (expect! "wrong arity rejected" (pair? diags)))
(let-values ([(_m _k _ir diags) (compile-math "y[i] = max(0.0f, x[i]);")])
  (expect! "max(float, float) accepted" (null? diags)))

;; element types: double, int, and numeric casts
(let-values ([(_m _k ir diags) (compile-file "examples/types.wyv")])
  (expect! "types compiles" (null? diags))
  (when (null? diags)
    (expect! "double arithmetic" (string-contains? ir "fmul double"))
    (expect! "int arithmetic with i32" (string-contains? ir "add i32"))
    (expect! "double vectorizes at width 4"
             (string-contains? ir "llvm.loop.vectorize.width\", i32 4"))
    (expect! "float->int cast" (string-contains? ir "fptosi"))))

;; int<->float casts both directions
(let-values ([(_m _k ir diags)
              (compile-source
               (string-append
                "@interface C\n@effect(reads(a), writes(b))\n+ (void)f:(@noalias const int *)a b:(@noalias float *)b count:(usize)n;\n@end\n"
                "@implementation C\n+ (void)f:(@noalias const int *)a b:(@noalias float *)b count:(usize)n\n"
                "{ for (usize i = 0; i < n; i++) { b[i] = (float)a[i]; } }\n@end\n")
               "cast.wyv")])
  (expect! "int->float cast lowers to sitofp"
           (and (null? diags) (string-contains? ir "sitofp"))))

;; unary minus (fneg) and modulo (srem/frem)
(let-values ([(_m _k ir diags)
              (compile-source
               (string-append
                "@interface U\n@effect(reads(x), writes(y))\n+ (void)f:(@noalias const float *)x y:(@noalias float *)y count:(usize)n;\n@end\n"
                "@implementation U\n+ (void)f:(@noalias const float *)x y:(@noalias float *)y count:(usize)n\n"
                "{ for (usize i = 0; i < n; i++) { y[i] = -x[i]; } }\n@end\n")
               "neg.wyv")])
  (expect! "unary minus lowers to fneg" (and (null? diags) (string-contains? ir "fneg"))))

(let-values ([(_m _k ir diags)
              (compile-source
               (string-append
                "@interface M\n@effect(reads(x), writes(y))\n+ (void)g:(@noalias const int *)x y:(@noalias int *)y count:(usize)n;\n@end\n"
                "@implementation M\n+ (void)g:(@noalias const int *)x y:(@noalias int *)y count:(usize)n\n"
                "{ for (usize i = 0; i < n; i++) { y[i] = x[i] % 3; } }\n@end\n")
               "mod.wyv")])
  (expect! "modulo lowers to srem" (and (null? diags) (string-contains? ir "srem"))))

;; an integer literal that overflows 64 bits is rejected (no silent truncation)
(let-values ([(_m _k _ir diags)
              (compile-source
               (string-append
                "@interface O\n@effect(writes(y))\n+ (void)f:(@noalias float *)y count:(usize)n;\n@end\n"
                "@implementation O\n+ (void)f:(@noalias float *)y count:(usize)n\n"
                "{ for (usize i = 0; i < n; i++) { y[i] = (float)99999999999999999999; } }\n@end\n")
               "ovf.wyv")])
  (expect! "64-bit-overflowing integer literal rejected" (pair? diags)))

;; the exp builtin lowers to @llvm.exp (sigmoid/silu/gelu activations)
(let-values ([(_m _k ir diags) (compile-file "examples/sigmoid.wyv")])
  (expect! "sigmoid compiles" (null? diags))
  (when (null? diags)
    (expect! "exp lowers to @llvm.exp" (string-contains? ir "@llvm.exp"))))

;; an integer literal adopts int from context (no type mismatch)
(let-values ([(_m _k _ir diags)
              (compile-source
               (string-append
                "@interface I\n@effect(reads(a), writes(b))\n+ (void)f:(@noalias const int *)a b:(@noalias int *)b count:(usize)n;\n@end\n"
                "@implementation I\n+ (void)f:(@noalias const int *)a b:(@noalias int *)b count:(usize)n\n"
                "{ for (usize i = 0; i < n; i++) { int t = a[i] + 2; b[i] = t * 3; } }\n@end\n")
               "intlit.wyv")])
  (expect! "integer-literal polymorphism compiles" (null? diags)))

;; float and double don't mix (type error)
(let-values ([(_m _k _ir diags)
              (compile-source
               (string-append
                "@interface M\n@effect(reads(a), writes(b))\n+ (void)f:(@noalias const float *)a b:(@noalias double *)b count:(usize)n;\n@end\n"
                "@implementation M\n+ (void)f:(@noalias const float *)a b:(@noalias double *)b count:(usize)n\n"
                "{ for (usize i = 0; i < n; i++) { b[i] = a[i]; } }\n@end\n")
               "mix.wyv")])
  (expect! "float-to-double mismatch rejected" (pair? diags)))

;; control flow: if/else lowers to branches
(let-values ([(_m _k ir diags) (compile-file "examples/relu.wyv")])
  (expect! "relu compiles" (null? diags))
  (when (null? diags)
    (expect! "relu IR has a conditional branch" (string-contains? ir "br i1"))
    (expect! "relu IR has if.then/if.end labels"
             (and (regexp-match? #px"if[0-9]+\\.then" ir)
                  (regexp-match? #px"if[0-9]+\\.end" ir)))))

;; `if` inside @vectorize(require) is refused (needs predication)
(let-values ([(_m _k _ir diags)
              (compile-source
               (string-append
                "@interface V\n@effect(reads(x), writes(y))\n@vectorize(require, width: 8)\n"
                "+ (void)f:(@noalias const float *)x y:(@noalias float *)y count:(usize)n;\n@end\n"
                "@implementation V\n+ (void)f:(@noalias const float *)x y:(@noalias float *)y count:(usize)n\n"
                "{ for (usize i = 0; i < n; i++) { if (x[i] > 0.0f) { y[i] = x[i]; } else { y[i] = 0.0f; } } }\n@end\n")
               "vif.wyv")])
  (expect! "vectorize(require) + if rejected with WVN017"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN017")) diags))))

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
(let-values ([(_m kernels ir diags) (compile-file "examples/transpose.wyv")])
  (expect! "transpose compiles (4x4 and 8x8)" (and (null? diags) (= (length kernels) 2)))
  (when (null? diags)
    (expect! "transpose IR has <4 x float> and <8 x float> vectors"
             (and (string-contains? ir "<4 x float>") (string-contains? ir "<8 x float>")))
    (expect! "8x8 transpose has 24 shuffles"
             (>= (length (regexp-match* #px"shufflevector <8" ir)) 24))))

;; @simd vector arithmetic + scalar broadcast: a twiddled FFT butterfly
(let-values ([(_m _k ir diags) (compile-file "examples/butterfly.wyv")])
  (expect! "butterfly compiles" (null? diags))
  (when (null? diags)
    (expect! "butterfly IR has vector fadd" (string-contains? ir "fadd <4 x float>"))
    (expect! "butterfly IR has vector fsub" (string-contains? ir "fsub <4 x float>"))
    (expect! "butterfly IR broadcasts the scalar twiddle"
             (and (string-contains? ir "insertelement")
                  (string-contains? ir "shufflevector <4 x float>")))))

;; a vector local cannot be initialized from a scalar alone
(let-values ([(_m _k _ir diags)
              (compile-source
               (string-append
                "@interface B\n@effect(writes(b))\n@simd\n+ (void)f:(float)w b:(@noalias float *)b;\n@end\n"
                "@implementation B\n+ (void)f:(float)w b:(@noalias float *)b\n"
                "{ float4 v = w; b[0 : 4] = v; }\n@end\n")
               "scalarvec.wyv")])
  (expect! "scalar-to-vector local rejected with WVN041"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN041")) diags))))

;; cmul builtin: complex multiply expands to shuffle + vector mul/add/sub
(let-values ([(_m _k ir diags) (compile-file "examples/complex-mul.wyv")])
  (expect! "complex-mul compiles" (null? diags))
  (when (null? diags)
    (expect! "cmul expands to vector mul/add/sub"
             (and (string-contains? ir "fmul <4 x float>")
                  (string-contains? ir "fsub <4 x float>")
                  (string-contains? ir "fadd <4 x float>")))))

;; the FFT core: a twiddled complex butterfly built from cmul
(let-values ([(_m _k ir diags) (compile-file "examples/fft-butterfly.wyv")])
  (expect! "fft-butterfly compiles" (null? diags))
  (when (null? diags)
    (expect! "butterfly uses cmul + shuffles"
             (>= (length (regexp-match* #px"shufflevector" ir)) 6))))

;; a complete 4-point FFT: @simd transform + scalar reference
(let-values ([(_m kernels ir diags) (compile-file "examples/fft.wyv")])
  (expect! "fft compiles (2 kernels)" (and (null? diags) (= (length kernels) 2)))
  (when (null? diags)
    (expect! "fft @simd version uses cmul + shuffles"
             (>= (length (regexp-match* #px"shufflevector" ir)) 8))
    (expect! "fft scalar version has plain float arithmetic"
             (string-contains? ir "fadd float"))))

;; the batched FFT (hand-written): signal-major SoA -> zero shuffles
(let-values ([(_m _k ir diags) (compile-file "examples/fft-batch.wyv")])
  (expect! "fft-batch compiles" (null? diags))
  (when (null? diags)
    (expect! "batched FFT has zero shuffles"
             (zero? (length (regexp-match* #px"shufflevector" ir))))
    (expect! "batched FFT is float8 vector add/sub"
             (and (string-contains? ir "fadd <8 x float>")
                  (string-contains? ir "fneg <8 x float>")))))

;; @batch: a scalar kernel auto-widened to the same zero-shuffle batch IR,
;; both as one batch (Batched) and over a block loop (Blocks)
(let-values ([(_m kernels ir diags) (compile-file "examples/batch.wyv")])
  (expect! "batch.wyv compiles (2 kernels)" (and (null? diags) (= (length kernels) 2)))
  (when (null? diags)
    (expect! "@batch auto-widens to float8" (string-contains? ir "fadd <8 x float>"))
    (expect! "@batch emits zero shuffles"
             (zero? (length (regexp-match* #px"shufflevector" ir))))
    (expect! "@batch block loop computes the per-block offset (mul by 64)"
             (regexp-match? #px"mul nuw i64[^\n]*64" ir))))

;; @batch refuses loops (the batch is the parallelism)
(let-values ([(_m _k _ir diags) (compile-file "examples/invalid/batch-loop.wyv")])
  (expect! "@batch with a loop rejected with WVN060"
           (and (pair? diags) (ormap (λ (d) (equal? (diag-code d) "WVN060")) diags))))

;; cmul with mismatched widths is rejected
(let-values ([(_m _k _ir diags)
              (compile-source
               (string-append
                "@interface C\n@effect(reads(a), writes(b))\n@simd\n+ (void)f:(@noalias const float *)a b:(@noalias float *)b;\n@end\n"
                "@implementation C\n+ (void)f:(@noalias const float *)a b:(@noalias float *)b\n"
                "{ float4 x = a[0 : 4]; float2 y = shuffle(x, x, 0, 1); float4 z = cmul(x, y); b[0 : 4] = z; }\n@end\n")
               "cmulmix.wyv")])
  (expect! "cmul with mismatched widths rejected" (pair? diags)))

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
