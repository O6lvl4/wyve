#lang racket/base
;; Scheduling transforms wyvec performs ABOVE LLVM. Legality is proven by
;; sema (tile-check) before anything here runs; this module is pure
;; mechanics. The Halide lesson, with proofs.
(require racket/match racket/list "ast.rkt")
(provide apply-tile apply-interchange)

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

;; @interchange(p, j): reduction scalar expansion + interchange.
;;
;;   for j { float acc = 0; for p { acc += EXPR; } c[S] = acc; }
;; becomes
;;   for j { c[S] = 0; }
;;   for p { for j { c[S] += EXPR; } }
;;
;; Float-exact (each c[S] sees the same additions in the same p-order),
;; and the new inner j-loop walks memory sequentially — vectorizable.
(define (apply-interchange body po ji)
  (define (xform stmts)
    (append*
     (for/list ([s (in-list stmts)])
       (match s
         [(SFor jv jinit jcond jbody jline)
          #:when (and (string=? jv ji)
                      (match jbody
                        [(list (SLocal _ _ _ _) (SFor pv _ _ _ _) (SAssign (LvIndex _ _) 'set _ _))
                         (string=? pv po)]
                        [_ #f]))
          (match-define (list (SLocal _ _acc _ _)
                              (SFor pv pinit pcond pbody pline)
                              (SAssign (LvIndex cb sub) 'set _ sline))
            jbody)
          (match-define (list (SAssign (LvVar _) 'add expr eline)) pbody)
          (list
           ;; zero pass
           (SFor jv jinit jcond
                 (list (SAssign (LvIndex cb sub) 'set (EFloat 0.0) sline))
                 jline)
           ;; p hoisted over j; the accumulator lives in c
           (SFor pv pinit pcond
                 (list (SFor jv jinit jcond
                             (list (SAssign (LvIndex cb sub) 'add expr eline))
                             jline))
                 pline))]
         [(SFor v i c b l) (list (SFor v i c (xform b) l))]
         [s (list s)]))))
  (xform body))
