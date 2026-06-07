# Wyve vs Zig — first measurements

2026-06-07. i7-7700 (Kaby Lake, AVX2+FMA), macOS 13. Apple clang 14.0.3
(LLVM 15) for the Wyve side, Zig 0.16.0 (`-O ReleaseFast -fllvm`) for the
Zig side. Same C driver, same buffers, both native CPU. Reproduce with
`./bench/run.sh`.

## Results (ns/elem, min of repeated batches)

### L1-resident (n = 2048) — compute-bound

| kernel | wyve   | zig idiomatic | zig tuned¹ | zig @Vector² |
| ------ | ------ | ------------- | ---------- | ------------ |
| saxpy  | 0.046  | 0.400 (8.7×)  | 0.401 (8.7×) | 0.080 (1.7×) |
| sum³   | 0.021  | 1.003 (48×)   | 1.003 (48×)  | 0.032 (1.5×) |
| blur3  | 0.108  | 0.553 (5.1×)  | 0.464 (4.3×) | 0.149 (1.4×) |

### Memory-bound (n = 4M)

| kernel | wyve   | zig idiomatic | zig tuned¹ | zig @Vector² |
| ------ | ------ | ------------- | ---------- | ------------ |
| saxpy  | 0.379  | 0.555 (1.5×)  | 0.554 (1.5×) | 0.388 (tie) |
| sum    | 0.147  | 1.004 (6.8×)  | 1.003 (6.8×) | 0.149 (tie) |
| blur3  | 0.383  | 0.696 (1.8×)  | 0.595 (1.6×) | 0.405 (tie) |

(parenthesis = how much faster Wyve is)

¹ tuned = `noalias` parameters + `@setFloatMode(.optimized)` by hand.
² @Vector = hand-written 8-lane SIMD, 4 accumulators for the reduction.
³ sum carries the schedule `wyvec tune` found (width 16, interleave 4) —
  see "The search" below. Before tuning it tied @Vector at 0.030.

## The discovery

Zig 0.16's ReleaseFast pipeline **does not run LLVM's loop vectorizer** on
this code — verified by `-femit-llvm-ir`: the optimized IR is scalar,
unrolled ×4, no vector types, even with `noalias` and
`@setFloatMode(.optimized)`, even with `-fllvm`. That is why "tuned" ties
"idiomatic": the annotations had nobody listening.

This is the thesis by accident. A general-purpose language's relationship
with its optimizer is aspirational — and the aspiration can rot in a
toolchain upgrade with no notification. A Wyve kernel carrying
`@vectorize(require)` cannot rot silently: the same regression here would
have been a compile error with the reason attached.

## The search

`wyvec tune` sweeps the schedule space (width × interleave + "LLVM
chooses"), compiles each variant, verifies it against the remarks, and
measures it. On the reduction it found **width 16 / interleave 4** —
1.42× faster than both the hand-written contract *and* LLVM's own cost
model (which picks vf 8 / ic 4 on this CPU). A schedule nobody wrote,
now pinned in `examples/reduce.wyv` as a contract the toolchain must
honor or fail loudly. On saxpy and blur3 the search confirmed the
written contracts are already at the optimum — also worth knowing.

## Scheduling above LLVM: @tile, first contact (honest numbers)

`@tile(i: 64, j: 64)` on the naive matmul is wyvec's first transform LLVM
itself never attempts: strip-mine + interchange, legality proven (write-only
arrays, injective row-major stores, no carried scalars — WVN020-023 refuse
everything else), float-exact by construction. Measured (m=n=k):

| size | wyve @tile(64) | wyve naive | zig naive | zig hand-tiled |
| ---- | -------------- | ---------- | --------- | -------------- |
| 512  | 1.19 GFLOPS    | 1.22 (tie) | 1.21 (tie) | 1.20 (tie)    |
| 1024 | 1.31 GFLOPS    | 1.25 (1.05×) | 1.23 (1.07×) | 0.63 (**2.08×**) |

The mechanics are right (tiled ≡ naive bitwise; the human who hand-tiled
the Zig made it 2× *slower*), but i/j tiling alone pays little here: the
kernel is bound by the strided `b[p*n + j]` walk, and a k×64 b-tile
(256 KB) overflows L2. The known fixes are k-tiling (3D tiles) and the
ikj schedule (scalar expansion + interchange, which makes the inner loop
vectorizable) — that is the next transform. The lesson stands either way:
schedules need measurement, and a schedule that ships as a verified
contract can be measured, compared, and refused without touching the
algorithm.

## Ladder status (docs/DESIGN.md north star)

- **(a) beat idiomatic Zig: cleared** — 5×–48× L1, 1.5×–6.8× memory-bound.
- **(b) match hand-@Vector Zig: exceeded on all three** — saxpy 1.7×,
  sum 1.5× (after tuning), blur3 1.4×.
- **(c) schedules humans didn't write: first blood** — `wyvec tune` beat
  LLVM's cost model by 1.42× on the reduction, and `@tile` landed as the
  first proven transform above LLVM (modest gains so far; see above).
  Open: k-tiling / ikj interchange / `@fuse`, then tune sweeping tile
  sizes the way it sweeps widths.

## Fairness notes

- Both sides target the native CPU (clang `-march=native`, Zig native default).
- `-fllvm` is passed explicitly; default-backend numbers were identical.
- Results are cross-checked between implementations before timing. The
  large-n sum differs by ~0.4% between scalar-sequential and 8-lane
  summation — float associativity, with the vectorized order closer to the
  exact value.
