<!-- description: @parallel — the proofs that allow tiling allow threading; multiply by core count -->
# @parallel

The sleeping giant. `tile-check` already proves loops parallel
(write-only arrays, injective stores, no carried scalars) — the same
proof legalizes splitting the outer loop across threads.

```objc
@effect(reads(a, b), writes(c))
@parallel(i)
@interchange(p, j)
```

- Lowering: outer-loop chunks dispatched to a thread pool (GCD on
  macOS, pthreads elsewhere) — runner/talk unchanged.
- Expected: ×physical cores on compute-bound kernels (24 GFLOPS → ~90
  on the i7-7700).
- Refusals reuse WVN020/021/023 verbatim.
- Composition question: @parallel(i) × @interchange(p, j) — i stays
  outermost in both, so they compose; prove it in sema, not in prose.
