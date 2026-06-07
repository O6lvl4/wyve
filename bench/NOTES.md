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
| sum    | 0.030  | 0.954 (32×)   | 0.954 (32×)  | 0.030 (tie)  |
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

## Ladder status (docs/DESIGN.md north star)

- **(a) beat idiomatic Zig: cleared** — 1.5×–32× across every kernel and size.
- **(b) match hand-@Vector Zig: cleared and exceeded** — saxpy 1.7× and
  blur3 1.4× faster (the contract lets LLVM interleave and schedule the
  tail; the hand-SIMD human didn't bother), sum within noise.
- **(c) schedules humans didn't write: open** — needs `@tile`/`@fuse` and
  the variant-search runner.

## Fairness notes

- Both sides target the native CPU (clang `-march=native`, Zig native default).
- `-fllvm` is passed explicitly; default-backend numbers were identical.
- Results are cross-checked between implementations before timing. The
  large-n sum differs by ~0.4% between scalar-sequential and 8-lane
  summation — float associativity, with the vectorized order closer to the
  exact value.
