# Wyve

**Contracts for the optimizer.**

Wyve is a static semantics language one layer above LLVM IR — higher-level
than LLVM IR, lower-level than Zig. You don't write programs in Wyve; you
write kernels, and with them, the contracts that make those kernels
optimizable.

Not a safer C. Not a nicer LLVM IR. A contract language for code generation.

> LLVM IRより高級で、Zigより低級。人間が最適化契約を書くための静的意味論言語。

## The idea

Optimizers are theorem provers starved of theorems. They spend most of their
time re-deriving facts the programmer knew all along: these pointers don't
alias, this function only writes there, this loop carries no dependence. And
when the proof fails, you get a scalar loop and no explanation.

Wyve inverts this. The facts *are* the source code:

```objc
@effect(reads(x, y), writes(y))
@vectorize(require, width: 8)
+ (void)saxpy:(float)a
            x:(@noalias const float *)x
            y:(@noalias float *)y
        count:(usize)n;
```

This is not a hint block. It is a permission slip with teeth:

- `@noalias` — proven against the language's ownership rules, not taken on faith
- `@effect` — the implementation is checked against it; writing anywhere else is a compile error
- `@vectorize(require)` — if the loop cannot vectorize, **compilation fails**, and the compiler tells you why

## The five contract classes

| Class        | Contracts                                                              |
| ------------ | ---------------------------------------------------------------------- |
| Alias        | `@noalias`, `@alias(scope)`, `@borrow`, `@owned`                       |
| Effect       | `@pure`, `@readonly`, `@effect(reads(…), writes(…))`, `@captures(none)` |
| Layout       | `@repr(c)`, `@align(n)`, `@soa`, `@packed`                             |
| Control flow | `@vectorize(require)`, `@unroll`, `@cold`, `@likely`, `@fp(reassoc)`   |
| Emission     | `@expect_ir`, `@target_feature`, `@intrinsic`, `@abi`                  |

## Failure is a feature

In C, an optimization that doesn't happen is silent. In Wyve, a required
optimization that can't happen is an error with a reason:

```
error[WVN014]: vectorization required, but the loop carries a dependence:
               x[i] reads x[i - 1] written in the previous iteration
  --> examples/invalid/dependence.wyv:26
note: remove @vectorize(require) or restructure the recurrence
```

See [`examples/invalid/`](examples/invalid/) — files in this directory MUST
be rejected by the compiler. They are as much a part of the language as the
files that compile.

## Design principles

1. **Contracts are proven, not promised.** An unchecked `@noalias` is just
   undefined behavior with better ergonomics — worse than C, because the
   language would *encourage* you to write it. Every contract is verified
   against the implementation.
2. **Legality is decided by Wyve, not by LLVM's mood.** `@vectorize(require)`
   is checked by Wyve's own dependence analysis over a restricted loop form.
   LLVM's optimization remarks are a regression layer for catching toolchain
   bugs, not the definition of the language. Wyve's semantics must not change
   when LLVM's version does.
3. **Objective-C grammar, zero runtime.** Message syntax with labeled
   arguments makes effect contracts readable: `reads(x, y), writes(y)` names
   the same things the call site names. No `objc_msgSend`, no classes at
   runtime — every send is a static call.
4. **`@interface` is the contract surface.** What was once a compilation-model
   artifact becomes a semantic boundary: the `@implementation` must be proven
   to satisfy its `@interface`, or it does not compile.

## Anatomy

| Name       | Role                                                                  |
| ---------- | --------------------------------------------------------------------- |
| `Wyve`     | the language                                                          |
| `wyvec`    | the compiler                                                          |
| `.wyv`     | source files                                                          |
| `Wyveness` | the degree to which code exposes semantics the optimizer can trust    |

## Status

**Pre-stage-0.** The syntax and contract vocabulary are being designed on
paper — [`examples/`](examples/) is the current frontier. Open design
questions live in [`docs/DESIGN.md`](docs/DESIGN.md).

Roadmap:

- **Stage 0 — transcription**: parse `.wyv`, emit LLVM IR with the contracts
  translated to attributes and metadata. Contracts trusted, not yet checked.
- **Stage 1 — required optimization**: `@vectorize(require)` violations become
  compile errors with the optimizer's reason attached.
- **Stage 2 — checked contracts**: ownership and effect analysis make every
  contract a proof obligation. This is the language.
