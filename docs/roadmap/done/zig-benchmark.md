<!-- description: North-star rungs (a)(b) vs Zig — 5-48x idiomatic, beats hand-@Vector on all three kernels -->
<!-- done: 2026-06-07 -->
# Zig benchmark — rungs (a) and (b)

Same C driver, native CPU both sides. L1: 5-48x vs idiomatic/tuned
Zig; beats hand-written @Vector SIMD on all three kernels after tune.
Discovery: Zig 0.16 ReleaseFast does not run LLVM's loop vectorizer
(verified via -femit-llvm-ir) — the thesis demonstrated by accident:
unchecked performance rots silently. (ade898a, bench/NOTES.md)
