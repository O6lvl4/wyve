<!-- description: @interchange(p, j) — scalar expansion + interchange; ~20x on matmul, float-exact, rung (c) cleared -->
<!-- done: 2026-06-07 -->
# @interchange

One verified contract line on the unchanged naive matmul: 24.7 GFLOPS
vs 1.2 naive (~20x). Float-exact by construction (bench asserts
bitwise equality). Same ikj schedule hand-written in Zig: ~4 GFLOPS —
the schedule AND the lowering both have to be yours. (dce39a1)
