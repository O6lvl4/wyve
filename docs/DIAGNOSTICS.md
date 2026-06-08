# Wyve Diagnostics

Every rejection wyvec emits carries a `WVN…` code. A code means a contract
could not be proven against the implementation — the whole point of the
language. Codes are grouped by what they protect.

## Contract surface (WVN001–003)

| Code | Meaning |
| ---- | ------- |
| WVN001 | A kernel in `@implementation` has no matching `@interface` declaration — no contract surface. |
| WVN002 | An implementation's signature doesn't match its `@interface` declaration. |
| WVN003 | **Effect violation**: the body reads or writes a pointer the `@effect` contract doesn't permit (e.g. writing `src` when only `reads(src)` was declared). |

## Vectorization legality — `@vectorize(require)` (WVN010–018)

wyvec's own affine dependence analysis decides whether the requested
vectorization is legal, independent of LLVM.

| Code | Meaning |
| ---- | ------- |
| WVN010 | The kernel has no loop to vectorize, or a subscript isn't affine in the induction variable. |
| WVN011 | Nested loops under `@vectorize(require)` (not supported in stage 0). |
| WVN012 | Cannot prove two pointers don't alias — add `@noalias`. |
| WVN014 | **Loop-carried dependence**: an iteration reads a value an earlier iteration wrote (e.g. `x[i]` reads `x[i-1]`). Proven sound in Lean — see `proofs/`. |
| WVN015 | A float reduction reorders additions; grant `@fp(reassoc)`. |
| WVN016 | A scalar is overwritten across iterations (a recurrence). |
| WVN017 | `if` inside a `@vectorize(require)` loop (needs predication; not in stage 0). |
| WVN018 | A kernel call inside a `@vectorize(require)` loop. |

## Scheduling legality — `@tile` / `@interchange` / `@parallel` (WVN020–025)

These transforms are applied by wyvec above LLVM; the legality is proven
before any IR is emitted.

| Code | Meaning |
| ---- | ------- |
| WVN020 | A tiled/interchanged array is both read and written in the nest — can't prove it safe. |
| WVN021 | A tile write subscript isn't the injective row-major form `i*B + j`. |
| WVN022 | `@tile` shape error, or an illegal combination of schedule contracts. |
| WVN023 | A scalar is carried across the tiled loops. |
| WVN024 | `@interchange` couldn't recognize the reduction pattern, or the bounds/subscripts aren't the required form. |
| WVN025 | `@parallel` can't prove the loop's iterations independent (non-injective write, cross-iteration read, carried scalar, or `return`). |

## Layout / emission (WVN030–031)

| Code | Meaning |
| ---- | ------- |
| WVN030 | `@align(n)` where `n` is not a power of two. |
| WVN031 | `@stream` with no provably write-only target (it needs `@effect`, and a read-modify-write array can't stream). |

## Explicit vectors — `@vectorize(manual)` / `@simd` (WVN040–041)

| Code | Meaning |
| ---- | ------- |
| WVN040 | `@vectorize(manual)` shape error: needs a width, takes no other knobs, and accepts only a pure elementwise loop. |
| WVN041 | `@simd` shape error: only vector locals, slice loads/stores, `shuffle`, `cmul`, and vector arithmetic — no loops, no scalars, no schedule contracts. Also covers vector-width and shuffle-index checks. |

## Aliasing across calls — stage 2 (WVN050)

| Code | Meaning |
| ---- | ------- |
| WVN050 | A call breaks the callee's `@noalias`: an argument isn't `@noalias` in the caller, or the same pointer reaches two `@noalias` parameters (calling a kernel in place). The outermost caller's `@noalias` is the calling language's job — Rust's borrow checker discharges it. |

---

Uncoded `error:`/`note:` lines are ordinary type and syntax errors
(undefined variable, wrong argument count, non-numeric operand, reserved
word, and so on) — they don't get a WVN number because they aren't
about a contract.
