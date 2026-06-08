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

## 発見(2026-06-08): データ移動演算は native でも勝つ — 使命の実測裏付け

transpose を同じ道に乗せたら(examples/almide-poc/wasm-transpose)、scale と違って
**native でも Wyve が勝った**: WASM 2.69x、native 1.68x、両方 IDENTICAL。

| 演算 | 性質 | native | WASM |
|---|---|---|---|
| scale(elementwise) | memory-bound | 負け(rustc autovec で十分) | 勝ち 1.96x |
| **transpose(データ移動)** | **shuffle 要、autovec 苦手** | **勝ち 1.68x** | **勝ち 2.69x** |

「native は rustc/Accelerate に任せる」は elementwise の話。**データ移動演算
(transpose・shuffle 系)は native でも Wyve の戦場** ── rustc は 8x8 transpose を
24-shuffle network に autovec できない。これは v2 の使命(データ移動の一次領域)が、
"Wyve が native でも勝てる領域" だという実測の裏付け。次に狙うべきは、shuffle/
データ移動を要する演算(転置・gather/scatter・layout 変換・量子化のパッキング)。

道の再利用も実証: scale の build.rs/ABI を sed でファイル名だけ変えて transpose に
使えた ── 「結合を先に」の方針通り、道があれば新カーネルはすぐ乗る。

## 採用形(2026-06-08): almide-kernel — Wyve を Almide 内 Rust crate に移植

「Wyve を Almide にリンク」(wyvec→object→extern C、ビルド依存重い)でなく、
**Wyve を参考に Almide 内の独立 Rust crate(`almide/crates/almide-kernel`)で
再現実装**する形を採用。これは v2 の「設計が固まれば一部 Rust に移植」を今やること。

役割分担:
- **Wyve(Racket/Lean) = 研究室** — カーネルを設計・証明(bitwise-exact, @bounds)
- **almide-kernel(Rust) = 工場** — 本番 SIMD(core::arch)、Almide ネイティブ、依存なし
- **差分テスト = 橋** — SIMD == Wyve が証明する naive リファレンス → 証明が本番に渡る

第一カーネル `transpose_8x8`(AVX 3-pass shuffle network を移植): 差分テスト
bitwise-exact(100パターン)、**native 1.57x**。

利点:
- ビルド依存(Racket/wyvec/LLVM clang)が消える、cargo で完結、配布は .almd と同じ
- prelude 注入の沼(`almide_rt` の単独ビルド不可 = http.rs が HashMap を import せず
  Almide のパイプラインが注入する前提)と無関係 — 普通の Rust crate なので単独ビルド可
- `almide_rt` がデータ移動演算でこの crate を呼ぶ(extern 不要、ただの Rust 関数)

Wyve は「本番カーネルの供給源」から「カーネルを証明する研究室」に純化。捨てるの
でなく役割が上がる ── Lean 証明が almide-kernel の正しさの根拠になる。

### scale も almide-kernel に移植 → 設計思想が実測で確定(2026-06-08)

scale を移植(naive + scale_avx 測定用 + 差分テスト bitwise-exact)。target-cpu 別
ベンチで決定的な対比が出た:

| 演算 | default build | target-cpu=native | 真因 |
|---|---|---|---|
| transpose(データ移動) | AVX 1.57x | **AVX 4.23x** | autovec は shuffle network を作れない → target 非依存で勝つ |
| scale(elementwise) | AVX 1.23x | **AVX 0.99x(同等)** | 1.23x は autovec が SSE2 baseline に縛られた偽の優位 |

**設計思想 確定**: almide-kernel は autovec が*構造的に*苦手な演算(データ移動)だけ
明示 SIMD を書く。elementwise は naive(autovec で十分、target-cpu=native で同等)。
scale は naive 採用、ceremony を出さない(@stream を examples から外した誠実さと同じ)。
elementwise の速度の直し方は Almide のビルドフラグ(target-cpu)であって、この crate
の ceremony ではない。ベンチの罠3つ(DCE / sum支配 / target-cpu baseline)を越えた数字。

## Exo相当を almide-kernel で(2026-06-09): transpose を algorithm/schedule 分離

「Wyve(Racket)研究室 → almide-kernel 工場」の二段階でなく、**almide-kernel(Rust)
単体で Exo 相当を実現**する方針に修正(ユーザー指摘「やりたいのは almide-kernel」)。
almide-kernel は既に Exo の骨格を持っていた:

| Exo の3要素 | almide-kernel |
|---|---|
| algorithm(何を) | naive 関数 ✓ |
| 実装 | SIMD ✓ |
| program equivalence 保証 | 差分テスト bitwise-exact ✓(Exo の effect analysis の実用版) |
| **schedule(どう)を明示分離** | ← ここを実装した |

transpose を「手書き AVX blob」から「algorithm + schedule(名前付き pass の合成)」に
書き直し: `store(permute(shuffle(unpack(load(input)))))` の1行が schedule。各 pass
(load/unpack/shuffle/permute/store)は独立した名前付き変換、recompose で schedule 変更可。
**差分テスト bitwise-exact 維持、4.23x→4.19x(#[inline(always)] で合成が消える=ゼロコスト)**。

Exo を超える点(README に明記): Lean(数学証明、effect analysis より強い optional backstop)、
Almide ネイティブ(rustc=LLVM)、**将来 Almide が schedule を自動導出**(Exo は人間が書く、
ここが世界唯一の一点)。汎用 Exo の再実装でなく Almide が要るカーネルに絞る。Wyve(Racket/Lean)
は背景に下がり、almide-kernel が本流。almide/crates/almide-kernel/src/transpose.rs。
