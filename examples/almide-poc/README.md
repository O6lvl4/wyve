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

## Update: the fused PoC was measured too — also a loss

A fused `linear+gelu` Wyve kernel (matmul + sigmoid-approx gelu in one pass,
`@parallel`) vs Almide's path (Accelerate sgemm + a gelu sweep), f32:

| r | ni | no | Wyve fused | Almide (sgemm+gelu) | speedup |
|---|---|---|---|---|---|
| 1 | 2048 | 2048 | 4436 us | 533 us | 0.12× |
| 8 | 2048 | 2048 | 7394 us | 1591 us | 0.22× |
| 32 | 2048 | 2048 | 23246 us | 3120 us | 0.13× |
| 8 | 512 | 512 | 632 us | 134 us | 0.21× |
| 128 | 2048 | 2048 | 100503 us | 6908 us | 0.07× |

4.5–14× **slower**, exactly as predicted: fusing the gelu sweep saves ~`10/k`
of the work (≈2% at k=512), and that can't pay back losing the GEMM itself
to Accelerate by 3–4×. The bigger the batch, the more GEMM-dominated, the
worse it gets. **Fusion doesn't change the verdict — anything GEMM-dominated
belongs to BLAS.**

Also surfaced: `@llvm.tanh` doesn't lower to libm on this toolchain (LLVM
15), so a tanh-based gelu fails at link. Wyve now offers `exp` (which lowers
to `expf`) and not `tanh`; sigmoid/silu/gelu are built from `exp`
(examples/sigmoid.wyv).

## The standing conclusion

GEMM and GEMM-fused-with-anything go to Accelerate. The one seam left for
Wyve is what BLAS structurally cannot do: **quantized matmul**
(`linear_q1_0_row_no_bias`, Q1_0 × f32 — the real inference hot path, which
Almide hand-writes because BLAS has no quantized GEMM). That contest is
Wyve vs a hand-written loop, not Wyve vs Accelerate — the only place the
numbers could go the other way. The integration shape (above) is unchanged;
only the target kernel moves there.
