<!-- description: Almide x Wyve — auto-derived contracts, both Almide backends served (Rust link + wasm32, SIMD128 verified) -->
# Almide bridge

Wyve as the kernel layer under Almide — the missing leg of Almide's
"Path to World #1" performance research (surpass hand-written Rust via
semantic-aware optimization).

## Backend mapping (both verified)

| Almide backend | Path | Status |
|----------------|------|--------|
| Rust | Almide -> Rust source -> cargo links Wyve .o (the examples/rust-caller recipe; fits Almide's Rainbow Bridge @extern packaging) | works today — 80 GFLOPS measured from Rust |
| WASM | same .ll -> `zig cc -target wasm32-wasi -msimd128` -> real wasm module | **verified 2026-06-08**: f32x4/v128 SIMD128 fires — but only with `width: 4` (SIMD128 = 4 floats; a width-8 contract silently stays scalar) |

WASM caveats: contracts need target-appropriate values (per-target
contract sets, or `tune` per target); `@parallel` needs a wasm lowering
(wasi-threads / workers); usize is i64 in Wyve IR vs wasm32's 32-bit
size_t — ABI detail to settle.

## The deep play: auto-derived contracts

Almide's compiler can EMIT .wyv for numeric hot paths with the
contracts derived mechanically from its own semantics — no human
annotations:

- Perceus ownership  -> `@noalias`
- effect system      -> `@effect(reads/writes)`
- value immutability -> read-only sets

"General-purpose languages can't prove the contracts" has one
exception: a general-purpose language whose semantics were designed to
be provable. That is Almide by construction.

## The full stack

```
LLM writes -> Almide (MSR, semantic guarantees)
                |- Rust/TS/WASM (general code)
                `- Wyve (numeric kernels, contracts auto-derived)
                     `- LLVM (verified) -> native / wasm32
```

Type/effect hallucinations die in Almide; performance hallucinations
die at WVN diagnostics. Modification survival rate, end to end —
semantics through speed.


## PoC measured (2026-06-08): matmul is not the seam — fused/quantized is

examples/almide-poc demonstrates the integration shape (AlmideMatrix::SmallF32
ABI -> Wyve kernel, feature flag, build.rs, BLAS fallback) and measures it.
On plain f32 GEMM Wyve beats Almide's hand-ikj (2-2.6x, N>=64) but loses to
Accelerate sgemm everywhere (2.7-3.8x) and is slowest at N=16. Almide already
routes optimally (hand-ikj tiny / Accelerate else) — no gap in plain GEMM.

The seam is what BLAS *can't* do, which Almide hand-writes in matrix_burn.rs:
fused linear+activation (linear_row_gelu, silu_mul — one pass, no intermediate
buffer), and quantized matmul (linear_q1_0_row_no_bias — the real inference
hot path). Next PoC: a fused linear+gelu Wyve kernel vs linear_row_gelu on
inference shapes. The integration shape carries over unchanged.

## Corrected by measurement (2026-06-08): native loses, WASM is the seam

native GEMM goes to Accelerate (Wyve loses 2.7-3.8x at matmul, 4.5-14x at
fused linear+gelu — examples/almide-poc). But WASM has no Accelerate. A
width-4 saxpy in wasm32 (zig cc -msimd128) runs 1.55x faster as Wyve
explicit SIMD128 than as Zig's own autovectorized loop (0.34s vs 0.53s,
wasmtime) — explicit-contract SIMD beating an autovectorizer, exactly the
native @stream/manual story but on the backend where the BLAS wall is
absent. Adoption direction corrected: skip Wyve on native (Accelerate owns
it), adopt on WASM. ABI: usize is i64 vs wasm32 size_t i32 — settle by
per-target lowering. Next: WASM matmul on inference shapes.
(examples/almide-poc/wasm)
