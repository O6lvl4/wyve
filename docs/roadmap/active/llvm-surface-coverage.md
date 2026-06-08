<!-- description: Coverage matrix — every controllable LLVM semantic, owned as a verified contract -->
# LLVM Surface Coverage

The aim in one line: cover LLVM's semantic surface as contracts, never
as raw instruction exposure. A row is *done* when it (1) parses as a
contract, (2) has a checking story in sema, (3) lands deterministically
in the IR, and (4) where applicable, has its reply verified in `talk`.

## Function & parameter attributes

| LLVM | Wyve contract | Status |
|------|---------------|--------|
| `noalias` | `@noalias` | ✅ (proof at call boundary = stage 2, on-hold) |
| `nocapture` | implied by kernel model | ✅ |
| `readonly` / `writeonly` | `@effect(reads/writes)` | ✅ verified against body |
| `align(n)` | `@align(n)` on params | ✅ vmovaps verified |
| `dereferenceable(n)` | `@bounds` contract (pairs with `count:`) | ☐ (on-hold/bounds-contract.md) |
| `nonnull` | kernel model (pointers always valid)? | ☐ decide |
| `memory(...)` fn-level | derived from `@effect` | ☐ (LLVM 16+; gate on toolchain) |

## Loop metadata

| LLVM | Wyve | Status |
|------|------|--------|
| `vectorize.enable/width` | `@vectorize(require, width)` | ✅ remark-verified |
| `interleave.count` | `interleave:` | ✅ remark-verified |
| `vectorize.predicate/scalable` | `predicate` / `scalable` | ✅ emitted (unverified) |
| `vectorize.enable=false` | `@vectorize(disable)` | ✅ remark-verified |
| `unroll.count` | `@unroll(require, count)` | ✅ remark-verified |
| `distribute.enable` | `@distribute` | ☐ |
| `unroll_and_jam` | register blocking (Phase 4) | ☐ |
| `licm.*` | — | ☐ listen first |

## FP fast-math flags

| LLVM | Wyve | Status |
|------|------|--------|
| `reassoc` | `@fp(reassoc)` | ✅ |
| `contract` | `@fp(contract)` — FMA unlock | ✅ |
| `nsz` / `arcp` / `afn` / `nnan` / `ninf` | `@fp(...)` family | ✅ |

## Integer poison flags

| LLVM | Wyve | Status |
|------|------|--------|
| `nuw` on induction | automatic | ✅ |
| `nsw` / `exact` | UB-table decision (DESIGN.md Q3) | ☐ |

## Types & control flow

| LLVM | Wyve | Status |
|------|------|--------|
| `float` / `double` | `float` / `double` | ✅ `1.0f` vs `1.0` |
| `i64` / `i32` | `usize` / `int` | ✅ integer literals polymorphic by context |
| `br` (conditional) | `if` / `else` | ✅ scalar branches |

## Instructions

| LLVM | Wyve | Status |
|------|------|--------|
| arith/cmp/GEP/load/store | expressions | ✅ float/double/usize/int |
| `select` | internal (`EMin`) | ✅ internal; surface syntax ☐ |
| `fneg`, rem, bitwise | `-`, `%`, `& | ^ << >>` | ✅ |
| math intrinsics | `min max abs sqrt fma` builtins | ✅ scalar (vector in @simd ☐) |
| conversions (fptosi, ...) | `(type)expr` casts | ✅ float/double/int/usize |
| `call` | kernel-to-kernel (Obj-C message syntax) | ✅ void kernels; `@inline` ☐ |
| vector ops (elementwise) | `@vectorize(manual, width)` | ✅ vector load/op/store + scalar tail |
| vector ops (shuffle) | `@simd` + `floatN` slice loads + `shuffle` | ✅ 4x4 transpose verified |
| atomics / fences | with `@parallel` | ☐ Phase 4 |
| intrinsics | `@intrinsic` (emission class) | ☐ |

## Non-loop metadata

| LLVM | Wyve | Status |
|------|------|--------|
| `!tbaa` | derived from the type system | ☐ high value |
| `!nontemporal` | `@stream` on write-only stores | ✅ via `@vectorize(manual)` — 1.5× memory-bound |
| `if` / `else` | control flow | ✅ scalar branches (WVN017 blocks if under vectorize) |
| branch weights | `@likely` / `@cold` | ☐ (if shipped — now unblocked) |

## Emission class (the fifth contract family — all open)

`@target_feature` (per-kernel -mattr), `@expect_ir` (golden-IR tests),
`@intrinsic`, `@abi`.

## Listening side (remark passes translated in `talk`)

| Pass | Status |
|------|--------|
| loop-vectorize | ✅ |
| loop-unroll | ✅ |
| licm, loop-distribute, slp-vectorizer, inline | ☐ |

## `@stream` × `@vectorize(manual)`: the nontemporal story, resolved

`@stream` lowers write-only stores to `!nontemporal` (write-only proven
from `@effect`; read-modify-write refused, WVN031). The naive lowering —
nontemporal on a *scalar* store — backfires: LLVM 15's loop vectorizer
refuses to vectorize such a loop, and it measured **0.475 ns/elem
(scalar NT) vs 0.411 (vectorized aligned)** — slower.

`@vectorize(manual, width: N)` resolves it. wyvec emits the vector loop
itself (`<N x float>` load/op/store + scalar remainder, WVN040 restricts
this to elementwise loops), so the nontemporal hint rides a *vector*
store and `@align` makes it aligned. Result: `vmovntps` — aligned,
vectorized, cache-bypassing — at **0.279 ns/elem, 1.47× faster than
plain vectorization**, bitwise-identical. The on-hold note became a win.
