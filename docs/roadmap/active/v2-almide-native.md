<!-- description: Wyve v2 — Almide-native: algorithm/schedule 分離・メモリ階層第一級・契約はAlmideから導出・検証付きrewrite -->
# Wyve v2 — Almide-native scheduler

v1 は「LLVM を契約で乗りこなす独立言語」として完成した(proven, not promised,
schedule transforms bitwise-exact in Lean)。v2 はその資産を継承したまま、
**Almide の一次コンピューティング層**に振り切る ── 独立言語をやめ、Almide の
数値意図を受けて、メモリ階層に向けてスケジュールし、検証する専属の層になる。

## なぜ v2 か(v1 の限界)

監査で分かったこと(docs/TRUST-MODEL, Almide PoC, セマンティクス分析):
- Almide は数値演算を `@intrinsic`(Burn/BLAS)に丸投げしていて、**Wyve がスケ
  ジュールすべき affine ループが Almide IR に存在しない**。v1 は「渡す材料」が
  ない場所に立っていた。
- v1 は契約1枚に「計算 × スケジュール × 要求」を混ぜた。Halide/Exo が示した
  「algorithm と schedule の分離」がない。
- データ移動(register/cache tiling)が一次領域だが、v1 はそこを LLVM 任せに
  していた ── BLAS に負けた理由。

## v1 から継承するもの

```
✓ 最適化を契約として proven にする(promised でなく)
✓ schedule 変換は bitwise-exact(Lean: sum_comm / finProdFinEquiv)
✓ failure is a feature(最適化できないなら明示エラー)
✓ LLVM を乗りこなす(竜乗り)
✓ Racket で言語 + Lean で証明、という分業
```

## v1 から変えるもの

| v1 | v2 |
|---|---|
| 独立した `.wyv`(人間が書く) | **Almide の lowering target + schedule 層**(人間/LLM は数値意図を書く) |
| 契約1枚に計算もスケジュールも混在 | **algorithm(何を) / schedule(どう) / proof(正しいか) の3層分離** |
| 限定ループ(@simd straight-line, @vectorize nested 不可) | **affine loop nest 第一級**(iteration space + access function) |
| メモリは部分的(@align/@stream, register tiling は LLVM 任せ) | **メモリ階層を第一級**(tile を register/L1/L2/L3/DRAM の *レベル* で指定) |
| 後から Lean 証明(定理↔実装の橋が未完) | **correct-by-construction な rewrite**(変換の定義に証明を埋める) |
| `@noalias` を人間が書く | **契約は Almide のセマンティクスから導出**(ownership→noalias, effect→effect, shape→bounds) |
| LLVM のみ | ターゲット非依存 schedule → マルチ lowering(LLVM, 将来 SPIR-V/WGSL) |

## Almide 適合

```
Almide  : 数値意図を affine ループに開く + 契約を導出(ownership/effect/shape)
   ↓ algorithm + 契約
Wyve v2 : メモリ階層に向けて schedule + correct-by-construction で検証
   ↓
LLVM(Rust backend 経由で合流) / 将来 GPU
```

接続は Rust backend 経由で LLVM 合流(native/WASM とも、別モジュール問題を回避)。
これにより v1 の「渡す材料がない」問題が、Almide 側の affine 化で解ける。

## 世界の中での位置(正直に)

algorithm/schedule 分離は Halide(2012)、correct-by-construction は Exo(2022)、
マルチレベル+memref は MLIR が既にやっている。v2 が誰もいない場所に立つのは1点:

> **Almide が高レベル数値意図から affine ループ *と契約* を自動導出し、v2 が
> それをメモリ階層に向けて検証付きでスケジュールする。**

Halide/Exo は人間がループとスケジュールを書く。v2+Almide は「意味から、ループ
も契約もスケジュールも導出し、しかも証明する」── この系譜にしか立てない場所。

## 段階

- (0) **algorithm/schedule 分離の概念実証** — done: `experiment/v2/schedule-split.rkt`
  (同じ matmul algorithm に naive/tiled schedule を別々に適用、メモリ階層を語彙に)
- (1) ネスト変換の正確さ(tile の階層的命名、parallel/interchange の位置)
- (2) **correct-by-construction rewrite** — 各 schedule 変換が結果を保つことを
  構造的に保証(v1 の Lean 証明を変換の定義に埋める)。v2 の本丸
- (3) 実コード生成(LLVM IR, v1 の codegen を土台に)
- (4) メモリ階層モデルの本格化(register blocking = BLAS の最深層を schedule で)
- (5) Almide からの algorithm + 契約 自動導出(世界初の一点)

v1 は安定版として保つ(proven 完成、5プラットフォームバイナリ)。v2 は develop で
育てる。設計が固まれば一部 Rust に移植して Almide 本番統合。

## 採用方針(2026-06-08): 結合を先に、最適化は schedule 層で後付け

scale を Almide の Rust backend に WASM で結合できた(examples/almide-poc/wasm-scale):
IDENTICAL、WASM で 1.96x。native では rustc autovec が速い(0.282 vs 0.182、width:4
のまま= AVX の半分しか使っていない等)。

ここで「native でも勝つ」最適化に固執せず、**結合を先に確立する**方針を採る。理由:

- **結合の立て付けは資産** ── AlmideMatrix ABI / build.rs(wyvec→LLVM clang→
  wasm or native object→link) / フォールバック は、一度作れば全カーネルで再利用。
- **最適化は schedule 層** ── width(SIMD幅)、@stream(nontemporal)、@align、tiling
  は、結合した後で差し替えられる。algorithm/schedule 分離の精神そのもの。道が
  通っていれば速さは道の上で鍛えられる。
- **結合は今すぐ価値がある** ── WASM は勝ち、native は同等〜やや遅いが安定で
  IDENTICAL。そして両方に検証(@bounds 範囲証明・bitwise-exact)が付く ── rustc
  autovec にも Accelerate にもない proven。

### 道(立て付け)の再利用

新しいカーネルを同じ道に乗せる手順は scale と同じ:
1. `kernel.wyv` を書く(@vectorize/@bounds など、契約付き)
2. build.rs が wyvec→LLVM IR→clang(wasm32 -msimd128 / native -march=native)→object→link
3. main.rs が AlmideMatrix ABI でラップ、extern C で呼ぶ
4. 差分テスト(IDENTICAL)+ ベンチ

### 後で鍛える最適化(未来、道の上で)

- per-target SIMD 幅(WASM=4=SIMD128 / native=8=AVX2 / =16=AVX512) ── native の幅不足を解消
- `@stream`(write-only 出力の nontemporal store)
- `@align` でアライメント保証
- tiling(register/cache) ── BLAS の最深層、v2 の schedule 語彙

native は当面 rustc/Accelerate にフォールバック(--features wyve オフ)。WASM で
Wyve、native は道だけ通しておき、最適化が乗ったら切り替える。
