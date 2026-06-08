# wasm-transpose — second kernel on the same seam, and native wins too

Reuses the wasm-scale seam (same build.rs / AlmideMatrix ABI, only the .wyv and
the wrapper differ) to put Wyve's 8x8 transpose under Almide. Working both
ways, and — unlike scale — Wyve wins on native too.

## Result (this machine)

```
            Wyve      Almide      speedup
WASM:       0.191s    0.514s      2.69×
native:     0.158s    0.266s      1.68×
correctness: IDENTICAL (both)
```

## Why transpose wins on native (but scale didn't)

```
scale (elementwise)  : memory-bound; rustc autovec is enough → native loses
transpose (data move): needs a shuffle network; autovec is poor at strided/
                       irregular access → Wyve wins on native too
```

This is the empirical confirmation of Wyve v2's mission (the data-movement
primary region): **"native goes to rustc" is the elementwise story — data-
movement ops (shuffles) are Wyve's ground even on native.** rustc can't
autovectorize an 8x8 transpose into a 24-shuffle network; Wyve writes it
explicitly (and proves it bitwise-exact).

## Seam reuse

The build.rs and ABI are scale's, byte-for-similar:
```
build.rs : wyvec → LLVM clang (wasm32 -msimd128 / native -march=native) → object → link
src/main : AlmideMatrix::SmallF32 ABI, extern "C" Transpose_t8
```
Only `transpose.wyv` and the wrapper are new. The seam is a reusable road; a
new kernel is a new payload on it.

## Note: 8x8 fixed

This is the 8x8 tile (Almide's matrices tile into 8x8). Arbitrary-size
transpose = the 8x8 tile in a block loop with index swap — a future extension
on the same road.
