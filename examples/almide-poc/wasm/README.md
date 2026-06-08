# WASM — the other backend, where there is no Accelerate

native is settled: Almide routes GEMM to Accelerate and Wyve can't beat it.
But Almide also ships to **WASM**, and WASM has no Accelerate — the numeric
code there is naive loops or a compiler's autovectorizer. That removes the
wall Wyve kept hitting.

## Measured (this machine, wasmtime 42, zig 0.16)

A width-4 saxpy (`saxpy.wyv`, `@vectorize(require, width: 4)`) compiled to
wasm32 with `zig cc -target wasm32-wasi -msimd128`, vs the same loop left to
Zig's own `-O2 -msimd128`:

| | wasmtime wall time |
|---|---|
| Wyve, explicit SIMD128 | 0.34 s |
| naive, Zig autovectorized | 0.53 s |

**1.55× faster — and the baseline is already f32x4-vectorized by Zig** (13
`f32x4` ops in its module), so this is explicit-contract SIMD beating an
autovectorizer, not beating scalar. The Wyve kernel emits real SIMD128:
`f32x4.mul`, `f32x4.add`, `v128` loads/stores.

## ABI note (settle before real use)

Wyve's `usize` is `i64` in the IR; wasm32's `size_t` is 32-bit. A `count`
parameter mismatches (i64 vs i32) and traps unless the caller passes
`unsigned long long`. Per-target lowering of `usize` (i32 on wasm32) is the
clean fix; for now the C shim declares the size arg as `unsigned long long`.

## The corrected adoption direction

- **Almide native (Rust):** Accelerate owns GEMM. Wyve adds nothing. Skip.
- **Almide WASM:** no Accelerate — Wyve's verified SIMD128 beats the
  autovectorizer. **This is where Wyve belongs in Almide.**

Next: a WASM matmul (Wyve SIMD128 vs naive/autovec in wasm) on inference
shapes — the same contest, on the backend where Wyve actually wins.
