<!-- description: @vectorize(manual) + float8 + slice loads — explicit lanes inside contract checking -->
# Manual SIMD

Gated on the first shuffle-shaped kernel (FFT butterfly, transpose,
AoS<->SoA). Design parked in docs/DESIGN.md Q6: Scopes' philosophy
contained inside Wyve's verification. Waiting is justified while
naive-loop-plus-contract keeps beating hand-SIMD.
