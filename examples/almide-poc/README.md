# Almide adoption PoC — the integration shape, and an honest no on matmul

A proof-of-concept for putting Wyve under Almide's numeric runtime
(`almide/runtime/rs/burn/matrix_burn.rs`), and a measurement that redirects
where it should go.

## The integration shape (this works)

`poc.c` calls a Wyve kernel through Almide's `AlmideMatrix::SmallF32` ABI
(row-major f32) and benchmarks it. In the real tree the shape is:

```
almide/runtime/rs/burn/
  matrix_burn.rs      # today's impl — the fallback
  matrix_wyve.rs      # new: unwrap AlmideMatrix -> (ptr,m,n,k), call the Wyve kernel
  wyve/matmul.wyv     # the kernel
build.rs              # racket -l wyve/cli -- build *.wyv -> .ll ; clang -c -> .o ; link
Cargo.toml            # [features] wyve = []
```

```rust
pub fn almide_rt_matrix_mul(a, b) -> AlmideMatrix {
    #[cfg(feature = "wyve")]
    if let Some(r) = matrix_wyve::try_mul(a, b) { return r; }
    matrix_burn::mul(a, b)          // fallback: always correct, always builds
}
```

Properties this buys: Racket is a **build-time** dependency only (the `.o`
is baked into the binary); `--features wyve` off falls back to today's code,
so a Wyve regression can never break Almide; the ABI mapping is one
`unwrap`, and a differential test (Wyve vs the fallback) guards numerics —
the same harness as `bench/diff.c`.

## The honest result: matmul is not Wyve's fight

Measured (this machine, f32, GFLOPS):

| N | Wyve `Full` | Almide hand-ikj | Accelerate sgemm |
|---|---|---|---|
| 16 | 1.6 | 4.1 | 36.9 |
| 64 | 35.2 | 27.3 | 63.8 |
| 256 | 72.0 | 30.9 | 197.5 |
| 512 | 82.6 | 27.7 | 314.9 |

Wyve beats Almide's hand-written ikj (2–2.6× for N≥64) but loses to
Accelerate BLAS everywhere (2.7–3.8×), is slowest of all at N=16 (dispatch
overhead), and accumulates f32 error at large N. Almide already routes to
exactly the right place — hand-ikj for tiny, Accelerate for the rest. There
is no gap for Wyve to fill in plain GEMM.

## Where Wyve actually wins: what BLAS can't do

BLAS does one GEMM. It cannot fuse, and it cannot do quantized weights — so
Almide hand-writes those in `matrix_burn.rs`:

- **fused linear+activation** — `linear_row_gelu`, `silu_mul`: a matmul
  immediately consumed by an activation. BLAS forces a round-trip through an
  intermediate buffer; a Wyve kernel does it in one pass, no buffer.
- **quantized matmul** — `linear_q1_0_row_no_bias` (Q1_0 × f32): BLAS has no
  quantized path at all. This is the real inference hot path.
- **fused transformer block** — `qwen3_block_q1_0_kv`: several ops Almide
  hand-chains; a contract-verified fused kernel is the natural home.

These are hand-written precisely because BLAS can't express them — which is
exactly the seam where a contract-optimized kernel can win. That is the PoC
worth building next: a fused `linear+gelu` Wyve kernel vs Almide's
`linear_row_gelu`, on the inference shapes that matter.
