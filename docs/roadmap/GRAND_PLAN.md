# Wyve Grand Plan

> **The aim: cover LLVM's entire semantic surface as verified contracts,
> then accelerate the dragon.**
>
> Coverage never means raw exposure — that would be the high-level
> assembler this project was founded against. Every capability enters
> through one of the five contract classes (alias / effect / layout /
> control-flow / emission), arrives with its checking story, and where
> possible its reply is verified against the optimizer's remarks.

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
