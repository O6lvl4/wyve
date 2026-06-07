#lang racket/base
;; AST. Prefab structs so they can cross module/syntax boundaries freely.
(require racket/match racket/string)
(provide (all-defined-out))

(struct Module (interfaces impls) #:prefab)
(struct Iface (name methods line) #:prefab)
(struct Impl (name methods line) #:prefab)
(struct Sig (contracts ret parts line) #:prefab)
(struct SelPart (label param) #:prefab)            ; param: Param or #f
(struct Param (noalias? ty name) #:prefab)
(struct Contracts (effect vectorize fp-reassoc?) #:prefab)
(struct Effect (reads writes line) #:prefab)
(struct Vectorize (require? width line) #:prefab)
(struct MethodDef (sig body) #:prefab)

;; types: 'void 'float 'usize 'bool | (Ptr const? pointee)
(struct Ptr (const? pointee) #:prefab)

(struct SLocal (ty name init line) #:prefab)
(struct SAssign (target op value line) #:prefab)   ; op: 'set | 'add
(struct LvVar (name) #:prefab)
(struct LvIndex (base index) #:prefab)
(struct SFor (var init cond body line) #:prefab)   ; unit-stride usize loop
(struct SReturn (value line) #:prefab)             ; value: expr or #f

(struct EInt (v) #:prefab)
(struct EFloat (v) #:prefab)
(struct EVar (name) #:prefab)
(struct EIndex (base index) #:prefab)
(struct EBin (op lhs rhs) #:prefab)                ; op: + - * / < <= > >= == !=

(define (cmp-op? op) (and (memq op '(< <= > >= == !=)) #t))

(define (contracts-empty? c)
  (and (not (Contracts-effect c))
       (not (Contracts-vectorize c))
       (not (Contracts-fp-reassoc? c))))

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
    [(EIndex b ix) (format "~a[~a]" b (expr->string ix))]
    [(EBin op l r) (format "~a ~a ~a" (expr->string l) op (expr->string r))]))
