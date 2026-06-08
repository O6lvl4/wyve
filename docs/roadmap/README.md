# Wyve Roadmap

> Auto-generated from directory structure. Run `bash docs/roadmap/generate-readme.sh > docs/roadmap/README.md` to update.
>
> [GRAND_PLAN.md](GRAND_PLAN.md) — 5-phase strategy

## Active

5 items

| Item | Description |
|------|-------------|
| [@batch](active/batch-contract.md) | @batch — write one signal naively, wyvec lays it out signal-major and widens every op to the lanes |
| [Complex FFT](active/complex-fft.md) | @simd to a real FFT — complex (interleaved re/im) arithmetic and float8/16 networks |
| [Lean 4 proofs](active/lean-proofs.md) | wyve-proofs — Lean 4 models of the analyses with soundness theorems |
| [LLVM Surface Coverage](active/llvm-surface-coverage.md) | Coverage matrix — every controllable LLVM semantic, owned as a verified contract |
| [Schedule composition](active/schedule-composition.md) | k-tiling, tile x interchange composition, tune sweeping schedules |

## On Hold

4 items

| Item | Description |
|------|-------------|
| [Almide bridge](on-hold/almide-bridge.md) | Almide x Wyve — auto-derived contracts, both Almide backends served (Rust link + wasm32, SIMD128 verified) |
| [GPU targets](on-hold/gpu-targets.md) | SPIR-V / NVPTX — the same contracts where they matter most |
| [Manual SIMD](on-hold/manual-simd.md) | @vectorize(manual) + float8 + slice loads — explicit lanes inside contract checking |
| [MLIR reconsideration](on-hold/mlir-reconsideration.md) | Trigger — if sema's affine analysis opens the polyhedral textbook, re-evaluate MLIR |

## Done

12 items

<details>
<summary>Show all 12 completed items</summary>

| Done | Item | Description |
|------|------|-------------|
