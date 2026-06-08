# wasm-scale — Wyve seamlessly linked into Almide's Rust backend (WASM)

The first real adoption: Almide's `almide_rt_matrix_scale` replaced by a Wyve
kernel, on the WASM backend where there is no Accelerate. Working, verified,
and faster.

## Result (this machine, wasmtime, wasm32-wasip1)

```
Wyve kernel SIMD128 (f32x4):  yes
correctness vs Almide scale:  IDENTICAL
Wyve seam:                    0.518 s
Almide (rustc autovectorized): 1.015 s
→ 1.96× faster
```

Explicit-contract SIMD128 beats the autovectorizer again (saxpy was 1.55×,
scale 1.96×) — on the backend where the BLAS wall is absent.

## The seam

```
src/main.rs   AlmideMatrix::SmallF32 { rows, cols, data: Vec<f32> }  (Almide's ABI)
                └ extern "C" WyveScale_scale  ← the Wyve kernel, called through the ABI
build.rs      scale.wyv → wyvec → LLVM IR → LLVM clang (-target wasm32-wasi
                -msimd128 -O2) → wasm object → llvm-ar → cargo links it
scale.wyv     @bounds + @vectorize(width:4): proven in-range, SIMD128
```

Both Rust and Wyve become LLVM-family wasm objects, linked into one module —
one linear memory, no cross-module data shuffling. This is the Rust-backend
path from docs/roadmap/active/v2-almide-native.md, made concrete.

## Build notes (the sharp edges hit)

- **Use LLVM `clang`/`llc`, not `zig cc`** for the Wyve object: zig's wasm
  object isn't link-compatible with `rust-lld` ("section too large"). Same
  LLVM family links cleanly.
- **`llc` alone doesn't vectorize** — Wyve emits `@vectorize` loop metadata
  that the optimizer (opt, folded into `clang -O2`) turns into f32x4. `llc`
  is codegen only → scalar. Use `clang -O2` (opt + llc).
- **rustup toolchain**: a non-rustup `rustc` on PATH (`~/.local/bin`) lacked
  the wasm std; pin to the rustup toolchain.
- **ABI**: Wyve's `usize` is `i64` → the `count` param is `u64` on the Rust
  side. Pointers are `i32` on wasm32 (matches). Per-target `usize→i32`
  lowering would let it be plain `usize`.

## Build & run

```
PATH=$(rustup which cargo | xargs dirname):$PATH cargo build --release --target wasm32-wasip1
wasmtime target/wasm32-wasip1/release/wasm-scale.wasm diff     # IDENTICAL
wasmtime target/wasm32-wasip1/release/wasm-scale.wasm wyve     # bench
wasmtime target/wasm32-wasip1/release/wasm-scale.wasm almide   # bench
```
