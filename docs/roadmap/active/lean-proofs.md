<!-- description: wyve-proofs — Lean 4 models of the analyses with soundness theorems -->
# Lean 4 proofs

Model the dependence analysis (WVN014), tiling legality (WVN020-023),
and interchange exactness (currently asserted bitwise in bench) as Lean
theorems; CI binds the Racket implementation to the model. CompCert's
sales pitch, sized for kernels. Start before the analyses outgrow
modeling cost.

## Progress

WVN014 (loop-carried dependence) soundness is proven in `proofs/`
(Lean 4.30, `omega`, no Mathlib): acceptance is sound (same offset ⇒ no
distinct iterations collide), rejection is necessary (cr < cw ⇒ a real
previous-iteration write collides with the later read), and the analysis
rule is characterized exactly (dependence ⇔ offsets differ). `lake build`
checks it. Next: WVN020–024 (tiling/interchange legality) and WVN025
(parallel independence) — the injective-subscript arguments.

## Done: schedule transforms proven bitwise-exact (2026-06-08)

WVN014 (dependence), WVN025 (@parallel, Lean core), WVN024 (@interchange,
Mathlib sum_comm), WVN020-022 (@tile, Mathlib finProdFinEquiv). All three
schedule transforms machine-proven to change the result by not one bit —
including that the 91.5-GFLOPS tiled matmul equals the naive one. Mathlib is
now a proofs dependency. Remaining: WVN015-018 (reduction/predication legality
rather than result-equality), and matmul full correctness (tiled = Matrix.mul).
