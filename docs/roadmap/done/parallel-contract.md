<!-- description: @parallel — the proofs that allow tiling allow threading; multiply by core count -->
<!-- done: 2026-06-08 --># @parallel

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

## Done

WVN025 proves independence (single 0..bound loop, writes injective in
i — `i` or `i*B+j` form, cell-local reads, no carried scalars, no
return). Lowering: wrapper packs args → dispatch_apply_f(NULL queue) →
worker unpacks → alwaysinline body keeping the original noalias attrs
(inlining preserves them as scoped metadata, so inner loops still
vectorize). macOS/libdispatch v1; pthreads fallback when a non-Apple
host appears. Measured: 22 → 89 GFLOPS (3.9× ≈ 4 physical cores),
bitwise-exact; with @fp(contract) 91.5 GFLOPS = 86× over naive.
