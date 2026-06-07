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
| `align(n)` | `@align(n)` on params | ☐ |
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
| `contract` | `@fp(contract)` — FMA unlock, ~2× on matmul | ☐ **next** |
| `nsz` / `arcp` / `afn` / `nnan` / `ninf` | `@fp(...)` family | ☐ |

## Integer poison flags

| LLVM | Wyve | Status |
|------|------|--------|
| `nuw` on induction | automatic | ✅ |
| `nsw` / `exact` | UB-table decision (DESIGN.md Q3) | ☐ |

## Instructions

| LLVM | Wyve | Status |
|------|------|--------|
| arith/cmp/GEP/load/store | expressions | ✅ (subset) |
| `select` | internal (`EMin`) | ✅ internal; surface syntax ☐ |
| `fneg`, rem, shifts, bitwise | operators | ☐ |
| conversions (fptosi, ...) | casts with rules | ☐ |
| `call` | kernel-to-kernel + `@inline` contract | ☐ |
| vector ops | `@vectorize(manual)` + `float8` | ☐ on-hold (needs a shuffle-shaped kernel) |
| atomics / fences | with `@parallel` | ☐ Phase 4 |
| intrinsics | `@intrinsic` (emission class) | ☐ |

## Non-loop metadata

| LLVM | Wyve | Status |
|------|------|--------|
| `!tbaa` | derived from the type system | ☐ high value |
| `!nontemporal` | `@stream` on stores — memory-bound wins | ☐ |
| branch weights | `@likely` / `@cold` | ☐ (needs `if` first) |

## Emission class (the fifth contract family — all open)

`@target_feature` (per-kernel -mattr), `@expect_ir` (golden-IR tests),
`@intrinsic`, `@abi`.

## Listening side (remark passes translated in `talk`)

| Pass | Status |
|------|--------|
| loop-vectorize | ✅ |
| loop-unroll | ✅ |
| licm, loop-distribute, slp-vectorizer, inline | ☐ |
