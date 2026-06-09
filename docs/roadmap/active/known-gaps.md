<!-- description: Wyve v2 / almide-kernel の既知の穴 — ベンチで勝ったが production を阻む欠点を優先順位付きで -->
# Wyve v2 / almide-kernel — known gaps

ベンチでは Rust native/wasm と Almide 自身に勝ち、flat ABI で Almide に統合して
実際に動いている(`v2-almide-native.md` の達成ログ参照)。だが「**実推論で、全デバイス
で、正しく速い**」にはまだ穴がある。「勝った」を誇張しないため、正直に・優先順位付き
で記録する。

## P0 — production を阻む致命的な穴

### G1. ARM NEON 未対応 ★最重大
almide-kernel の SIMD は **x86 AVX と wasm simd128 のみ**。ARM NEON は naive フォールバック。
- **影響**: Apple Silicon(Mac)・iPhone ネイティブアプリ・モバイルの大半(ARM)で SIMD が
  効かない。「モバイル推論で独走」は ブラウザ(wasm)では成立するが、**ネイティブ ARM では
  成立しない**(誇張だった)。
- **解決**: per-target dispatch に NEON ブランチ追加。`exp_pd_neon`(f64x2)、q1_0/transpose の
  NEON 版。fast-exp 共有基盤があるので silu/softmax/gelu は芋づるで効く。

### G2. wasm の正しさテストが無い
wasm 版(silu/softmax/gelu/q1_0/matmul の simd128)は native の `cargo test` で走らない(cfg)。
正しさは **ベンチの sink 一致で間接確認しただけ**。
- **影響**: wasm SIMD の f64x2 実装にバグがあっても検出されない。
- **解決**: wasm-bindgen-test か wasmtime test runner で wasm の差分テストを CI に。

### G3. 実推論 end-to-end 未検証
回帰は `matrix_test`(2x3 等の小行列)のみ。`examples/llama_block.almd`(実 LLM)を**一度も
走らせていない**。
- **影響**: fast-exp 近似(~1e-6)の累積誤差が生成品質(perplexity)に効くか不明。ベンチも
  全部 合成データ(i%100)で、実重みの分布で同じ速度が出るかも未検証。
- **解決**: llama_block を実重みで走らせ、perplexity / 生成テキストを scalar 版と比較。

## P1 — 重要だが致命的でない

### G4. flat ABI の網羅テスト不足
AlmideMatrix を flat struct に変えたが、テストは 12 個。attention components(split_cols/
concat_cols/slice_rows/rope/select_rows 等)が flat で正しいか、edge case(空/ragged 行列)は
未検証(互換 trait の Index/iter のエッジ)。
- **解決**: 全 64 演算の差分テスト(flat 実装 vs 旧 nested の出力一致)。

### G5. BLAS は macOS のみ
Accelerate のみ(build.rs で have_blas cfg)。Linux(OpenBLAS)/Windows(MKL)は未対応 →
register-tiled fallback。
- **解決**: blas-src 等でクロスプラットフォーム BLAS、各 OS の BLAS を build.rs で条件リンク。

### G6. per-target の結果差(再現性)
native(AVX f64x4)と wasm(simd128 f64x2)で reduction の lane 数が違う → 加算順序が違う →
結果が微妙に違う(float reassoc)。
- **影響**: 同じモデルが native と wasm で微妙に違う出力。推論の再現性。
- **解決**: within-tolerance を明示して許容するか、reduction 順序を per-target で固定する。

## P2 — 改善余地

- **G7. register-tiled matmul は 4x4**(packing/cache blocking なし、wasm は naive)。dense は
  BLAS にルーティング済みなので native の影響は小だが、BLAS なし環境(wasm 密 matmul)は遅い。
- **G8. fast-exp の極端値未検証**。大きい x / NaN / Inf で正しいか、範囲外で壊れるか不明。
- **G9. Lean 証明が almide-kernel に橋渡しされてない**。Wyve の Lean(permutation/reduction の
  数学証明)は almide-kernel のテスト(Rust 差分/網羅)に降りていない。「proven」は差分/網羅止まり。
- **G10. ベンチが1回測定**(warmup/統計なし、マシン負荷で変動)。
- **G11. Almide の変更が git 管理外**(matrix.rs/build.rs の履歴が追えない、backup は /tmp のみ)。

## 優先順位の推奨

```
G1(NEON) → G3(実推論 end-to-end) → G2(wasm テスト) → G5(クロス BLAS) → G4(flat 網羅) → 残り
```

**G1(ARM NEON)が最も効く** — 巨大な ARM 市場(Apple Silicon/iPhone/モバイル)を取り戻し、
fast-exp 共有基盤の芋づるがそのまま効く。次いで G3(実推論検証)で「ベンチでなく本物で速くて
正しい」を確認し、G2(wasm テスト)で wasm の正しさを保証する。

## 一行サマリー

達成は本物(ベンチで勝ち、Almide に統合)。だが **ARM 抜け・wasm テスト無し・実推論未検証**の
3つが「全デバイスで正しく速い」を阻む。ベンチの数字を production の事実にするのが次の仕事。

---

## G1 進捗(2026-06-09): exp 系の ARM NEON 着手

silu/softmax/gelu に NEON 版を追加。`exp_pd_neon`(float64x2_t, range reduction + Taylor +
2^k via vcvtq_s64_f64)が共有基盤 ── NEON は FMA(vfmaq_f64)も f64→i64(vcvtq_s64_f64)も native
で、wasm より AVX 版に近い。**aarch64-apple-darwin クロスコンパイル成功**(型/intrinsics 通る)、
native(x86)回帰 OK。

**残り**: ① q1_0_packed/transpose の NEON(別の手: bit-unpack/shuffle)、② **ARM 実機での
正しさ・ベンチ検証**(現状は x86 マシンなのでクロスビルド確認まで、実行は未)。G1 完了には ARM
マシン(or CI runner)での実測が必須。

### G1 進捗2(2026-06-09): q1_0 も NEON、exp系+量子化が aarch64 クロスビルド

q1_0_packed に NEON(f64x2、2 sign bits/group を ±0.0 mask の整数 veor で XOR)。**量子化が
ARM NEON の本命**(bit-unpack は autovec/scalar 不可、Apple Silicon/モバイルの量子化推論)。
transpose は正直に naive フォールバック(f64x2=2 lane で shuffle 利益が AVX f64x4 の半分、8x8
NEON transpose は複雑な割に効果薄)。**aarch64-apple-darwin クロスビルド成功**(silu/softmax/
gelu/q1_0)、native x86 全テスト OK。

**G1 コードは揃った(exp系+量子化の NEON)。残るは ARM 実機検証のみ**(私は x86 マシンなので
クロスビルド止まり)。Apple Silicon Mac か CI ARM runner で cargo test + bench を回せば G1 完了。

---

## G-PR. PR #427 は汚染で draft 差し戻し(2026-06-09) — 要クリーン作り直し

PR #427(almide/almide, almide-kernel 統合)を出したが CI の **Test Rust が fail → draft に
差し戻した**。原因は**ローカル Almide[git 管理外、GitHub HEAD と違う版]から移植したことによる
汚染**:
- `wasm_cross_target_spec`(spec/wasm_cross/ 全 spec 横断)で **99 equal / 1 unexpected** ──
  int 系 spec が「attempt to shift right with overflow」(src/main.rs:287 = 生成コード)で panic。
- **真因 最有力: map signature 差分(Rc<dyn Fn> → impl Fn)** が混入(ローカルが HEAD と違う版
  だった証拠)。generic monomorphization が別 spec の codegen を変えた可能性。
- **私の検証が浅かった**: ローカルで matrix_test しか走らせず、wasm_cross_target_spec を未検証
  だった(「Test Rust green ならマージ」と言ったが、その Test Rust を自分で通してなかった)。

### 作り直し手順(腰を据えてやる)
1. develop の clean clone から新ブランチ。
2. crates/almide-kernel をコピー(純粋な新規、**これは正しい**ので流用可)。
3. runtime/rs/build.rs(BLAS)コピー、Cargo.toml(依存)、ルート Cargo.toml(workspace member)。
4. **matrix.rs は develop 版に flat ABI + 配線「だけ」を適用**(ローカル版コピー禁止 ──
   α[map signature/変数名]を持ち込まない)。
5. rust_runtime.rs(generated, 追跡)は matrix.rs から正しく再生成させる(手で触らない)。
6. **ローカルで `cargo test wasm_cross_target_spec` まで通す**(今回サボった検証)。
7. CI 全 green → flat ABI diff 最終レビュー → マージ。

素材は PR #427 のブランチ(feat/almide-kernel-simd)に残存。almide-kernel crate と flat ABI の
コアは正しい、**α だけ除けばよい**。教訓: git 管理外からの移植は HEAD との差分を必ず diff 検証、
全 CI 相当をローカルで通してから PR。

---

## G-PR 解決(2026-06-09): 真因 = almide-kernel 依存が生成プロジェクトの debug overflow を on にした

30+ 手のデバッグで真因確定:
- **私の almide-kernel 依存(almide_rt の Cargo.toml)が、`almide build` の生成プロジェクトの debug
  build を overflow-checks=on にした**(メカニズムは依存解決の深部、症状は完全確定)。
- **Almide の int.rs の rotate/wrap は overflow-off(wrapping shift)を前提に設計**されてる
  (`rotate_left(1,1,65)=3` は `1>>64` が wrapping で `>>0`=1 → `2|1=3`)。
- 私の変更が overflow-on にしたことで、`v >> (bits-n)` が bits>=64 で panic。
- これが wasm_cross_target_spec(int_wrap_rotate_width, contract C-048)を 1 fail させた。

**切り分けの軌跡**: develop=pass / map戻し=fail / rust_runtime戻し=fail / build.rs削除=fail /
tempdir=fail / develop almide=pass / `almide build --release`=pass / debug=fail
→ 「私の almide-kernel 依存が debug build を overflow-on にした」と確定。

**修正**: GENERATED_CARGO_TOML(src/cli/mod.rs)の全 variant の `[profile.dev]` に
`overflow-checks = false` を明示。develop の overflow-off 挙動を保証し、Almide の int runtime の
wrapping-shift 前提を満たす。私の almide-kernel 依存の副作用を打ち消す + Almide の設計前提を明文化。
個別検証: feat almide で int_wrap_rotate_width が `2,2,3,4,9,49,2,1` を正しく出力(panic なし)。

**教訓**: ① 移植で map α(Rc→impl Fn)混入 + ② almide-kernel 依存が build codepath を変えた。
両方とも「全 CI 相当(特に wasm_cross_target_spec)をローカルで通してから PR」で防げた。
PR #427 最終形: almide-kernel + flat ABI + 配線 + map(develop版) + profile.dev 修正。

### G-PR 完全決着(2026-06-09): CI 全 green、マージ可能

PR #427(14c54b6)の全 CI ジョブ green:
- **Test Rust: pass**(wasm_cross_target_spec 含む ← 今回の修正対象、本命)
- Build (Linux): pass / Build & Test (Linux): pass / Lean Proofs: pass /
  Test WASM: pass / WASM host-arch determinism: pass / Emit & Format: pass

修正(GENERATED_CARGO_TOML の [profile.dev] overflow-checks=false)が CI で確認、ローカルの
全 runtime テスト(wasm_cross_target_spec 153.74s ok)と一致。PR #427 は ready for review、
マージ可能。当初「Test Rust green ならマージ」と言って fail → draft 差し戻し → 30+手の二分探索
→ 真因特定 → 修正 → 今回こそ全 CI green。長い道のりだったが、クリーンな状態で決着。

**教訓(確定版)**: ① git 管理外からの移植は HEAD diff を必ず検証(map α 混入を防ぐ)。
② 「green ならマージ」と言う前に、その green を自分でローカルで確認する(全 CI 相当、特に
wasm_cross_target_spec のような cross-target 不変条件)。③ 新規依存が build codepath(profile/
overflow-checks)を変えうる ── generated project は独立 workspace + 明示 profile であるべき。
