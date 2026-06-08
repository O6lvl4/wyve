# Design questions

Open decisions, roughly in the order they block progress. Settled decisions
move to the bottom.

## North star

Outrun Zig on the dragon's own back. Wyve and Zig land on the same LLVM, so
the headroom is not in the backend — it is in what the language can afford
to tell it. Three reins:

1. **More fuel on real code.** Zig's performance annotations (`noalias`,
   `@setFloatMode`) are unchecked — lie and you get UB — so real codebases
   use them timidly. Wyve's contracts are proven, so the language can
   saturate every kernel with `noalias`, `inbounds`, `nuw`, and per-kernel
   FP freedom by default. Idiomatic Wyve should out-optimize idiomatic Zig
   everywhere. (Fortran's old victory, with verification.)
2. **Scheduling above LLVM.** The affine kernel domain admits transforms
   LLVM's generic pipeline doesn't attempt: tiling, interchange, fusion,
   unroll-and-jam — expressed as contracts (`@tile`, `@interleave`,
   `@fuse`), proven legal by wyvec's own analysis, applied before LLVM ever
   sees the IR. The Halide lesson: a domain-restricted language can beat a
   general optimizer on its own backend.
3. **Search past the single compile.** Emission contracts fan out variants
   (widths, unrolls, tilings); the runner benchmarks them; the winner is
   pinned. "Fastest" is a point — Wyve searches its neighborhood. (The
   FFTW/ATLAS move, as a language feature.)

The benchmark ladder: (a) beat idiomatic Zig on every kernel in
`examples/`, (b) match hand-`@Vector` Zig, (c) beat it where search finds
schedules humans didn't write.

## Open

### 1. Which slice of Objective-C grammar is in?

"Objective-C grammar verbatim" cannot mean all of it — Obj-C is a strict
superset of C, and some of C's grammar exists only to serve semantics Wyve
rejects. Current thinking:

- **In**: `@interface` / `@implementation` / `@end`, method declarations,
  message-send syntax, C expression and statement grammar (restricted),
  C declarators.
- **Out (for now)**: properties, categories, the preprocessor, blocks.
- **Undecided**: protocols. `@protocol` could be repurposed as a *contract
  bundle* — a named set of effect/alias obligations a kernel conforms to.
  Tempting, but not needed for stage 0.
- **Reserved**: `in`, `out`, `inout`, `oneway`, `bycopy`, `byref` are
  protocol qualifiers in Obj-C's grammar and cannot be parameter names.

### 2. Receiver model

Kernels are stateless, so examples currently use class methods (`+`) and
treat `@interface` as a module namespace. Is `-` (instance methods) ever
meaningful? Possible future answer: a "kernel object" holding pre-bound
buffers or a compiled specialization. Not needed now; `+` only until proven
otherwise.

### 3. Expression semantics

Syntax identical to C, semantics redefined: every C undefined behavior must
become either *defined* or *rejected*. The table to write:

| C says UB | Wyve says |
| --- | --- |
| signed overflow | ? (trap / wrap / compile-time range proof) |
| shift ≥ width | ? |
| division by zero | ? |
| out-of-bounds index | ? (bounds contracts? `count:` is already in every signature) |
| pointer casts | rejected — no arbitrary casts, full stop |

The `count:` parameter showing up in every kernel signature is a hint that
bounds may want to be a first-class contract (`@bounds(x, count)`), not a
convention.

### 4. Type vocabulary

Examples currently mix C names (`float`, `const float *`) with Wyve
additions (`usize`). Decide: keep C's spellings for familiarity, or move to
`f32`/`f64`/`u64`? Leaning toward keeping C spellings — the grammar is
Obj-C's, the types should look like they belong in it. `usize` stays.

### 5. Loop forms eligible for `@vectorize(require)`

The self-owned dependence analysis only works over a restricted loop form
(affine bounds, affine subscripts). Define precisely which `for` loops
qualify, and what the diagnostic says when a loop falls outside the form
(distinct from "inside the form but carries a dependence").

### 6. Explicit SIMD (`@vectorize(manual)`)

**Shipped (elementwise).** `@vectorize(manual, width: N)` makes wyvec emit
the vector loop itself — `<N x float>` load/op/store plus a scalar
remainder — instead of leaving vectorization to LLVM. WVN040 restricts it
to pure elementwise loops (offset-0 subscripts, no locals, no reductions).
Its first job: let `@stream`'s nontemporal hint ride a *vector* store,
which the LLVM-driven path could not do (the scalar-nontemporal loop
won't vectorize). Measured 1.47× over plain vectorization, bitwise-exact
(bench/NOTES.md).

**Shipped (shuffle-shaped).** `@simd` kernels are straight-line explicit
vector code: vector locals (`floatN`, N∈{2,4,8,16}), slice loads/stores
(`a[off : N]`), and `shuffle(a, b, lanes…)` → LLVM `shufflevector`. WVN041
checks vector widths, slice lengths, and shuffle index ranges; @effect and
@noalias still apply. Verified on hardware: a 4x4 transpose (8 SSE shuffles)
and a twiddled radix-2 butterfly (`w * hi` broadcasts the scalar via
vbroadcastss, then vector fadd/fsub). That is the full set of FFT moving
parts — permutation (`shuffle`), lane arithmetic (`+ - * /` on `floatN`),
and scalar broadcast (a scalar float in a vector expression splats to the
vector width). The verification model held throughout: the human writes the
lanes, wyvec checks everything around them — Scopes' philosophy inside
Wyve's checking. Still open: `float8`/`float16` networks for wider kernels,
and complex arithmetic (interleaved re/im) for a real FFT.

## Settled

- **Stage 0 parser: own recursive descent, no clang.** The grammar slice
  turned out small enough that a dependency-free parser was cheaper than the
  pre-lexer + libclang plumbing originally considered. The clang-hijack route
  remains an option if the slice grows toward full C expressions.
- **Stage 0 grammar slice (implemented)**: `@interface`/`@implementation`/
  `@end`, class methods (`+`) with labeled selectors, contracts
  (`@effect`/`@vectorize`/`@fp`) on interface declarations only, `@noalias`
  as a parameter qualifier, statements `for`/`return`/assignment/local
  declaration, expressions over `float`/`usize` with subscripts on pointer
  parameters. Everything else in question 1 stays open.

- **Name**: Wyve. Compiler `wyvec`, sources `.wyv`.
- **No intermediate IR with a name.** Wyve lowers directly to LLVM IR.
  Contract checking is a compiler phase, not a representation. (An earlier
  draft named an IR "Sella" — rejected.)
- **Contracts are proven, not promised.** Unchecked `@noalias` is UB with
  better ergonomics; the language must verify or refuse.
- **Legality is Wyve's, not LLVM's.** `@vectorize(require)` is decided by
  wyvec's own dependence analysis. LLVM optimization remarks are a
  regression layer against toolchain bugs, never the definition.
- **`@interface` is the contract surface**; `@implementation` is checked
  against it.
- **`examples/invalid/` is normative**: files there must be rejected, with
  the diagnostics shown in their headers.

## Tracking LLVM (the inherited dependency)

Wyve emits LLVM IR, so it inherits a dependency on the LLVM toolchain — the
fate of every IR-targeting language (Rust, Swift, Julia, Clang). LLVM evolves:
IR syntax shifts (opaque pointers), intrinsics change how they lower
(`llvm.tanh` does not lower to libm on LLVM 15 — we hit this and dropped
`tanh`, building it from `exp` instead). This section is how Wyve carries that
dependency deliberately rather than by hope.

**Two layers, only one of which tracks LLVM.**

- **Verification (sema) is LLVM-independent by design.** `@vectorize`
  legality, the dependence analysis, schedule equivalence — these are Wyve's
  own, proven in Lean, decided over a restricted loop form. A new LLVM version
  cannot change what Wyve accepts or what a contract means. This is the point
  of "legality is decided by Wyve, not by LLVM's mood."
- **Codegen (IR emission) does track LLVM.** The IR text and intrinsic set are
  LLVM's, so they move when LLVM moves. This is the layer that needs a gate.

**The gate: `scripts/llvm-smoke.sh`** (run in CI). It compiles every normative
example through the actual `clang` and checks the object for unlowered
`@llvm.*` intrinsics — exactly the `tanh` failure class, which offline
IR-string tests can't see (it only surfaces at link time). When LLVM's
behavior drifts, CI fails loudly instead of shipping a broken kernel. The
codegen dependency becomes a *tested regression boundary*, not a prayer —
the same "proven, not promised" discipline, applied to the toolchain.

**Conventions that keep the surface small.** Wyve emits a narrow, stable
subset of IR (opaque pointers, plain arithmetic, a handful of intrinsics) and
leaves optimization to contracts rather than exotic IR constructs — so there
is little surface to break when LLVM changes. The Lean toolchain and Racket
package are version-pinned; the LLVM the smoke test runs against is whatever
the platform ships, which is precisely what we want to keep honest about.
