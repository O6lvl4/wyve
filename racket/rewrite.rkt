#lang racket/base
;; AST rewrites for the conversation: retract or override contracts on a
;; parsed module without touching the source.
(require racket/match "ast.rkt")
(provide strip-noalias-mod override-vectorize-mod set-vectorize-knobs-mod)

(define (map-sigs mod fix-sig)
  (struct-copy Module mod
               [interfaces (for/list ([i (in-list (Module-interfaces mod))])
                             (struct-copy Iface i [methods (map fix-sig (Iface-methods i))]))]
               [impls (for/list ([im (in-list (Module-impls mod))])
                        (struct-copy Impl im
                                     [methods (for/list ([d (in-list (Impl-methods im))])
                                                (struct-copy MethodDef d
                                                             [sig (fix-sig (MethodDef-sig d))]))]))]))

(define (strip-noalias-mod mod names)
  (define (fix-param p)
    (if (and p (member (Param-name p) names))
        (struct-copy Param p [noalias? #f])
        p))
  (define (fix-sig s)
    (struct-copy Sig s
                 [parts (for/list ([sp (in-list (Sig-parts s))])
                          (struct-copy SelPart sp [param (fix-param (SelPart-param sp))]))]))
  (map-sigs mod fix-sig))

;; or-semantics: a #f knob keeps whatever the contract says (REPL (ask ...))
(define (override-vectorize-mod mod width interleave)
  (define (fix-sig s)
    (define c (Sig-contracts s))
    (define v (Contracts-vectorize c))
    (if v
        (struct-copy Sig s
                     [contracts
                      (struct-copy Contracts c
                                   [vectorize (struct-copy Vectorize v
                                                           [width (or width (Vectorize-width v))]
                                                           [interleave (or interleave (Vectorize-interleave v))])])])
        s))
  (map-sigs mod fix-sig))

;; exact-set semantics: knobs are set to precisely these values, #f meaning
;; "let LLVM choose"; kernels without a @vectorize contract get a hint one
(define (set-vectorize-knobs-mod mod width interleave)
  (define (fix-sig s)
    (define c (Sig-contracts s))
    (define v (or (Contracts-vectorize c)
                  (Vectorize #f #f #f #f #f #f (Sig-line s))))
    (struct-copy Sig s
                 [contracts
                  (struct-copy Contracts c
                               [vectorize (struct-copy Vectorize v
                                                       [width width]
                                                       [interleave interleave])])]))
  (map-sigs mod fix-sig))
