# Risk Review

A first adversarial pass at "is this safe to put behind my own code?" — not
a security audit, a busfactor probe. The question that matters for a
contract language: **can a contract be a lie and still compile?** If yes,
the whole premise ("proven, not promised") is hollow.

## What held

**Soundness — every contract bypass tried was refused:**

| Attack | Verdict |
| --- | --- |
| `@vectorize(require)` over a run-time stride `x[i+s]` | rejected (WVN010, not affine) |
| `@effect(writes(y))` hiding a read of `x` | rejected (WVN003) |
| float reduction without `@fp(reassoc)` | rejected (WVN016) |
| out-of-range `shuffle` index | rejected (WVN041) |

**Optimizations don't change results — proven by differential testing.**
The five matmul kernels (examples/matmul.wyv) run on the same 256×256 input
(bench/diff.c):

| kernel | contract | vs naive |
| --- | --- | --- |
| Gemm | `@tile` | bitwise-exact |
| Ikj  | `@interchange` | bitwise-exact |
| Par  | `@parallel + @interchange` | bitwise-exact |
| Full | `+ @fp(contract)` | approx (5.7e-6) — FMA, traded by contract |

Scheduling transforms change nothing bit-for-bit; the *only* kernel whose
result moves is the one that asked to, in a contract. That is exactly the
promise.

**Robustness:** deep expression nesting, empty bodies, and large nests
compile without crash or hang; truncated syntax errors cleanly; every
normative example emits LLVM IR that `clang` accepts.

## What broke (and what we did)

1. **A 64-bit-overflowing integer literal truncated silently** — `(float)1e20`
   emitted `i64 99999999999999999999`, which LLVM wraps mod 2^64. A constant
   quietly becoming a different value is unacceptable in a contract
   language. **Fixed:** sema rejects it (examples/invalid/literal-overflow.wyv).

2. **`@batch` array bounds are unchecked.** A subscript like `x[1000000]`
   compiles; it implies a buffer the contract never states, and an
   out-of-range or sparse index isn't caught — the same class as C's
   missing bounds. This is a known stage-0 boundary, the territory of a
   future `@bounds` contract (roadmap). Not a soundness bug in the
   contracts that exist, but a real limit to document.

3. **No type safety across the C FFI.** Calling a kernel with the wrong
   signature (we passed matmul's 6 params as 4) is a SIGBUS, not a
   diagnostic — ordinary FFI risk, mitigable later by generating C headers
   from the `@interface`.

## Verdict

The thesis holds where it counts: the contracts that exist are proven, the
scheduling transforms are bitwise-exact, and the one result-changing
optimization announces itself. No fatal soundness hole surfaced. The
remaining risks are a documented stage-0 boundary (array length) and
ordinary FFI sharp edges — appropriate for v0.x, and squarely in the
"fine behind your own isolated kernel layer, not yet for third parties to
trust blind" zone. The most honest next step is to dogfood a real kernel.
