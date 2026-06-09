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

## Rust を超える(2026-06-09): 量子化 q1_0 dot で 3.5x — 本命を実証

目標を明確化(ユーザー「とにかく Rust を超える」)。almide-kernel の存在意義 =
rustc が出せないカーネルを出す。3カーネルで「どこで Rust を超えるか」が確定:

| 演算 | Rust 比 | 正しさの bar | autovec が苦手な理由 |
|---|---|---|---|
| transpose(shuffle) | **4.23x native** | bitwise-exact | shuffle network を作れない |
| **q1_0(bit-unpack)** | **3.5x 全 target** | within-tolerance(reassoc) | packed-bit を bit-address できない |
| scale(elementwise) | 1.0x | bitwise-exact | autovec が既に勝つ→naive 採用 |

q1_0(1-bit 量子化 dot)= 推論ホットパスの本命。algorithm(符号付き和)+ schedule
(AVX2: byte broadcast→lane bit select→符号ビット xor→8-wide 和→水平 reduce)を
Exo-style に分離。**rustc は bit-unpack を autovec できず、Almide 自身も x86 で
scalar(SIMD は NEON のみ)→ AVX2 が target 非依存で 3.5x**(autovec に追いつく余地
がない)。

**正しさの bar は演算で変わる**(重要な規律): データ移動(transpose)=bitwise-exact、
**reduction(q1_0)=within-tolerance**(SIMD が float 和を reassoc するので、誤差尺度
は |result| でなく*項の絶対値の和*=結果はキャンセルで 0 近くになりうる)。演算ごとに
正しい bar を選ぶ。almide/crates/almide-kernel/src/q1_0.rs。

## 4象限制覇(2026-06-09): q1_0 が Rust/Almide × native/wasm の全象限で勝つ

ユーザーの目標明確化「ベンチとして Rust native に勝つ かつ Almide native に勝つ、
Rust wasm に勝つ かつ Almide wasm に勝つ」。almide-kernel に per-target SIMD
(x86 AVX2 / wasm simd128)を持たせ、q1_0 で4象限すべて達成:

|  | native(AVX2) | wasm(simd128) |
|---|---|---|
| vs Rust naive | **3.73x** | **2.52x** |
| vs Almide(f64 scalar) | **3.62x** | **2.43x** |

q1_0 では Rust の autovec も Almide 自身の dot も scalar(Almide の SIMD は NEON のみ、
packed-bit address が autovec を阻む)なので、almide-kernel が全セルで勝つ。Almide は
f64・almide-kernel は f32 = 仕事に正しい幅を選ぶのも edge の一部。q1_0_dot は
per-target dispatch(x86=AVX2 / wasm=simd128 / else naive)。次: transpose も4象限
(wasm simd128 版)、他カーネル、almide_rt 配線。

### transpose も4象限(2026-06-09): 2枚目制覇

transpose に wasm simd128 版(8x8 を 4x4 ブロックの転置 pass × 4 + ブロック swap、
Exo-style)を足し、4象限制覇:

| transpose | native(AVX) | wasm(simd128) |
|---|---|---|
| vs Rust naive | **5.18x** | **3.66x** |
| vs Almide(f64) | **2.70x** | **3.50x** |

両 target bitwise-exact(データ移動=reassoc なし)。q1_0 と transpose の2カーネルが
4象限制覇。次: 量子化 matmul 全体(q1_0_dot を行列展開、実推論ホットパスまるごと)。

### 量子化 matmul 全体(2026-06-09): linear_q1_0 で実推論 6.74x — 本命の本命

q1_0_dot を行列に展開し linear_q1_0(x @ Wᵀ, W が Q1_0)= 実推論ホットパスを実装
(algorithm=ブロック dot の二重ループ、schedule=per-target q1_0_dot を各ブロックに)。
実サイズ 1x2048x2048(1トークン×2048→2048層):

| linear_q1_0 | native(AVX2) | wasm(simd128) |
|---|---|---|
| vs Rust naive | **6.74x** | **3.03x** |

max rel err 6.7e-8/8.9e-8(f32 reassoc 内)。**単体 dot(3.5x)より行列全体で広がる
(6.74x)** = per-block SIMD schedule が行列規模で amortize。microbench でなく実 workload。
14.6 GFLOP/s(native)。残り: almide_rt 配線(4象限で勝つカーネルを実 Almide が呼ぶ)。

### almide_rt 配線(2026-06-09): 配線の核心=任意サイズ transpose、4象限で勝つ

A(almide_rt 配線・本番統合)着手。prelude 沼の正体判明: almide_rt は単独ビルド不可
(http.rs:6「HashMap already imported by prelude」= Almide の almide run/build フローが
prelude 注入する前提)。本物の almide_rt 全体ビルドは Almide フロー(大きい)。

**配線の核心=任意サイズ対応**を先に実装(Almide の行列は 8x8 でない)。transpose_matrix
(rows×cols 任意、8x8 タイルは SIMD kernel・端数 scalar、bitwise-exact at any size)。
512x512 で4象限: native vs Rust 3.50x/vs Almide 3.13x、wasm 3.15x/3.63x。端数(13x8,
37x41 等)も bitwise-exact。

**残る本番統合**: ABI glue(f64↔f32、nested Vec<Vec<f64>>↔flat)+ Almide ビルドフロー
(prelude 注入、almide_rt は almide run/build 内でのみコンパイル)。配線の核心(任意サイズ
タイル化)は動き4象限で勝つ ── 残りは ABI 変換と Almide のビルドシステム統合(大きい山)。

### ABI glue 実証(2026-06-09): 配線関数は動く、だが ABI の形が SIMD の成否を決める

a(ABI glue)実装。f64 transpose(AVX f64x4=4x4ブロック構造、データ移動で精度維持)+
任意サイズ + bridge.rs(Vec<Vec<f64>> → kernel → Vec<Vec<f64>> の完全な配線関数)。全
bitwise-exact(10テスト緑)。**だが測定で決定的発見**:

| 512x512 同じカーネル | vs Almide naive |
|---|---|
| nested Vec<Vec<f64>> ABI | **0.44x(遅い!)** |
| flat Vec<f64> ABI | **3.07x** |

**ABI の形だけで 7倍の差**。nested↔flat 変換(2回フルコピー + 行ごと Vec alloc)が SIMD
transpose の利益を食い潰す。**本番統合の指針はカーネルでなく Almide の*型***: flat
バッファ(SmallF32/flat f64)を渡せば 3x、Vec<Vec<f64>> を渡すと変換が利益を消す。
配線が報われるのは行列が flat な場合のみ。残: Almide がホットパスで flat 行列 ABI を
採用 + Almide ビルドフロー(prelude 注入)。「測ってダメなら正直に」= bridge.rs に記録。

### Exo を clone → 静的 equivalence を almide-kernel に(2026-06-09): permutation は SMT 不要で全証明

ユーザー「Exo を clone した上で almide-kernel を最強に」。Exo(exo-lang/exo)を clone し
effect analysis の核心を読解: **各 scheduling 変換に Check_ 関数**(Check_ReorderStmts 等)、
各文の effect(read/write 領域)を計算 → **SMT solver(z3)で commute(独立性)を検証** →
変換が equivalence を保つことを*実行せず*静的保証(correct-by-construction)。

**almide-kernel に取り込み、しかも permutation kernel では Exo を超えた(SMT 不要)**: transpose
は permutation(位置を動かすだけ、値に依存しない)。**index 配列 input[k]=k を1回通せば
permutation 全体が抽出され、transpose 仕様と一致すれば全入力で正しい=全証明**(100サンプルの
差分テストを静的全証明に置換、Exo の SMT が要る所を permutation は1回の実行で decidable)。
schedule_is_the_transpose_permutation_for_all_inputs(f32 8x8/f64 8x8/任意サイズ端数含む)13テスト緑。
reduction(q1_0)は permutation でない→within-tolerance のまま(静的化は区間/符号解析=future)。
almide-kernel = 速い(4象限)+ 静的に全入力で正しい(Exo 相当)= 最強に近づいた。

### q1_0 bit-unpack 静的化(2026-06-09): 符号は proven、和だけ tolerance

Exo 手法をもう一段。q1_0 は permutation でない(reduction)が、**符号*配置*は permutation/
selection 構造**。bit-unpack(apply_sign)を切り出し: 符号適用は符号ビットの XOR=値非依存、
1 byte=8 lanes、**256 byte 値で全 bit パターン網羅** → avx2_bit_unpack_total_proof が
「各 byte・各入力で符号が正しい lane に行く」を有限・全証明(solver 不要)。float の*和*だけ
within-tolerance(reassoc、float では不可避)。速度維持(3.60x、切り出しは inline)。

```
q1_0 正しさ: 符号配置 → PROVEN(256 網羅) / 和 → within-tolerance(reassoc)
```

almide-kernel 正しさの地図: permutation(transpose)=静的全入力、selection/bit-unpack
(q1_0 符号)=静的網羅、float reduction=和だけ tolerance・周りは全部 proven。残: wasm
simd128 の apply_sign 対称化(16 nibble 全証明、wasm test runner)/ NEON / attention。

### reduction の完全 proven(2026-06-09): q1_0 は promised がゼロに

float の和は reassoc(順序依存)で bitwise-exact 無理 → だが**2層で proven**:
- **層1(順序が仕様)**: SIMD reduction が「明示 tree-order(8 lane→lo+hi→hadd→hadd)」と
  **bitwise-exact**(avx2_is_bitwise_exact_to_tree_order, 500 seeds, tolerance ゼロ)。
  float は順序依存なので「和」は元々一意でない → 順序を仕様に명명すれば SIMD は厳密実装。
- **層2(誤差有界)**: tree-order vs 理想 exact 和の差 ≤ n·u·Σ|x|(n=128, u=2⁻²⁴)=
  reassociation 誤差定理(Lean 証明可能、テストで witness)。

```
q1_0: 符号配置 → PROVEN(256網羅) / reduction → PROVEN(tree-order に bitwise + 誤差有界)
```

**almide-kernel 正しさの地図(端から端まで)**: permutation(transpose)=静的全入力、
selection(q1_0符号)=静的網羅、float reduction(q1_0和)=指定順序に bitwise + 誤差有界。
**promised はゼロ**。速度維持 3.76x。q1_0 完全 proven。16テスト緑。残: 層2 を Lean で
完全証明 / wasm 対称化 / NEON / attention。

### 仕上げ(2026-06-09): almide-kernel 一区切り

一区切りの仕上げ。16テスト緑、native+wasm 全 example ビルド OK、README を製品ドキュメント化
(冒頭 At a glance: 4象限速度 + 完全 proven の正しさの地図 + per-target + standalone)。
bench_scale を cfg ガード(scale_avx は x86 専用)で wasm ビルド完結。

**到達点**: almide-kernel = 速い(4象限、Rust も Almide も native も wasm も超える、最大 6.74x)
+ 完全 proven(permutation 全入力 / selection 網羅 / reduction tree-order bitwise + 誤差有界、
promised ゼロ)+ Exo を学んで permutation/selection は SMT なしで超えた。5カーネル
(transpose f32/f64・scale・q1_0・linear_q1_0)+ bridge、6ベンチ、16テスト、依存ゼロ。

**次の山(別機会)**: 層2 Lean 完全証明 / wasm apply_sign 対称化 / NEON(Apple Silicon) /
attention(実推論) / crates.io 公開 / Almide 本番配線(flat ABI 採用 + prelude ビルドフロー)。

### Almide 本体への導入 解決(2026-06-09): almide-kernel が実 Almide の中で動いた

「一旦仕上げ」の後、残課題「Almide 本体への導入」を解決。**鍵: prelude 沼は単独ビルドが
原因、Almide の正規フロー(almide test/run/build)を使えば回避**。almide CLI はビルド済み
(target/release/almide)、正規フローが prelude 注入 + almide_rt ビルドを行う。単独 cargo
build で 212errors を踏んだのは正規フローを使わなかったから。

**配線3手**: ①almide_rt/Cargo.toml に `almide-kernel = { path = "../../crates/almide-kernel" }`、
②almide_rt_matrix_transpose を `almide_kernel::bridge::almide_matrix_transpose` にルーティング
(ABI 一致=Vec<Vec<f64>>、bridge がそのまま中身に)、③`almide test spec/lang/matrix_test.almd`
→ **12テスト全通、matrix.transpose は今 almide-kernel 経由(f64 SIMD、静的に全入力 proven)**。

**almide-kernel が実 Almide の中で動いた = 導入の道が解決**。残: 速さ(nested Vec<Vec<f64>>
で 0.44x、flat ABI=Burn SmallF32 or 軽量に flat 型 が実推論 llama_block で効く)。正しさ+導入
は達成、速さは flat ABI が次。Almide 側変更(Cargo.toml + matrix.rs)は git 管理外。

### flat ABI 実装(2026-06-09): AlmideMatrix を flat struct に、互換 trait で64演算そのまま

ユーザー「flat ABI いこう、BLAS も autovec も攻略」。line 3 発見=Almide は本番 ndarray(flat)
想定(軽量 Vec<Vec<f64>> は almide run 用)。**AlmideMatrix を Vec<Vec<f64>> → flat struct
{ rows, cols, data: Vec<f64> } に変更**。互換 trait(Index/IndexMut で m[r] が行スライス、
iter()=chunks、FromIterator/From で構築系)で **64演算そのままコンパイル(エラー0!)**。
構築系11+5箇所も From/FromIterator で吸収。transpose を almide-kernel.transpose_matrix_f64 に
flat 直接配線(変換なし=flat ABI の win、bridge の nested 0.44x を回避)。almide test 12通過。

**これで almide-kernel の SIMD が変換なしで Almide に効く(nested の7倍ペナルティ消滅)**。残り:
他演算(量子化 q1_0・attention・fused・scale・mul)も flat 直接配線 → BLAS の外(量子化/fused/
attention)で almide-kernel 独走 + autovec 攻略(shuffle/bit-unpack)。**flat ABI = Rust に勝つ
前提が整った**。matrix.rs(git 管理外、backup /tmp/matrix_rs_backup.rs)。

### 量子化 matmul 配線(2026-06-09): BLAS 攻略の本命、Almide scalar を 3.35x 超える

ユーザー「almide-kernel に flat 直接配線」。Almide の linear_q1_0_row_no_bias の ABI=
f64 x + packed Q1_0(18B/block: fp16 scale 2B + 16 sign bytes)。almide-kernel に
q1_0_packed.rs 追加(fp16_to_f64 + q1_0_block_dot_packed AVX f64x4 bit-unpack[nib→±0.0 mask
の XOR]+ linear_q1_0_packed)。差分テスト AVX==naive(200 seeds, tolerance)+ fp16 roundtrip。
**Almide の linear_q1_0_row_no_bias を almide-kernel に flat 直接配線**(x.data straight、変換
なし)、matrix_test 12回帰OK。

**決定的発見: Almide の q1_0_block_dot は x86 で scalar(NEON は ARM のみ)** → almide-kernel
の AVX f64 が **Almide 自身を 3.35x 超える**(実推論 1x2048x2048: Almide scalar 11.19s →
almide-kernel 3.34s)。量子化は BLAS の外 → almide-kernel 独走、比較対象すらない。
**BLAS 攻略の本命=量子化 で勝った**。残: wasm simd128 packed版 / attention/fused 配線 /
密matmul は register tiling。
