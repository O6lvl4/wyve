# Wyve Roadmap

> Auto-generated from directory structure. Run `bash docs/roadmap/generate-readme.sh > docs/roadmap/README.md` to update.
>
> [GRAND_PLAN.md](GRAND_PLAN.md) — 5-phase strategy

## Active

3 items

| Item | Description |
|------|-------------|
| [CI](active/ci.md) | GitHub Actions — enforce the normative examples publicly |
| [LLVM Surface Coverage](active/llvm-surface-coverage.md) | Coverage matrix — every controllable LLVM semantic, owned as a verified contract |
| [Schedule composition](active/schedule-composition.md) | k-tiling, tile x interchange composition, tune sweeping schedules |

## On Hold

6 items

| Item | Description |
|------|-------------|
| [Almide bridge](on-hold/almide-bridge.md) | Almide x Wyve — auto-derived contracts, both Almide backends served (Rust link + wasm32, SIMD128 verified) |
| [GPU targets](on-hold/gpu-targets.md) | SPIR-V / NVPTX — the same contracts where they matter most |
| [Lean 4 proofs](on-hold/lean-proofs.md) | wyve-proofs — Lean 4 models of the analyses with soundness theorems |
| [Manual SIMD](on-hold/manual-simd.md) | @vectorize(manual) + float8 + slice loads — explicit lanes inside contract checking |
| [MLIR reconsideration](on-hold/mlir-reconsideration.md) | Trigger — if sema's affine analysis opens the polyhedral textbook, re-evaluate MLIR |
| [Stage 2 — ownership](on-hold/stage2-ownership.md) | Prove @noalias at call boundaries — ownership analysis, the last trusted claim |

## Done

10 items

<details>
<summary>Show all 10 completed items</summary>

| Done | Item | Description |
|------|------|-------------|
