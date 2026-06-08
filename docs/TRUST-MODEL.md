# Trust model — what is proven, what is promised

Wyve's banner is "proven, not promised." Honesty requires saying exactly
where that holds and where it doesn't — every place the compiler still
*trusts* rather than *proves*. This is that ledger, written after a deliberate
audit for promised holes. A contract language that hid its own prayers would
be the worst kind of dishonest.

## Proven — the compiler verifies these against the implementation

| Claim | How | Code |
|---|---|---|
| `@noalias` doesn't alias within a kernel | dependence analysis | WVN012/014 |
| `@noalias` holds across a call | argument must itself be `@noalias`; no pointer to two | WVN050 |
| `@effect` names every direct read/write | body is walked, undeclared access rejected | WVN003 |
| **`@effect` names every read/write *through a call*** | the callee's effect propagates up to the caller | WVN003 |
| `@vectorize(require)` is legal | affine dependence analysis | WVN010–018 |
| `@tile`/`@interchange`/`@parallel` change the result by not one bit | **machine-proven in Lean** | `proofs/` |
| `x[i]` is in range, when `@bounds(x: n)` is declared | the index is proven `< n` | WVN070 |
| division by a *literal* zero | seen statically | WVN071 |
| loop induction variables don't change | assignment to a loop var refused | WVN072 |
| `@align` holds across a call | callee's @align must be met by a caller @align | WVN051 |
| no unbounded recursion | call-graph cycles refused | WVN073 |
| `@simd`/`@batch` slices imply no buffer gaps | offsets must densely cover 0..max | WVN041/WVN060 |
| integer literals fit 64 bits | range check | sema |

The effect-through-call row is new: an `@effect` could previously lie by
routing a write through a callee (Outer declares `reads(x)`, calls Inner which
writes `z`). Now the obligation flows up the call —
`examples/invalid/effect-leak-call.wyv` is the normative rejection.

## Promised — trusted, by deliberate design, not yet proven

These are **arithmetic and memory facts below the contract layer**. Wyve does
not prove them, the same stance C takes (and Rust in release). The point is
that this is now an *explicit, enumerated* boundary, not a hidden one.

| Trusted fact | What can go wrong | Stance |
|---|---|---|
| **array bounds, *without* `@bounds`** | `x[i]` out of range reads past the buffer | opt into `@bounds(x: n)` to make it *proven* (WVN070); without it, the calling language owns it. `@batch`'s implied per-block buffer is now *proven-dense* (WVN060): sparse or huge indices that would leave gaps are rejected |
| **integer overflow** | `a * b` wraps mod 2³²/2⁶⁴ | opt into `@checked` to make it a *defined trap* (`*.with.overflow` + `llvm.trap`); without it, unchecked like C/Rust-release |
| **division by a runtime zero** | `x / z`, `z == 0` | a literal zero is rejected (WVN071); a runtime zero is a *defined trap* under `@checked`, else unchecked |
| **cast range** | `(int)hugefloat` is `fptosi` poison | unchecked |
| **`@align(n)` truthfulness** | the caller passes an under-aligned pointer; an aligned load faults | the calling language's obligation (from Rust, the type system) |
| **FFI signature** | wrong arg count/type at the C boundary → SIGBUS | ordinary FFI; mitigable by generating C headers from `@interface` |

## The line, stated plainly

**Wyve proves the contracts it offers — alias, effect, vectorization
legality, schedule equivalence — soundly, now including across calls and (for
scheduling) in Lean.** It does **not** prove arithmetic safety or memory
bounds; those belong to the calling language or to future opt-in contracts
(`@bounds`, `@checked`). The dragon flies exactly where the reins point; it
does not promise the ground is soft if you fall off — and it says so, here,
out loud.

For 1.0, each promised row needs a decision: prove it (a new contract) or
ratify the boundary in the language's stability guarantee. This file is the
agenda for that decision.
