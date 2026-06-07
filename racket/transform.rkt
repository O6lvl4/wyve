#lang racket/base
;; Scheduling transforms wyvec performs ABOVE LLVM. Legality is proven by
;; sema (tile-check) before anything here runs; this module is pure
;; mechanics. The Halide lesson, with proofs.
(require racket/match "ast.rkt")
(provide apply-tile)

;; @tile(i: Ti, j: Tj): strip-mine both loops, hoist the tile loops out.
;;
;;   for i in 0..M { for j in 0..N { BODY } }
;; becomes
;;   for i.t in 0..M step Ti
;;     for j.t in 0..N step Tj
;;       for i in i.t .. min(i.t+Ti, M)
;;         for j in j.t .. min(j.t+Tj, N) { BODY }
;;
;; Tile-loop names carry a `.t` suffix — unspellable in source, so they can
;; never collide with user names.
(define (apply-tile body pairs)
  (match-define (list (cons iv1 t1) (cons iv2 t2)) pairs)
  (for/list ([s (in-list body)])
    (match s
      [(SFor v _init cond1 lbody line)
       #:when (string=? v iv1)
       (match-define (list (SFor _v2 _init2 cond2 lbody2 line2)) lbody)
       (define b1 (bound-of cond1))
       (define b2 (bound-of cond2))
       (define ii (string-append iv1 ".t"))
       (define jj (string-append iv2 ".t"))
       (SForStep
        ii b1 t1
        (list (SForStep
               jj b2 t2
               (list (SFor iv1 (EVar ii)
                           (EBin '< (EVar iv1) (EMin (EBin '+ (EVar ii) (EInt t1)) b1))
                           (list (SFor iv2 (EVar jj)
                                       (EBin '< (EVar iv2) (EMin (EBin '+ (EVar jj) (EInt t2)) b2))
                                       lbody2 line2))
                           line))
               line))
        line)]
      [_ s])))

(define (bound-of cond-e)
  (match cond-e [(EBin '< _ b) b]))
