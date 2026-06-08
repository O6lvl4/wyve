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

## Scheduling above LLVM: @tile and @interchange

Two transforms LLVM's pipeline never attempts, performed by wyvec on the
proven AST. Legality is checked, not assumed (WVN020-024 refuse anything
unprovable), and both are float-exact by construction — the driver
asserts transformed ≡ naive **bitwise**. All six matmul variants share
the identical naive triple loop; only the contract line differs.

| size | par+ikj+fma | par+ikj | @interchange | @tile(64) | naive | zig naive | zig hand-tiled | zig hand-ikj |
| ---- | ----------- | ------- | ------------ | --------- | ----- | --------- | -------------- | ------------ |
| 512  | **78.4 GFLOPS** | 79.0 | 22.9 (3.4×) | 1.17 (67×) | 1.18 (66×) | 1.17 (67×) | 1.22 (64×) | 4.37 (18×) |
| 1024 | **91.5 GFLOPS** | 89.2 | 22.1 (4.2×) | 1.29 (71×) | 1.06 (**86×**) | 1.19 (77×) | 1.13 (81×) | 3.97 (23×) |

(parenthesis = how much faster the leftmost column is)

The full stack is three contract lines on the unchanged naive source:

```objc
@parallel(i)          // dispatch_apply_f across cores — independence proven (WVN025)
@interchange(p, j)    // scalar expansion + interchange — float-exact
@fp(contract)         // FMA fusion — trades bitwise exactness, explicitly
```

- `@parallel` scales 22 → 89 GFLOPS = 3.9× ≈ the four physical cores,
  and **par+ikj is still bitwise-exact** (the driver asserts it): an 84×
  speedup with zero numerical drift.
- `@parallel` lowers to wrapper → worker → alwaysinline body so the
  `noalias` parameter attributes survive into the threaded loops as
  scoped metadata; without that the inner loops would stop vectorizing.
- `@fp(contract)` adds ~3% here — at 91 GFLOPS the kernel is already at
  this machine's port/bandwidth ceiling; FMA pays more when k-tiling
  raises the compute density. Granting it is explicit and the transcript
  says what it trades.

- `@interchange(p, j)` is reduction scalar expansion + loop interchange:
  the accumulator moves into `c`, a zero-pass splits off, and `p` hoists
  over `j`. The inner loop then walks `b` and `c` sequentially and LLVM
  vectorizes it voluntarily. **One contract line on the unchanged naive
  source: ~20×.**
- The same ikj schedule hand-rewritten in Zig reaches only ~4 GFLOPS:
  the schedule fixes locality, but Zig 0.16's pipeline does not run the
  loop vectorizer, so the inner loop stays scalar. Same schedule, 6×
  apart — the schedule AND the lowering both have to be yours.
- `@tile(i: 64, j: 64)` alone pays little on this kernel (the k×64
  b-tile overflows L2); its value returns once k-tiling and
  tile×interchange composition land. The hand-tiled Zig at 1024 was 2×
  slower than naive in the earlier run — humans scheduling by hand cut
  themselves.
- Headroom to ~2× more: FMA contraction (a future `@fp(contract)` knob —
  wyvec emits plain fmul/fadd today, which is also why exactness holds),
  k-tiling, register blocking. Peak SP on this CPU is ~57 GFLOPS/core
  without FMA counting tricks.

## Memory-bound: @stream × @vectorize(manual)

`scale` (dst = a*x, dst write-only), n = 16M, far past cache:

| lowering | ns/elem |
| --- | --- |
| `@align` + `@vectorize(require)` (vectorized, temporal) | 0.411 |
| `@align` + `@stream` (scalar nontemporal) | 0.475 — **slower** |
| `@align` + `@stream` + `@vectorize(manual, width: 8)` | **0.279 — 1.47×** |

The naive `@stream` lowering loses: a scalar nontemporal store makes
LLVM 15's loop vectorizer give up, and scalar-nontemporal is slower than
vectorized-temporal. `@vectorize(manual)` — wyvec emitting the
`<8 x float>` loop itself — puts the nontemporal hint on a *vector* store
(`vmovntps`, aligned via `@align(64)`), beating plain vectorization while
staying bitwise-identical. Verification is intact: WVN040 restricts
manual to elementwise loops, WVN031 still proves the write-only target.

## FFT: a complete 4-point transform, and an honest benchmark

`examples/fft.wyv` is a full 4-point radix-2 DIT FFT in two forms: `@simd`
(explicit vectors — even/odd split by shuffle, butterflies by vector
add/sub, the -i twiddle by `cmul`) and scalar `Dft` (the reference). Both
match the exact DFT on hardware.

| version | ns/transform |
| --- | --- |
| scalar Dft | 3.0 |
| @simd Fft | 10.6 |

The @simd version is **slower** at N=4 — and that is expected, not a
failure. A 4-point transform is mostly data movement: the shuffle network
(even/odd split, the cmul's broadcasts, the output interleave) costs more
than the handful of adds it saves. SIMD FFTs win at larger radices and,
above all, by **batching** — transforming many independent signals in the
lanes of one vector, where the shuffles amortize. The single small
transform is the wrong shape for SIMD; the machinery is correct and
composes. Recorded honestly, the @stream lesson again: measure, and don't
ship a slower path as a win.

## Batched FFT: the way SIMD wins

A single FFT is shuffle-bound and loses. Batch instead — 8 signals laid out
signal-major, every float8 holding one element across all 8 (examples/fft-batch.wyv).
The butterfly's combined elements are then already in the same lanes, so the
whole transform is **zero shuffles**.

| 4-point transform | ns | shuffles |
| --- | --- | --- |
| scalar | 10.5 | — |
| @simd single | 10.7 | 14 |
| **@simd batch (8 signals)** | **1.17** | **0** |

~9× faster than both, exact. The single-signal @simd FFT was the wrong
shape; the batch is the right one — and it needs no new language feature,
just the layout. The hand-written precursor to a `@batch` contract that
would lay one naive signal out signal-major and widen the ops automatically.

## @batch over a block loop (stage 3a)

@batch also widens a block loop: write the loop and one block's FFT, and
wyvec widens the body to float8 and adds the per-block offset (block i at
x + i*64, one block being 8 elements × 8 signals). One call processes
N = 8*blocks signals.

| 32768 signals, 4-point FFT | ns/transform |
| --- | --- |
| scalar loop | 2.96 |
| **@batch block loop** | **1.29** |

2.3× over scalar, zero shuffles, exact. The human writes one block's
naive FFT and the loop; the compiler delivers the lane-parallel sweep over
all signals. (Stage 3b — AoS input with an auto signal-major transpose at
the boundary — is the remaining step; this 3a form keeps block-SoA data.)

## @batch stage 3b (AoS + transpose): measured, rejected

Stage 3a keeps a block-SoA layout (element k of all signals contiguous), so
the widened butterfly is shuffle-free. Stage 3b would let the human write
the more natural AoS layout (each signal's elements contiguous) and have
@batch insert an 8x8 transpose at the boundary to reach signal-major.

The 8x8 transpose is exact (examples/transpose.wyv `t8`, 24 shuffles), but
a batched 4-point FFT needs it twice — in and out, 48 shuffles round-trip:

| 4-point FFT, 8 signals | ns/transform |
| --- | --- |
| @batch block-SoA (3a) | 1.29 |
| scalar | 2.96 |
| **@batch AoS + transpose (3b)** | **3.67** |

The transpose costs more than the whole batched FFT it feeds — 3b lands
*below scalar*. So @batch keeps the SoA layout (3a); 3b is rejected on the
measurement, not built on a hunch. The @stream lesson again: measure first.
(For a heavier kernel where compute dwarfs the transpose, 3b could pay off
— it stays in the roadmap as conditional, not active.)

## Ladder status (docs/DESIGN.md north star)

- **(a) beat idiomatic Zig: cleared** — 5×–48× L1, 1.5×–6.8× memory-bound.
- **(b) match hand-@Vector Zig: exceeded on all three** — saxpy 1.7×,
  sum 1.5× (after tuning), blur3 1.4×.
- **(c) schedules humans didn't write: cleared** — `wyvec tune` beat
  LLVM's cost model by 1.42× on the reduction; `@interchange` ~20×;
  `@parallel` + `@interchange` + `@fp(contract)` reaches **91.5 GFLOPS,
  86× over naive**, from three contract lines. Open: k-tiling,
  tile×interchange composition, register blocking, tune sweeping
  schedules.

## Fairness notes

- Both sides target the native CPU (clang `-march=native`, Zig native default).
- `-fllvm` is passed explicitly; default-backend numbers were identical.
- Results are cross-checked between implementations before timing. The
  large-n sum differs by ~0.4% between scalar-sequential and 8-lane
  summation — float associativity, with the vectorized order closer to the
  exact value.
