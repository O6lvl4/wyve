# Wyve Roadmap

> Auto-generated from directory structure. Run `bash docs/roadmap/generate-readme.sh > docs/roadmap/README.md` to update.
>
> [GRAND_PLAN.md](GRAND_PLAN.md) — 5-phase strategy

## Active

5 items

| Item | Description |
|------|-------------|
| [CI](active/ci.md) | GitHub Actions — enforce the normative examples publicly |
| [@fp flags family](active/fp-flags-family.md) | Complete the @fp contract family — contract (FMA), nsz, arcp, afn, nnan/ninf |
| [LLVM Surface Coverage](active/llvm-surface-coverage.md) | Coverage matrix — every controllable LLVM semantic, owned as a verified contract |
| [@parallel](active/parallel-contract.md) | @parallel — the proofs that allow tiling allow threading; multiply by core count |
| [Schedule composition](active/schedule-composition.md) | k-tiling, tile x interchange composition, tune sweeping schedules |

## On Hold

6 items

| Item | Description |
|------|-------------|
| [Almide bridge](on-hold/almide-bridge.md) | LLM-generated Wyve kernels — hallucinated optimizations die at WVN diagnostics |
| [GPU targets](on-hold/gpu-targets.md) | SPIR-V / NVPTX — the same contracts where they matter most |
| [Lean 4 proofs](on-hold/lean-proofs.md) | wyve-proofs — Lean 4 models of the analyses with soundness theorems |
| [Manual SIMD](on-hold/manual-simd.md) | @vectorize(manual) + float8 + slice loads — explicit lanes inside contract checking |
| [MLIR reconsideration](on-hold/mlir-reconsideration.md) | Trigger — if sema's affine analysis opens the polyhedral textbook, re-evaluate MLIR |
| [Stage 2 — ownership](on-hold/stage2-ownership.md) | Prove @noalias at call boundaries — ownership analysis, the last trusted claim |

## Done

7 items

<details>
<summary>Show all 7 completed items</summary>

| Done | Item | Description |
|------|------|-------------|
| 2026-06-07 | [Zig benchmark — rungs (a) and (b)](done/zig-benchmark.md) | North-star rungs (a)(b) vs Zig — 5-48x idiomatic, beats hand-@Vector on all three kernels |
| 2026-06-07 | [Stage 0 compiler](done/stage0-compiler.md) | wyvec in Racket — lexer/parser/sema/codegen, Objective-C grammar to textual LLVM IR |
| 2026-06-07 | [Schedule search (tune)](done/schedule-search-tune.md) | wyvec tune — schedule search; beat LLVM's cost model 1.42x on the reduction |
| 2026-06-07 | [Optimizer knobs as verified contracts](done/optimizer-knobs.md) | @vectorize(width/interleave/predicate/scalable/disable) + @unroll, all remark-verified |
| 2026-06-07 | [Conversation layer](done/conversation-layer.md) | #lang wyve, talk/run, REPL with retractable contracts — the conversation with LLVM |
| 2026-06-07 | [@tile](done/tile-transform.md) | @tile — first scheduling transform above LLVM, legality proven (WVN020-023), float-exact |
| 2026-06-07 | [@interchange](done/interchange-transform.md) | @interchange(p, j) — scalar expansion + interchange; ~20x on matmul, float-exact, rung (c) cleared |

</details>

