#lang racket/base
;; AST. Prefab structs so they can cross module/syntax boundaries freely.
(require racket/match racket/string)
(provide (all-defined-out))

(struct Module (interfaces impls) #:prefab)
(struct Iface (name methods line) #:prefab)
(struct Impl (name methods line) #:prefab)
(struct Sig (contracts ret parts line) #:prefab)
(struct SelPart (label param) #:prefab)            ; param: Param or #f
;; align: #f, or a power-of-two byte alignment promised for this pointer
(struct Param (noalias? align ty name) #:prefab)
;; fp-flags: list of symbols ⊆ (reassoc contract nsz arcp afn nnan ninf)
;; stream?: nontemporal (cache-bypassing) stores for write-only arrays
(struct Contracts (effect vectorize unroll tile interchange parallel stream? fp-flags) #:prefab)
(struct Effect (reads writes line) #:prefab)
;; manual?: wyvec vectorizes the loop itself (vector load/op/store + scalar
;; tail) instead of asking LLVM to — the only way to put @stream's
;; nontemporal hint on a *vector* store
(struct Vectorize (require? manual? width interleave predicate? scalable? disable? line) #:prefab)
(struct Unroll (require? count line) #:prefab)
;; pairs: list of (induction-var . tile-size), outermost first
(struct Tile (pairs line) #:prefab)
;; @interchange(p, j): make `outer` (currently the reduction loop inside
;; `inner`) run outside it — scalar expansion + loop interchange
(struct Interchange (outer inner line) #:prefab)
;; @parallel(i): dispatch the outer loop's iterations across cores
(struct Parallel (var line) #:prefab)
(struct MethodDef (sig body) #:prefab)

;; types: 'void 'float 'usize 'bool | (Ptr const? pointee)
(struct Ptr (const? pointee) #:prefab)

(struct SLocal (ty name init line) #:prefab)
(struct SAssign (target op value line) #:prefab)   ; op: 'set | 'add
(struct LvVar (name) #:prefab)
(struct LvIndex (base index) #:prefab)
(struct SFor (var init cond body line) #:prefab)   ; unit-stride usize loop
(struct SReturn (value line) #:prefab)             ; value: expr or #f
;; internal only — produced by the @tile transform, never by the parser:
;; `for (usize var = 0; var < bound; var += step)`
(struct SForStep (var bound step body line) #:prefab)

(struct EInt (v) #:prefab)
(struct EFloat (v) #:prefab)
(struct EVar (name) #:prefab)
(struct EIndex (base index) #:prefab)
(struct EBin (op lhs rhs) #:prefab)                ; op: + - * / < <= > >= == !=
;; internal only — unsigned min, for ragged tile edges
(struct EMin (a b) #:prefab)

(define (cmp-op? op) (and (memq op '(< <= > >= == !=)) #t))

(define (contracts-empty? c)
  (and (not (Contracts-effect c))
       (not (Contracts-vectorize c))
       (not (Contracts-unroll c))
       (not (Contracts-tile c))
       (not (Contracts-interchange c))
       (not (Contracts-parallel c))
       (null? (Contracts-fp-flags c))))

(define fp-flag-names '(reassoc contract nsz arcp afn nnan ninf))

(define (fp-flags->string flags)
  (string-join (map symbol->string flags) ", "))

(define (tile->string t)
  (string-join
   (for/list ([p (in-list (Tile-pairs t))])
     (format "~a: ~a" (car p) (cdr p)))
   ", "))

;; the contract as the user spelled it, for transcripts
(define (vectorize->string v)
  (string-join
   (append (if (Vectorize-require? v) '("require") '())
           (if (Vectorize-manual? v) '("manual") '())
           (if (Vectorize-disable? v) '("disable") '())
           (let ([w (Vectorize-width v)]) (if w (list (format "width: ~a" w)) '()))
           (let ([il (Vectorize-interleave v)]) (if il (list (format "interleave: ~a" il)) '()))
           (if (Vectorize-predicate? v) '("predicate") '())
           (if (Vectorize-scalable? v) '("scalable") '()))
   ", "))

(define (unroll->string u)
  (string-join
   (append (if (Unroll-require? u) '("require") '())
           (list (format "count: ~a" (Unroll-count u))))
   ", "))

(define (sig-selector s)
  (define parts (Sig-parts s))
  (if (and (= (length parts) 1) (not (SelPart-param (car parts))))
      (SelPart-label (car parts))
      (string-join (for/list ([p (in-list parts)]) (format "~a:" (SelPart-label p))) "")))

(define (sig-params s)
  (filter values (map SelPart-param (Sig-parts s))))

(define (sig-matches? a b)
  (and (equal? (Sig-ret a) (Sig-ret b))
       (= (length (Sig-parts a)) (length (Sig-parts b)))
       (for/and ([x (in-list (Sig-parts a))] [y (in-list (Sig-parts b))])
         (and (string=? (SelPart-label x) (SelPart-label y))
              (equal? (SelPart-param x) (SelPart-param y))))))

(define (type->string t)
  (match t
    ['void "void"]
    ['float "float"]
    ['usize "usize"]
    ['bool "bool"]
    [(Ptr c? p) (format "~a~a *" (if c? "const " "") (type->string p))]))

(define (type-numeric? t) (and (memq t '(float usize)) #t))

(define (expr->string e)
  (match e
    [(EInt v) (number->string v)]
    [(EFloat v) (number->string v)]
    [(EVar n) n]
    [(EMin a b) (format "min(~a, ~a)" (expr->string a) (expr->string b))]
    [(EIndex b ix) (format "~a[~a]" b (expr->string ix))]
    [(EBin op l r) (format "~a ~a ~a" (expr->string l) op (expr->string r))]))
