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
