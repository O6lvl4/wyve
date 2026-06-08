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
