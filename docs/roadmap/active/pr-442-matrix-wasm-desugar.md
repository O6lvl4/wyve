# PR #442: WASM desugar fallback for fused matrix ops (保全, NOT merged)

2026-06-09. `feat/matrix-wasm-desugar-fallback → develop` on almide/almide.
https://github.com/almide/almide/pull/442 — pushed for review/CI, **not merged**
(merge is the owner's call later; deliberately no admin self-merge this time).

## What it does (the "ideal", reached not patched)

Five fused matrix ops (`scaled_dot_product_attention`, `attention_weights`,
`linear_row_gelu`, `fused_gemm_bias_scale_gelu`, `pre_norm_linear`) had a native Rust
intrinsic but no WASM lowering → direct calls ICE'd the wasm emitter.

- **Desugar fallback (single source of truth).** stdlib `@rewrite(from, to)` already
  drives fusion (forward) for both the egg table and the codegen FusionRule. A new
  build-script consumer (`buildscript/matrix_desugar.rs`) emits the **reverse**
  (`to → from`): fused op + args → un-fused primitive IR. `emit_matrix_call`'s
  `_ => return false` becomes a desugar fallback (rebuild composition, recurse). One
  `@rewrite` now drives fusion AND desugar → ICE structurally impossible for the fusion
  class; future fused ops auto-safe on every target (native fused = opt-in perf, desugar
  = default correctness).
- **Native-only diagnostic.** `qwen3_block_q1_0_kv` (packed-GGUF, tuple return, no
  decomposition) → compile-time error/skip via `program_uses_native_only_matrix_on_wasm`
  (mirrors `program_uses_fan_timeout`). 1-line `NATIVE_ONLY_MATRIX_OPS`, no framework.
- **e2e.** `spec/stdlib/matrix_kernel_e2e_test.almd`: kernel attention+SiLU block vs an
  independent pure-Python golden (tol 1e-5), passes rust + wasm.

Verified: 5 fused ops emit on wasm; full `spec/` green both targets (253 rust, 245+8
pre-existing `wasm:skip`); no regression; qwen3 wasm → clean error/skip not ICE.

Files: `crates/almide-codegen/{build.rs, buildscript/matrix_desugar.rs(new),
src/generated/matrix_desugar_gen.rs(new), src/emit_wasm/calls_matrix.rs, src/lib.rs}`,
`src/cli/{build.rs, commands.rs}`, `spec/stdlib/matrix_kernel_e2e_test.almd(new)`.

## Out of scope — pre-existing bug found, NOT fixed here

**`almide build --target rust` of matrix programs is broken.** The `burn` `AlmideMatrix`
(`runtime/rs/burn/matrix_burn.rs`, an `enum`, linked by the build path) lacks the
flat-ABI compat API (`len`/`Index`/`iter`/`FromIterator`) that codegen emits → E0599/
E0608/E0277. Predates #427 (which fixed only the fast-path `runtime/rs/src/matrix.rs`,
used by `almide test`). Unmodified by this PR. The 4th flat-ABI front (fast-path matrix.rs
✅, wasm desugar ✅ here, burn ❌, plus the original #427 work). Fix needs either compat
API on the burn enum or a burn-specific codegen path — a separate, larger arc.
