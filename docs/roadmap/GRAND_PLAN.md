# Wyve Grand Plan

> **The aim: cover LLVM's entire semantic surface as verified contracts,
> then accelerate the dragon.**
>
> Coverage never means raw exposure — that would be the high-level
> assembler this project was founded against. Every capability enters
> through one of the five contract classes (alias / effect / layout /
> control-flow / emission), arrives with its checking story, and where
> possible its reply is verified against the optimizer's remarks.

## The ideal

The one-line target the whole project aims at:

> **A human or an LLM declares intent as a contract; the implementation
> stays naive; the compiler searches for the fastest schedule, proves it,
> and pins it — and regression becomes impossible. Optimization as a
> contract, not a prayer.**

Four layers, nearest to farthest:

1. **The experience.** You write a naive kernel. The compiler says: "this
   reaches 180 GFLOPS with `@parallel @interchange @tile @fp(contract)`,
   measured on your machine — sign it?" One line, and it can never silently
   slow down: a toolchain that betrays the contract fails the build with a
   reason. `tune` is the searcher, the contract is the certificate, `talk`
   is the conversation.
2. **The language.** Every contract proven (stage 2 closes the `@noalias`
   call boundary — *proven, not promised*, end to end). Reach extended to
   the edge of the provable: complex numbers, control flow, the conv /
   stencil / reduction / FFT classes. Never a general-purpose language —
   the restriction *is* the moat.
3. **The stack.** Almide derives the contracts mechanically from its own
   semantics (Perceus ownership → `@noalias`, effects → `@effect`), so the
   human writes no contracts at all. LLM writes Almide; type lies die in
   Almide, performance lies die at WVN. One contract language, CPU and GPU.
4. **The idea.** *Fast code can prove why it is fast* — as a matter of
   course. Today's performance runs on superstition (`-O2` will handle it;
   I checked godbolt; it vectorized last release). Wyve replaces that with
   contracts and proofs, down to a Lean-checked soundness for the analyses
   themselves (`wyve-proofs`): proven all the way down. CompCert did this
   for compiler correctness; Wyve does it for optimization.

The honest gap: layers 2–4 are years of work (ownership proofs are
research-grade; GPU is a second backend; the Almide derivation and the Lean
proofs are large). What is settled is the *direction* — every step so far is
backed by a measurement or a rejection. The bet no one else is making: not
"faster," not "safer," but **giving performance a proof.**

## Phase 1 — Conversation ✅

Speak in contracts, hear in remarks. `#lang wyve`, `wyvec
check/build/talk/run`, the REPL with retractable contracts
(`ask #:without-noalias ... #:force`). Done 2026-06.

## Phase 2 — Schedules above LLVM ✅

Transforms LLVM's pipeline never attempts, proven by wyvec on the AST:
`@tile` (strip-mine + interchange, WVN020-023), `@interchange`
(scalar expansion + interchange, float-exact, ~20× on matmul), and
`wyvec tune` (schedule search that beat LLVM's own cost model 1.42×).
North-star ladder vs Zig cleared at every rung (bench/NOTES.md).

## Phase 3 — Surface coverage (active)

Sweep LLVM's controllable semantics systematically:
[active/llvm-surface-coverage.md](active/llvm-surface-coverage.md) is
the tracking matrix. Each row lands as a contract + verification, not
as an instruction alias. Listening side widens in step (more remark
passes translated back into contract vocabulary).

## Phase 4 — Acceleration

The multipliers that ride on coverage: `@parallel` (the proofs that
allow tiling allow threading — ×cores), `@fp(contract)` (FMA),
k-tiling and tile×interchange composition, register blocking, and
`tune` sweeping schedules the way it sweeps widths.

## Phase 5 — Depth

Proof depth: Lean 4 models of the analyses (`wyve-proofs`), stage 2
ownership (prove `@noalias` at call boundaries — the last trusted
claim). Target depth: GPU (SPIR-V/NVPTX), where alias/effect contracts
matter most. Ecosystem depth: the Almide bridge — LLM-generated
kernels whose hallucinations die at WVN diagnostics.

---

For the strategic fork reached after measuring against BLAS (speed vs verification; native vs WASM vs quantized), see [STRATEGY.md](STRATEGY.md).
