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
