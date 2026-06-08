#lang racket
;; Wyve v2 — algorithm/schedule 分離の概念実証(stage 0)
;; docs/roadmap/active/v2-almide-native.md
;;
;; Wyve v1 は契約1枚に「計算 × スケジュール × 要求」を混ぜた。v2 は 0 から、
;; Halide/Exo の骨 ── algorithm(何を) と schedule(どう) を分離する ── を
;; 中心に据える。この概念実証が示すするのは1点だけ:
;;
;;   「同じ algorithm に、違う schedule を別々に適用すると、違うループが出る」
;;
;; メモリ階層を schedule の語彙にする(tile を *どのレベルに* で指定)。
;; iteration space は forge が保持するので、変換は構造的に追える(検証の土台)。

;; ───────────────────────────── algorithm 層 ─────────────────────────────
;; 純粋な計算。iteration space(ループ変数 + 範囲)と body だけ。schedule なし。

(struct algo (name loops reduce body) #:transparent)
;; loops  : list of (var . extent)        — iteration space(順序は意味の既定値)
;; reduce : 還元するループ変数 or #f       — その軸は順序自由(交換可)
;; body   : 計算式(文字列表現でよい)

;; matmul: C[i,j] = Σ_p A[i,p]·B[p,j]
(define matmul
  (algo "matmul"
        '((i . "M") (j . "N") (p . "K"))
        'p
        "C[i,j] += A[i,p] * B[p,j]"))

;; ───────────────────────────── schedule 層 ─────────────────────────────
;; algorithm とは独立した変換の列。メモリ階層を語彙に持つ。

;; (interchange a b)      — ループ a,b の順序を入れ替える
;; (tile v size 'level)   — ループ v を size で分割し、外側を level に向ける
;;                          level ∈ register | L1 | L2 | L3 | DRAM
;; (parallel v)           — ループ v をコア並列に
;; (vectorize v width)    — ループ v を SIMD 幅 width でベクトル化

;; ナイーブ: 何もしない(algorithm の既定順)
(define sched-naive '())

;; 職人のスケジュール: cache に合わせて tile し、レジスタまで刻み、並列+ベクトル化
(define sched-tiled
  '((interchange p j)            ; ikj 順(p を内へ落とさず j を最内 contiguous に)
    (tile i 64 L2)               ; i を 64 ごと、L2 ブロッキング
    (tile j 64 L2)               ; j を 64 ごと、L2 ブロッキング
    (tile i 6 register)          ; さらに i を 6、レジスタブロッキング
    (tile j 16 register)         ; j を 16、レジスタブロッキング(6x16 マイクロカーネル)
    (parallel i)                 ; 外側 i をコア並列
    (vectorize j 8)))            ; 最内 j を SIMD8

;; ──────────────────────── schedule を algorithm に適用 ────────────────────────
;; iteration space を「ネストの木」に変換していく。各変換は木を書き換える rewrite。
;; (お試しなので木は素朴なリスト表現。順序とタイル属性を保持する。)

;; 1ループのノード: (loop var extent kind)
;;   kind: 'seq | 'parallel | (vector width) | (tile size level)
(define (mk-nest a)
  (for/list ([lp (algo-loops a)]) `(loop ,(car lp) ,(cdr lp) seq)))

(define (apply-step nest step)
  (match step
    [`(interchange ,a ,b)
     ;; a,b の位置を入れ替え(reduce 軸を含む交換は意味保存、後で検証)
     (define ia (index-where nest (λ (n) (eq? (second n) a))))
     (define ib (index-where nest (λ (n) (eq? (second n) b))))
     (if (and ia ib)
         (let ([v (list->vector nest)])
           (define tmp (vector-ref v ia))
           (vector-set! v ia (vector-ref v ib))
           (vector-set! v ib tmp)
           (vector->list v))
         nest)]
    [`(tile ,v ,size ,level)
     ;; ループ v を「外(タイル) / 内(要素)」に割る。外を v.t、内を v を残す。
     (append*
      (for/list ([n nest])
        (if (eq? (second n) v)
            (list `(loop ,(string->symbol (format "~a.t" v)) ,(format "~a/~a" (third n) size) (tile ,size ,level))
                  `(loop ,v ,size seq))
            (list n))))]
    [`(parallel ,v)
     (for/list ([n nest])
       (if (eq? (second n) v) `(loop ,v ,(third n) parallel) n))]
    [`(vectorize ,v ,w)
     (for/list ([n nest])
       (if (eq? (second n) v) `(loop ,v ,(third n) (vector ,w)) n))]))

(define (apply-schedule a sched)
  (foldl (λ (step nest) (apply-step nest step)) (mk-nest a) sched))

;; ──────────────────────────── emit: ループを擬似Cで ────────────────────────────
(define (emit a nest)
  (define ind (make-parameter 0))
  (define (pad) (make-string (* 2 (ind)) #\space))
  (printf "// ~a\n" (algo-name a))
  (let loop ([ns nest])
    (cond
      [(null? ns) (printf "~a~a;\n" (pad) (algo-body a))]
      [else
       (match-define `(loop ,v ,ext ,kind) (car ns))
       (define tag
         (match kind
           ['seq ""]
           ['parallel "  // ‖ cores"]
           [`(vector ,w) (format "  // SIMD~a" w)]
           [`(tile ,sz ,lvl) (format "  // tile→~a" lvl)]))
       (printf "~afor (~a < ~a)~a {\n" (pad) v ext tag)
       (parameterize ([ind (add1 (ind))]) (loop (cdr ns)))
       (printf "~a}\n" (pad))])))

;; ──────────────────────────────── 走らせる ────────────────────────────────
(printf "===== algorithm(何を)は1つ。schedule(どう)を差し替えると、別のループが出る =====\n\n")

(printf "--- schedule: naive ---\n")
(emit matmul (apply-schedule matmul sched-naive))

(printf "\n--- schedule: tiled(L2 cache → register 6x16 → parallel + SIMD8) ---\n")
(emit matmul (apply-schedule matmul sched-tiled))

(printf "\n注: algorithm の式 `C[i,j] += A[i,p]*B[p,j]` は両者で 1 文字も変えていない。\n")
(printf "    変わったのは schedule だけ。これが v1(契約混在)にない、計算/スケジュールの分離。\n")
