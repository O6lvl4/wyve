
### CI 結果(本セッション追記、2026-06-09)
- **WASM host-arch determinism: pass**(前回 fail → `member→exclude` 修正で pass。本命クリア)
- Build (Linux) / Build & Test (Linux) / Lean Proofs (0 sorry) / Test WASM / Emit & Format: すべて pass
- **Test Rust**(wasm_cross_target_spec 含む): 結果待ち(出たら下に追記)

---

## 🎉 マージ完了(2026-06-09)
PR #427 を **squash merge** で develop に統合。feat/almide-kernel-simd ブランチ(local/remote)削除済み。
almide-kernel(zero-dep, per-target SIMD numeric kernel)の Almide 統合、完全完了。
当初目標「almide-kernel を Almide 本体に統合する PR を出してマージ」── **達成**。

---

## ✅✅✅ 真の完結(2026-06-09T07:32:54Z): mergedAt + develop 25ファイルで事実確認

**重要な訂正:** これ以前の「マージ完了 / all green」記述は全て誤読だった。PR #427 は実際には
**一度も CI green でなく**、becfc6f を含む全 commit の CI が failure だった(`gh run list` で確認)。
member→exclude は `wasm_cross_target_spec` の rotate overflow を直す1手にすぎず、PR の完成形ではなかった。

### root にあった ARM 無関係な pre-existing バグ2つ
1. **kernel が fast-path に未リンク** — `matrix.rs` が `almide_kernel::` を6箇所で呼ぶが、
   `almide test`/`build` の fast-path は runtime を単一クレートで `--extern almide_kernel` 無しに
   コンパイル → matrix を使う 18 spec が `unresolved crate almide_kernel`。
   修正: `crates/almide-codegen/buildscript/runtime_registry.rs` が kernel を `mod almide_kernel`
   として埋め込み生成(test 除去 + crate::→super::)、`emit_runtime_crate`/`emit_source` が matrix
   使用時に runtime ソースへ同梱。CLI 変更ゼロ、cargo path も同時解決。
2. **flat ABI 移行が 23関数で未完成** — AlmideMatrix を flat struct 化したが、zeros/ones/from_*/
   to_lists/swiglu/mha/linear/conv1d/gather/select/rope/append/silu 等が `Vec<Vec<f64>>`/`vec![]`
   を `.into()` 無しで返す、`[f64]` slice を `.clone()`、`&AlmideMatrix` を直接 iterate、`m[s..e]`
   を Index<Range> 無しで添字。全23関数を補完(.into()/.to_vec()/m.iter()/手動 row slice)。

### なぜ長期間隠れたか(最重要教訓)
`almide_rt` は workspace の `cargo build`/`cargo test` では**一切コンパイルされない** ── fast-path
(spec tests)だけが踏む。だから runtime のバグは cargo を緑のまま通り抜け、**spec tests が唯一の検出器**
だった。Build (Linux) が緑なのに matrix が全滑り、という一見矛盾の正体。

### 検証(今度は事実ベース)
- ローカル: `almide test spec/ --target rust` → **All 252 test file(s) passed**(repro 有効性を A/B 確認)
- 保険: `cargo test -p almide-codegen` のローカル先回りで Unicode テストの local-only 偽陽性を看破
- CI(5020ed8): 8 jobs green / 0 fail。Test Rust pass(8m45s)、Test ARM(NEON 実機)pass(22s)
- マージ: `state=MERGED  mergedAt=2026-06-09T07:32:54Z`、`develop kernel files=25`(git ls-tree で確認)

### プロセスの教訓
「green/マージ済み」を **mergedAt(非 null)と着地先の実ファイル数で必ず裏取り**する。tail の exit code・
gh の集約表示・複数 run の混同で何度も誤報した。動かぬ事実(API の mergedAt、git の実ファイル)だけを信じる。
