#lang racket/base
;; Contract verification — the part that makes contracts proven, not promised.
;; Same checks and WVN codes as the Rust reference implementation:
;;   WVN001/002  contract surface / signature mismatch
;;   WVN003      effect violations
;;   WVN010-016  @vectorize(require) legality (wyvec's own affine analysis)
(require racket/match racket/list "ast.rkt" "diag.rkt")
(provide check pair-kernels (struct-out kernel))

(struct kernel (iface decl def symbol) #:transparent)

(define (kernel-symbol-of iface-name decl)
  (format "~a_~a" iface-name (SelPart-label (car (Sig-parts decl)))))

;; returns (values kernels diags); diags non-empty means rejection
(define (check mod)
  (define diags '())
  (define kernels '())
  (define (emit! d) (set! diags (append diags (list d))))
  (define ifaces (for/hash ([i (in-list (Module-interfaces mod))]) (values (Iface-name i) i)))
  (for ([imp (in-list (Module-impls mod))])
    (define iface (hash-ref ifaces (Impl-name imp) #f))
    (cond
      [(not iface)
       (emit! (diag #f
                    (format "no @interface named `~a` for this @implementation" (Impl-name imp))
                    (Impl-line imp) '()))]
      [else
       (for ([def (in-list (Impl-methods imp))])
         (define sel (sig-selector (MethodDef-sig def)))
         (define decl (findf (λ (m) (string=? (sig-selector m) sel)) (Iface-methods iface)))
         (cond
           [(not decl)
            (emit! (diag "WVN001"
                         (format "kernel `~a` has no contract surface: no matching declaration in @interface ~a"
                                 sel (Iface-name iface))
                         (Sig-line (MethodDef-sig def))
                         (list (format "@interface ~a begins at line ~a" (Iface-name iface) (Iface-line iface)))))]
           [(not (sig-matches? decl (MethodDef-sig def)))
            (emit! (diag "WVN002"
                         (format "signature of `~a` does not match its declaration in @interface ~a"
                                 sel (Iface-name iface))
                         (Sig-line (MethodDef-sig def))
                         (list (format "declared at line ~a" (Sig-line decl)))))]
           [else
            (define kds (check-kernel ifaces (Iface-name iface) decl def))
            (if (null? kds)
                (set! kernels
                      (append kernels
                              (list (kernel (Iface-name iface) decl def
                                            (kernel-symbol-of (Iface-name iface) decl)))))
                (set! diags (append diags kds)))]))]))
  ;; symbol collisions (stage 0 mangles by first selector label)
  (define seen (make-hash))
  (for ([k (in-list kernels)])
    (if (hash-ref seen (kernel-symbol k) #f)
        (emit! (diag #f
                     (format "mangled symbol `~a` collides with another kernel (stage 0 mangles by first selector label)"
                             (kernel-symbol k))
                     (Sig-line (MethodDef-sig (kernel-def k))) '()))
        (hash-set! seen (kernel-symbol k) #t)))
  (values kernels diags))

;; pair decls/defs by selector WITHOUT contract checks — for #:force conversations
(define (pair-kernels mod)
  (define ifaces (for/hash ([i (in-list (Module-interfaces mod))]) (values (Iface-name i) i)))
  (for*/list ([imp (in-list (Module-impls mod))]
              [def (in-list (Impl-methods imp))]
              #:when (hash-ref ifaces (Impl-name imp) #f)
              [decl (in-value (findf (λ (m) (string=? (sig-selector m) (sig-selector (MethodDef-sig def))))
                                     (Iface-methods (hash-ref ifaces (Impl-name imp)))))]
              #:when decl)
    (kernel (Impl-name imp) decl def (kernel-symbol-of (Impl-name imp) decl))))

;; ------------------------------------------------------------- per kernel

(define (check-kernel ifaces iface-name decl def)
  (define diags '())
  (define (emit! d) (set! diags (append diags (list d))))
  (define params (for/hash ([p (in-list (sig-params decl))]) (values (Param-name p) p)))
  (define contracts (Sig-contracts decl))

  ;; knob sanity (validated even when the contract is only a hint)
  (define v0 (Contracts-vectorize contracts))
  (when v0
    (when (and (Vectorize-disable? v0)
               (or (Vectorize-require? v0) (Vectorize-width v0) (Vectorize-interleave v0)
                   (Vectorize-predicate? v0) (Vectorize-scalable? v0)))
      (emit! (diag #f "@vectorize(disable) conflicts with the other @vectorize items"
                   (Vectorize-line v0) '())))
    (let ([w (Vectorize-width v0)])
      (when (and w (not (power-of-two? w)))
        (emit! (diag #f (format "vectorize width must be a power of two, got ~a" w)
                     (Vectorize-line v0) '()))))
    (let ([il (Vectorize-interleave v0)])
      (when (and il (< il 1))
        (emit! (diag #f (format "interleave count must be positive, got ~a" il)
                     (Vectorize-line v0) '()))))
    (when (Vectorize-manual? v0)
      (when (or (Vectorize-require? v0) (Vectorize-disable? v0)
                (Vectorize-interleave v0) (Vectorize-predicate? v0) (Vectorize-scalable? v0))
        (emit! (diag "WVN040" "@vectorize(manual) takes only a width; it vectorizes the loop itself"
                     (Vectorize-line v0) '())))
      (unless (Vectorize-width v0)
        (emit! (diag "WVN040" "@vectorize(manual) requires a width, e.g. @vectorize(manual, width: 8)"
                     (Vectorize-line v0) '())))))
  (define u0 (Contracts-unroll contracts))
  (when (and u0 (< (Unroll-count u0) 2))
    (emit! (diag #f (format "unroll count must be at least 2, got ~a" (Unroll-count u0))
                 (Unroll-line u0) '())))
  (define ic0 (Contracts-interchange contracts))
  (when ic0
    (when (or v0 u0 (Contracts-tile contracts))
      (emit! (diag "WVN022" "@interchange cannot be combined with other schedule contracts in stage 0"
                   (Interchange-line ic0) '()))))
  (define par0 (Contracts-parallel contracts))
  (when par0
    (when (or v0 u0 (Contracts-tile contracts))
      (emit! (diag "WVN022" "@parallel can combine only with @interchange and @fp in stage 0"
                   (Parallel-line par0) '()))))
  (define t0 (Contracts-tile contracts))
  (when t0
    (when v0
      (emit! (diag "WVN022" "@tile cannot be combined with @vectorize in stage 0"
                   (Tile-line t0) '())))
    (when u0
      (emit! (diag "WVN022" "@tile cannot be combined with @unroll in stage 0"
                   (Tile-line t0) '())))
    (unless (= (length (Tile-pairs t0)) 2)
      (emit! (diag "WVN022" "stage 0 tiles exactly two loops, e.g. @tile(i: 64, j: 64)"
                   (Tile-line t0) '())))
    (for ([p (in-list (Tile-pairs t0))])
      (when (< (cdr p) 2)
        (emit! (diag "WVN022" (format "tile size must be at least 2, got ~a" (cdr p))
                     (Tile-line t0) '())))))

  ;; @simd is its own world — no schedule contracts apply to explicit vectors
  (when (Contracts-simd? contracts)
    (when (or v0 u0 ic0 par0 t0 (Contracts-stream? contracts))
      (emit! (diag "WVN041" "@simd cannot be combined with schedule contracts (it is explicit vector code)"
                   (Sig-line decl) '()))))

  ;; @align(n) — each promised alignment must be a power of two
  (for ([p (in-list (sig-params decl))])
    (define a (Param-align p))
    (when (and a (not (power-of-two? a)))
      (emit! (diag "WVN030" (format "@align(~a) on `~a` must be a power of two" a (Param-name p))
                   (Sig-line decl) '()))))

  ;; effect contract must name pointer parameters
  (define eff (Contracts-effect contracts))
  (when eff
    (for ([n (in-list (append (Effect-reads eff) (Effect-writes eff)))])
      (define p (hash-ref params n #f))
      (cond
        [(and p (Ptr? (Param-ty p))) (void)]
        [p (emit! (diag #f (format "effect contract names `~a`, which is not a pointer parameter" n)
                        (Effect-line eff) '()))]
        [else (emit! (diag #f (format "effect contract names unknown parameter `~a`" n)
                           (Effect-line eff) '()))])))

  ;; @stream — nontemporal stores need a proven write-only target. The
  ;; effect contract is the proof: stream applies to arrays in writes but
  ;; not reads. Without @effect there is nothing to prove against, and a
  ;; read-modify-write array would be slower nontemporal, not faster.
  (when (Contracts-stream? contracts)
    (cond
      [(not eff)
       (emit! (diag "WVN031" "@stream needs an @effect contract to prove a write-only target"
                    (Sig-line decl)
                    '("add @effect(reads(...), writes(...))")))]
      [(not (ormap (λ (w) (not (member w (Effect-reads eff)))) (Effect-writes eff)))
       (emit! (diag "WVN031"
                    "@stream has no write-only array: every written array is also read (read-modify-write is slower nontemporal)"
                    (Sig-line decl)
                    '("remove @stream, or split the read-modify-write")))]
      [else (void)]))

  ;; @simd kernels use a separate vector-typed checker, not the scalar one
  (cond
    [(Contracts-simd? contracts)
     (set! diags (append diags (simd-check decl def params)))
     diags]
    [else
  (set! diags (append diags (typecheck ifaces params (Sig-ret decl) def)))
  (cond
    [(pair? diags) diags]
    [else
     (when eff
       (set! diags (append diags (effect-check iface-name eff params (MethodDef-body def)))))
     (define v (Contracts-vectorize contracts))
     (cond
       [(and v (Vectorize-manual? v))
        (set! diags (append diags (manual-check decl def params v)))]
       [(and v (Vectorize-require? v) (not (Vectorize-disable? v)))
        (set! diags (append diags (vectorize-check decl def params v)))])
     (define ti (Contracts-tile contracts))
     (when ti
       (set! diags (append diags (tile-check def ti))))
     (define ic (Contracts-interchange contracts))
     (when ic
       (set! diags (append diags (interchange-check def ic))))
     (define par (Contracts-parallel contracts))
     (when par
       (set! diags (append diags (parallel-check def par))))
     diags])]))

;; ------------------------------------------------------------- type check

(define (typecheck ifaces params ret def)
  (define diags '())
  (define (emit! code msg line [notes '()])
    (set! diags (append diags (list (diag code msg line notes)))))
  (define locals '())              ; list of (name . ty), innermost first
  (define declared (make-hash))    ; stage 0: one declaration per name per kernel

  (define (lookup n)
    (cond
      [(hash-ref params n #f) => Param-ty]
      [(assoc n locals) => cdr]
      [else #f]))

  (define (declare! n ty line)
    (when (or (hash-ref params n #f) (hash-ref declared n #f))
      (emit! #f (format "`~a` is already defined (stage 0 allows one declaration per name)" n) line))
    (hash-set! declared n #t)
    (set! locals (cons (cons n ty) locals)))

  ;; an integer literal is 'int-lit until context picks usize or int
  (define (unify-num a b)
    (cond
      [(eq? a b) a]
      [(and (eq? a 'int-lit) (type-integer? b)) b]
      [(and (eq? b 'int-lit) (type-integer? a)) a]
      [(and (eq? a 'int-lit) (eq? b 'int-lit)) 'int-lit]
      [else #f]))
  ;; does an inferred type fit a declared/target type?
  (define (fits? declared inferred)
    (or (equal? declared inferred)
        (and (eq? inferred 'int-lit) (type-integer? declared))
        ;; a non-const pointer fits a const-pointer parameter (as in C)
        (and (Ptr? declared) (Ptr? inferred)
             (Ptr-const? declared)
             (equal? (Ptr-pointee declared) (Ptr-pointee inferred)))))
  (define (index-ok? it)            ; subscripts are usize (or an int literal)
    (or (not it) (eq? it 'int-lit) (eq? it 'usize)))
  ;; type a math builtin call, or #f after emitting an error
  (define (builtin-type name args line)
    (define ats (map (λ (a) (infer a line)) args))
    (define (arity n) (= (length ats) n))
    (cond
      [(ormap not ats) #f]
      [(member name '("min" "max"))
       (cond [(not (arity 2)) (emit! #f (format "`~a` takes 2 arguments" name) line) #f]
             [(unify-num (car ats) (cadr ats)) => values]
             [else (emit! #f (format "`~a` arguments must have the same numeric type" name) line) #f])]
      [(string=? name "abs")
       (cond [(not (arity 1)) (emit! #f "`abs` takes 1 argument" line) #f]
             [(memq (car ats) '(float double int int-lit)) (if (eq? (car ats) 'int-lit) 'int (car ats))]
             [else (emit! #f "`abs` needs a signed numeric argument" line) #f])]
      [(string=? name "sqrt")
       (cond [(not (arity 1)) (emit! #f "`sqrt` takes 1 argument" line) #f]
             [(type-float? (car ats)) (car ats)]
             [else (emit! #f "`sqrt` needs a float or double argument" line) #f])]
      [(string=? name "fma")
       (cond [(not (arity 3)) (emit! #f "`fma` takes 3 arguments" line) #f]
             [(and (type-float? (car ats)) (apply equal? ats)) (car ats)]
             [else (emit! #f "`fma` needs three arguments of the same float type" line) #f])]
      [else (emit! #f (format "unknown function `~a` (builtins: min max abs sqrt fma)" name) line) #f]))
  (define (infer e line)
    (match e
      [(EInt _) 'int-lit]
      [(EFloat _) 'float]
      [(EDouble _) 'double]
      [(ECall name args) (builtin-type name args line)]
      [(EVar n)
       (or (lookup n)
           (begin (emit! #f (format "`~a` is not defined" n) line) #f))]
      [(EIndex b ix)
       (define p (hash-ref params b #f))
       (cond
         [(not p)
          (emit! #f (format "`~a` is not a pointer parameter" b) line) #f]
         [(not (Ptr? (Param-ty p)))
          (emit! #f (format "`~a` is not a pointer and cannot be indexed" b) line) #f]
         [else
          (define it (infer ix line))
          (unless (index-ok? it)
            (emit! #f "subscript must be an integer" line))
          (Ptr-pointee (Param-ty p))])]
      [(EBin op l r)
       (define lt (infer l line))
       (define rt (infer r line))
       (cond
         [(or (not lt) (not rt)) #f]
         [(or (not (or (type-numeric? lt) (eq? lt 'int-lit)))
              (not (or (type-numeric? rt) (eq? rt 'int-lit))))
          (emit! #f "operands must be numeric" line) #f]
         [(unify-num lt rt)
          => (λ (u) (if (cmp-op? op) 'bool u))]
         [else
          (emit! #f (format "type mismatch: `~a` vs `~a`" (type->string lt) (type->string rt)) line)
          #f])]))

  (define (do-block stmts)
    (define saved locals)
    (for ([s (in-list stmts)]) (do-stmt s))
    (set! locals saved))

  (define (do-stmt s)
    (match s
      [(SLocal ty name init line)
       (define t (infer init line))
       (when (and t (not (fits? ty t)))
         (emit! #f (format "initializer type `~a` does not match `~a`" (type->string t) (type->string ty)) line))
       (declare! name ty line)]
      [(SAssign target op value line)
       (define tty
         (match target
           [(LvVar n)
            (cond
              [(hash-ref params n #f)
               (emit! #f (format "cannot assign to parameter `~a`" n) line) #f]
              [(lookup n)]
              [else (emit! #f (format "`~a` is not defined" n) line) #f])]
           [(LvIndex b ix)
            (define p (hash-ref params b #f))
            (cond
              [(not p)
               (emit! #f (format "`~a` is not a pointer parameter" b) line) #f]
              [(not (Ptr? (Param-ty p)))
               (emit! #f (format "`~a` is not a pointer and cannot be indexed" b) line) #f]
              [else
               (when (Ptr-const? (Param-ty p))
                 (emit! #f (format "cannot write through `~a`: it is a const pointer" b) line))
               (define it (infer ix line))
               (unless (index-ok? it)
                 (emit! #f "subscript must be an integer" line))
               (Ptr-pointee (Param-ty p))])]))
       (when tty
         (define vt (infer value line))
         (when (and vt (not (fits? tty vt)))
           (emit! #f (format "cannot assign `~a` to `~a`" (type->string vt) (type->string tty)) line))
         (when (and (eq? op 'add) (not (type-numeric? tty)))
           (emit! #f "`+=` requires a numeric target" line)))]
      [(SFor var init cond-e body line)
       (define it (infer init line))
       (unless (index-ok? it)
         (emit! #f "loop bounds must be an integer" line))
       (define saved locals)
       (declare! var 'usize line)
       (match cond-e
         [(EBin op _ _) #:when (cmp-op? op) (infer cond-e line) (void)]
         [_ (emit! #f "loop condition must be a comparison" line)])
       (do-block body)
       (set! locals saved)]
      [(SReturn value line)
       (define vt (if value (infer value line) 'void))
       (when (and vt (not (fits? ret vt)))
         (emit! #f (format "return type `~a` does not match kernel return type `~a`"
                           (type->string vt) (type->string ret))
                line))]
      [(SIf cond-e then-body else-body line)
       (match cond-e
         [(EBin op _ _) #:when (cmp-op? op) (infer cond-e line) (void)]
         [_ (emit! #f "`if` condition must be a comparison" line)])
       (do-block then-body)
       (do-block else-body)]
      [(SCall iface-name labels args line)
       (define iface (hash-ref ifaces iface-name #f))
       (define sel (apply string-append (map (λ (l) (format "~a:" l)) labels)))
       (cond
         [(not iface) (emit! #f (format "no @interface named `~a` to call" iface-name) line)]
         [else
          (define m (findf (λ (mm) (string=? (sig-selector mm) sel)) (Iface-methods iface)))
          (cond
            [(not m) (emit! #f (format "@interface ~a has no kernel `~a`" iface-name sel) line)]
            [(not (eq? (Sig-ret m) 'void))
             (emit! #f (format "`~a` returns a value; only void kernels can be called as a statement" sel) line)]
            [else
             (define ps (sig-params m))
             (cond
               [(not (= (length args) (length ps)))
                (emit! #f (format "`~a` takes ~a arguments, got ~a" sel (length ps) (length args)) line)]
               [else
                (for ([a (in-list args)] [p (in-list ps)])
                  (define at (infer a line))
                  (when (and at (not (fits? (Param-ty p) at)))
                    (emit! #f (format "argument `~a` has type `~a`, expected `~a`"
                                      (Param-name p) (type->string at) (type->string (Param-ty p))) line)))])])])]))

  (do-block (MethodDef-body def))
  (unless (or (eq? ret 'void)
              (and (pair? (MethodDef-body def))
                   (SReturn? (last (MethodDef-body def)))))
    (emit! #f (format "kernel returns `~a` but does not end with a return statement" (type->string ret))
           (Sig-line (MethodDef-sig def))))
  diags)

;; ------------------------------------------------------------ effect check

(define (effect-check iface eff params body)
  (define diags '())
  (define accesses '()) ; list of (vector name write? line)
  (define (acc! name write? line)
    (set! accesses (append accesses (list (vector name write? line)))))

  (define (walk-expr e line)
    (match e
      [(EIndex b ix) (acc! b #f line) (walk-expr ix line)]
      [(EBin _ l r) (walk-expr l line) (walk-expr r line)]
      [_ (void)]))

  (define (walk-stmts stmts)
    (for ([s (in-list stmts)])
      (match s
        [(SLocal _ _ init line) (walk-expr init line)]
        [(SAssign target op value line)
         (walk-expr value line)
         (match target
           [(LvIndex b ix)
            (walk-expr ix line)
            (acc! b #t line)
            (when (eq? op 'add) (acc! b #f line))]
           [_ (void)])]
        [(SFor _ init cond-e body line)
         (walk-expr init line)
         (walk-expr cond-e line)
         (walk-stmts body)]
        [(SIf cond-e then-body else-body line)
         (walk-expr cond-e line)
         (walk-stmts then-body)
         (walk-stmts else-body)]
        [(SCall _ _ args line) (for ([a (in-list args)]) (walk-expr a line))]
        [(SReturn value line) (when value (walk-expr value line))]
        [_ (void)])))

  (walk-stmts body)
  (define reported (make-hash))
  (for ([a (in-list accesses)])
    (define p (vector-ref a 0))
    (define w? (vector-ref a 1))
    (define line (vector-ref a 2))
    (when (hash-ref params p #f)
      (when (and w? (not (member p (Effect-writes eff))))
        (unless (hash-ref reported (cons p 'w) #f)
          (hash-set! reported (cons p 'w) #t)
          (define msg
            (if (member p (Effect-reads eff))
                (format "effect violation: `~a` is written, but the contract declares only reads(~a)" p p)
                (format "effect violation: `~a` is written, but the contract does not declare writes(~a)" p p)))
          (set! diags (append diags (list (diag "WVN003" msg line
                                                (list (format "contract declared in @interface ~a" iface))))))))
      (when (and (not w?) (not (member p (Effect-reads eff))))
        (unless (hash-ref reported (cons p 'r) #f)
          (hash-set! reported (cons p 'r) #t)
          (define msg
            (if (member p (Effect-writes eff))
                (format "effect violation: `~a` is read, but the contract declares only writes(~a)" p p)
                (format "effect violation: `~a` is read, but the contract does not declare reads(~a)" p p)))
          (set! diags (append diags (list (diag "WVN003" msg line
                                                (list (format "contract declared in @interface ~a" iface))))))))))
  diags)

;; ------------------------------------------------------- vectorize legality

(define (power-of-two? n) (and (positive? n) (zero? (bitwise-and n (sub1 n)))))

(define (subscript-form e iv)
  (match e
    [(EVar n) (if (string=? n iv) (cons 'affine 0) 'uniform)]
    [(EInt _) 'uniform]
    [(EBin '+ (EVar n) (EInt c)) #:when (string=? n iv) (cons 'affine c)]
    [(EBin '+ (EInt c) (EVar n)) #:when (string=? n iv) (cons 'affine c)]
    [(EBin '- (EVar n) (EInt c)) #:when (string=? n iv) (cons 'affine (- c))]
    [_ #f]))

(define (off-str iv c)
  (cond [(zero? c) iv]
        [(positive? c) (format "~a + ~a" iv c)]
        [else (format "~a - ~a" iv (- c))]))

;; ------------------------------------------------------- tiling legality
;;
;; @tile(i: Ti, j: Tj) is strip-mine + interchange, which is legal when the
;; two loops are provably parallel. The stage 0 proof obligations:
;;   - the loops form a perfect nest prefix, each running 0..bound with `<`
;;   - every array written inside the nest is never read there (WVN020)
;;   - every write subscript is the injective row-major form `i*B + j`,
;;     where B is exactly the j-loop's bound (WVN021)
;;   - no scalar declared outside the nest is assigned inside it (WVN023)
;; Conservative on purpose: anything not provable is refused, loudly.

(define (tile-check def t)
  (define diags '())
  (define (emit! d) (set! diags (append diags (list d))))
  (match-define (list (cons iv1 _t1) (cons iv2 _t2)) (Tile-pairs t))

  (define l1 (findf (λ (s) (and (SFor? s) (string=? (SFor-var s) iv1)))
                    (MethodDef-body def)))
  (define l2 (and l1 (match (SFor-body l1)
                       [(list (? SFor? s)) (and (string=? (SFor-var s) iv2) s)]
                       [_ #f])))
  (define (loop-shape-ok? l)
    (and (match (SFor-init l) [(EInt 0) #t] [_ #f])
         (match (SFor-cond l)
           [(EBin '< (EVar v) (or (EVar _) (EInt _))) (string=? v (SFor-var l))]
           [_ #f])))
  (cond
    [(not l1)
     (emit! (diag "WVN022"
                  (format "@tile names `~a`, but there is no top-level loop over `~a`" iv1 iv1)
                  (Tile-line t) '()))
     diags]
    [(not l2)
     (emit! (diag "WVN022"
                  (format "the loop over `~a` must contain exactly the loop over `~a` (perfect nest)" iv1 iv2)
                  (SFor-line l1) '()))
     diags]
    [(not (and (loop-shape-ok? l1) (loop-shape-ok? l2)))
     (emit! (diag "WVN022"
                  "tiled loops must run `0 .. bound` with `<` (stage 0)"
                  (SFor-line l1) '()))
     diags]
    [else
     (define bound2 (match (SFor-cond l2) [(EBin '< _ b) b]))
     (define (bound2-matches? e)
       (match (list e bound2)
         [(list (EVar a) (EVar b)) (string=? a b)]
         [(list (EInt a) (EInt b)) (= a b)]
         [_ #f]))
     ;; walk the nest
     (define written (make-hash))    ; base -> list of (cons subscript line)
     (define read-bases (make-hash))
     (define inner-decl (make-hash))
     (define (wexpr e line)
       (match e
         [(EIndex b ix) (hash-set! read-bases b #t) (wexpr ix line)]
         [(EBin _ l r) (wexpr l line) (wexpr r line)]
         [_ (void)]))
     (define (wstmts stmts)
       (for ([s (in-list stmts)])
         (match s
           [(SLocal _ name init line)
            (wexpr init line)
            (hash-set! inner-decl name #t)]
           [(SAssign target op value line)
            (wexpr value line)
            (match target
              [(LvIndex b ix)
               (wexpr ix line)
               (hash-update! written b (λ (l) (cons (cons ix line) l)) '())
               (when (eq? op 'add) (hash-set! read-bases b #t))]
              [(LvVar nm)
               (unless (hash-ref inner-decl nm #f)
                 (emit! (diag "WVN023"
                              (format "cannot prove tiling legal: scalar `~a` is carried across the tiled loops" nm)
                              line
                              '("declare it inside the tiled nest, or remove @tile"))))])]
           [(SFor v init cond-e body line)
            (hash-set! inner-decl v #t)
            (wexpr init line)
            (wexpr cond-e line)
            (wstmts body)]
           [(SReturn _ line)
            (emit! (diag "WVN022" "return inside a tiled nest is not supported" line '()))]
           [_ (void)])))
     (hash-set! inner-decl iv1 #t)
     (hash-set! inner-decl iv2 #t)
     (wstmts (SFor-body l2))
     ;; proof obligations per written array
     (for ([(b subs) (in-hash written)])
       (when (hash-ref read-bases b #f)
         (emit! (diag "WVN020"
                      (format "cannot prove tiling legal: `~a` is both read and written inside the tiled nest" b)
                      (cdr (car subs))
                      '("remove @tile, or split the kernel"))))
       (for ([sl (in-list subs)])
         (match (car sl)
           [(EBin '+ (EBin '* (EVar v1) bexpr) (EVar v2))
            #:when (and (string=? v1 iv1) (string=? v2 iv2) (bound2-matches? bexpr))
            (void)]
           [sub
            (emit! (diag "WVN021"
                         (format "cannot prove tiling legal: write subscript `~a[~a]` is not the injective form `~a * <bound of ~a> + ~a`"
                                 b (expr->string sub) iv1 iv2 iv2)
                         (cdr sl)
                         '("remove @tile, or rewrite the store in row-major form")))])))
     diags]))

(define (vectorize-check decl def params v)
  (define diags '())
  (define (emit! d) (set! diags (append diags (list d))))
  (define loops (filter SFor? (MethodDef-body def)))
  (cond
    [(null? loops)
     (emit! (diag "WVN010" "vectorization required, but the kernel has no loop" (Vectorize-line v) '()))
     diags]
    [else
     (define outer-locals
       (for/list ([s (in-list (MethodDef-body def))] #:when (SLocal? s))
         (cons (SLocal-name s) (SLocal-ty s))))
     (for ([l (in-list loops)])
       (set! diags
             (append diags
                     (check-loop (SFor-var l) (SFor-body l) (SFor-line l)
                                 params outer-locals
                                 (and (memq 'reassoc (Contracts-fp-flags (Sig-contracts decl))) #t)))))
     diags]))

(define (check-loop iv body loop-line params outer-locals fp-reassoc?)
  (define diags '())
  (define (emit! d) (set! diags (append diags (list d))))
  (define acc (make-hash))          ; name -> list of (vector offset write? line)
  (define inner-locals (make-hash))

  (define (record! base write? index line)
    (when (hash-ref params base #f)
      (define off (subscript-form index iv))
      (if off
          (hash-update! acc base
                        (λ (l) (append l (list (vector off write? line))))
                        '())
          (emit! (diag "WVN010"
                       (format "vectorization required, but subscript `~a[~a]` is not affine in `~a`"
                               base (expr->string index) iv)
                       line '())))))

  (define (scan-expr e line)
    (match e
      [(EIndex b ix) (record! b #f ix line) (scan-expr ix line)]
      [(EBin _ l r) (scan-expr l line) (scan-expr r line)]
      [_ (void)]))

  (define (scan-block stmts)
    (for ([s (in-list stmts)])
      (match s
        [(SLocal _ name init line)
         (scan-expr init line)
         (hash-set! inner-locals name #t)]
        [(SAssign target op value line)
         (scan-expr value line)
         (match target
           [(LvIndex b ix)
            (scan-expr ix line)
            (record! b #t ix line)
            (when (eq? op 'add) (record! b #f ix line))]
           [(LvVar n)
            (cond
              [(string=? n iv)
               (emit! (diag #f "the induction variable cannot be assigned in the loop body" line '()))]
              [(hash-ref inner-locals n #f) (void)] ; fresh every iteration
              [(assoc n outer-locals)
               =>
               (λ (pr)
                 (cond
                   [(eq? op 'add)
                    (when (and (eq? (cdr pr) 'float) (not fp-reassoc?))
                      (emit! (diag "WVN015"
                                   (format "vectorization required, but the float reduction over `~a` reorders additions" n)
                                   line
                                   '("grant @fp(reassoc) to permit reassociation"))))]
                   [else
                    (emit! (diag "WVN016"
                                 (format "vectorization required, but `~a` is overwritten across iterations (scalar recurrence)" n)
                                 line
                                 '("remove @vectorize(require) or make the value per-iteration")))]))]
              [else (void)])])]
        [(SFor _ _ _ _ line)
         (emit! (diag "WVN011" "nested loops under @vectorize(require) are not supported in stage 0" line '()))]
        [(SIf _ _ _ line)
         (emit! (diag "WVN017"
                      "`if` inside a @vectorize(require) loop is not supported in stage 0 (needs predication)"
                      line
                      '("drop @vectorize(require) for a scalar conditional loop")))]
        [(SCall _ _ _ line)
         (emit! (diag "WVN018"
                      "a kernel call inside a @vectorize(require) loop is not supported in stage 0"
                      line '()))]
        [(SReturn _ line)
         (emit! (diag #f "return inside a @vectorize(require) loop is not vectorizable" line '()))]
        [_ (void)])))

  (scan-block body)

  ;; memory dependences, per array
  (for ([(p accs) (in-hash acc)])
    (define writes (filter (λ (a) (vector-ref a 1)) accs))
    (unless (null? writes)
      (define uni-w (findf (λ (a) (eq? (vector-ref a 0) 'uniform)) writes))
      (cond
        [uni-w
         (emit! (diag "WVN014"
                      (format "vectorization required, but `~a` is written at a loop-invariant subscript (every iteration writes the same location)" p)
                      (vector-ref uni-w 2)
                      '("remove @vectorize(require) or restructure the recurrence")))]
        [else
         (define wofs
           (for/list ([a (in-list writes)])
             (cons (cdr (vector-ref a 0)) (vector-ref a 2)))) ; (offset . line)
         ;; write/write conflicts
         (define reported-ww (make-hash))
         (for* ([x (in-list wofs)] [y (in-list wofs)])
           (when (and (< (car x) (car y))
                      (not (hash-ref reported-ww (cons (car x) (car y)) #f)))
             (hash-set! reported-ww (cons (car x) (car y)) #t)
             (emit! (diag "WVN014"
                          (format "vectorization required, but the loop carries an output dependence: `~a` is written at ~a[~a] and ~a[~a]"
                                  p p (off-str iv (car x)) p (off-str iv (car y)))
                          (cdr x)
                          '("remove @vectorize(require) or restructure the recurrence")))))
         ;; read/write conflicts
         (define reported-rw (make-hash))
         (for ([a (in-list accs)] #:unless (vector-ref a 1))
           (define off (vector-ref a 0))
           (define rline (vector-ref a 2))
           (cond
             [(eq? off 'uniform)
              (emit! (diag "WVN014"
                           (format "vectorization required, but `~a` is read at a loop-invariant subscript while also being written in the loop" p)
                           rline
                           '("remove @vectorize(require) or restructure the recurrence")))]
             [else
              (define cr (cdr off))
              (for ([wo (in-list wofs)])
                (define cw (car wo))
                (when (and (not (= cr cw))
                           (not (hash-ref reported-rw (cons cw cr) #f)))
                  (hash-set! reported-rw (cons cw cr) #t)
                  (define msg
                    (if (= cr (sub1 cw))
                        (format "vectorization required, but the loop carries a dependence: ~a[~a] reads ~a[~a] written in the previous iteration"
                                p (off-str iv cw) p (off-str iv cr))
                        (format "vectorization required, but the loop carries a dependence: `~a` is written at ~a[~a] and read at ~a[~a]"
                                p p (off-str iv cw) p (off-str iv cr))))
                  (emit! (diag "WVN014" msg (max rline (cdr wo))
                               '("remove @vectorize(require) or restructure the recurrence")))))]))])))

  ;; aliasing: written arrays need a noalias witness against every other array
  (define written
    (for/list ([(p accs) (in-hash acc)]
               #:when (ormap (λ (a) (vector-ref a 1)) accs))
      p))
  (define reported-pairs (make-hash))
  (for* ([w (in-list written)] [(q _) (in-hash acc)])
    (unless (string=? q w)
      (define wp (hash-ref params w #f))
      (define qp (hash-ref params q #f))
      (when (and wp qp (not (Param-noalias? wp)) (not (Param-noalias? qp)))
        (define key (if (string<? w q) (cons w q) (cons q w)))
        (unless (hash-ref reported-pairs key #f)
          (hash-set! reported-pairs key #t)
          (emit! (diag "WVN012"
                       (format "vectorization required, but cannot prove `~a` and `~a` do not alias" w q)
                       loop-line
                       '("add @noalias to the parameter declarations")))))))
  diags)

;; -------------------------------------------------- interchange legality
;;
;; @interchange(p, j) is reduction scalar expansion + loop interchange:
;;
;;   for j { float acc = 0.0f; for p { acc += EXPR; } c[S] = acc; }
;; becomes
;;   for j { c[S] = 0.0f; }
;;   for p { for j { c[S] += EXPR; } }
;;
;; Float-exact: every c[S] receives the same additions in the same p-order.
;; Proof obligations (everything else is refused):
;;   - the j-loop body is EXACTLY the pattern above (WVN024)
;;   - both loops run `0 .. bound` with `<`; bounds are loop-invariant
;;     names not captured by the other loop (WVN024)
;;   - S = <j-invariant> + j (injective in j), and S does not reference p,
;;     since the zero pass runs outside the p-loop (WVN024)
;;   - EXPR never references acc, and the kernel never reads c (WVN020)

(define (interchange-check def ic)
  (define diags '())
  (define (emit! d) (set! diags (append diags (list d))))
  (define po (Interchange-outer ic))
  (define ji (Interchange-inner ic))

  (define (refs? e name)
    (match e
      [(EVar n) (string=? n name)]
      [(EIndex b ix) (or (string=? b name) (refs? ix name))]
      [(EBin _ l r) (or (refs? l name) (refs? r name))]
      [(EMin a b) (or (refs? a name) (refs? b name))]
      [_ #f]))
  (define (reads-array? e base)
    (match e
      [(EIndex b ix) (or (string=? b base) (reads-array? ix base))]
      [(EBin _ l r) (or (reads-array? l base) (reads-array? r base))]
      [(EMin a b) (or (reads-array? a base) (reads-array? b base))]
      [_ #f]))

  ;; the unique loop over ji
  (define jloop #f)
  (define dup #f)
  (let find ([stmts (MethodDef-body def)])
    (for ([s (in-list stmts)])
      (match s
        [(SFor v _ _ b _)
         (when (string=? v ji)
           (if jloop (set! dup #t) (set! jloop s)))
         (find b)]
        [_ (void)])))
  (cond
    [(or (not jloop) dup)
     (emit! (diag "WVN024"
                  (format "@interchange names `~a`, but there is no unique loop over `~a`" ji ji)
                  (Interchange-line ic) '()))
     diags]
    [else
     (define ok
       (match jloop
         [(SFor _ (EInt 0) (EBin '< (EVar jv) jbound) jbody _)
          #:when (string=? jv ji)
          (match jbody
            [(list (SLocal 'float acc (EFloat 0.0) _)
                   (SFor pv (EInt 0) (EBin '< (EVar pv2) pbound) pbody _)
                   (SAssign (LvIndex cb sub) 'set (EVar acc2) _))
             #:when (and (string=? pv po) (string=? pv2 pv) (string=? acc2 acc))
             (match pbody
               [(list (SAssign (LvVar accn) 'add expr eline))
                #:when (string=? accn acc)
                ;; bounds invariance
                (define (bound-ok? b other)
                  (match b
                    [(EInt _) #t]
                    [(EVar n) (and (not (string=? n other)) (not (string=? n acc)))]
                    [_ #f]))
                (cond
                  [(not (and (bound-ok? jbound po) (bound-ok? pbound ji)))
                   (emit! (diag "WVN024"
                                "cannot prove interchange legal: loop bounds are not invariant names"
                                (Interchange-line ic) '()))
                   #f]
                  ;; store subscript: <j-invariant> + j, no reference to p
                  [(not (match sub
                          [(EBin '+ rest (EVar v)) #:when (string=? v ji)
                           (and (not (refs? rest ji)) (not (refs? rest po)))]
                          [_ #f]))
                   (emit! (diag "WVN024"
                                (format "cannot prove interchange legal: store subscript `~a[~a]` is not `<~a-invariant> + ~a`"
                                        cb (expr->string sub) ji ji)
                                (Interchange-line ic) '()))
                   #f]
                  ;; the accumulated expression must not touch acc or c
                  [(refs? expr acc)
                   (emit! (diag "WVN024"
                                (format "cannot prove interchange legal: the accumulation reads `~a` itself" acc)
                                eline '()))
                   #f]
                  [(reads-array? expr cb)
                   (emit! (diag "WVN020"
                                (format "cannot prove interchange legal: `~a` is read inside the accumulation" cb)
                                eline '()))
                   #f]
                  [else
                   ;; c must never be read anywhere in the kernel
                   (define c-read #f)
                   (let scan ([stmts (MethodDef-body def)])
                     (for ([s (in-list stmts)])
                       (match s
                         [(SLocal _ _ init _) (when (reads-array? init cb) (set! c-read #t))]
                         [(SAssign tgt op val _)
                          (when (reads-array? val cb) (set! c-read #t))
                          (match tgt
                            [(LvIndex b ix)
                             (when (reads-array? ix cb) (set! c-read #t))
                             ;; `c[..] += ...` anywhere is a read of c
                             (when (and (string=? b cb) (eq? op 'add)) (set! c-read #t))]
                            [_ (void)])]
                         [(SFor _ init cond-e b _)
                          (when (or (reads-array? init cb) (reads-array? cond-e cb)) (set! c-read #t))
                          (scan b)]
                         [(SReturn v _) (when (and v (reads-array? v cb)) (set! c-read #t))]
                         [_ (void)])))
                   (when c-read
                     (emit! (diag "WVN020"
                                  (format "cannot prove interchange legal: `~a` is read (or accumulated in place) elsewhere in the kernel" cb)
                                  (Interchange-line ic) '())))
                   (not c-read)])]
               [_ (emit! (diag "WVN024"
                               (format "cannot prove interchange legal: the `~a` loop body must be exactly `~a += <expr>;`" po acc)
                               (Interchange-line ic) '()))
                  #f])]
            [_ (emit! (diag "WVN024"
                            (format "cannot prove interchange legal: the `~a` loop body must be exactly `float acc = 0.0f; for ~a { acc += ...; } c[...] = acc;`" ji po)
                            (Interchange-line ic) '()))
               #f])]
         [_ (emit! (diag "WVN024"
                         (format "cannot prove interchange legal: the `~a` loop must run `0 .. bound` with `<`" ji)
                         (Interchange-line ic) '()))
            #f]))
     (void ok)
     diags]))

;; --------------------------------------------------- parallelism legality
;;
;; @parallel(i): the outer loop's iterations run concurrently. Obligations
;; (WVN025 refuses anything unprovable):
;;   - the kernel body is exactly one loop, over i, running 0..bound `<`
;;   - every write subscript is injective in i: either exactly `i`, or the
;;     row-major form `i*B + j` where j is an inner loop var with bound B
;;   - reads of a written array are cell-local: each read subscript is
;;     syntactically identical to a write subscript of that array
;;   - no scalar declared outside the loop is assigned inside it
;;   - no return inside the loop

(define (parallel-check def par)
  (define diags '())
  (define (emit! d) (set! diags (append diags (list d))))
  (define iv (Parallel-var par))
  (match (MethodDef-body def)
    [(list (SFor v (EInt 0) (EBin '< (EVar v2) (or (EVar _) (EInt _))) lbody _))
     #:when (and (string=? v iv) (string=? v2 iv))
     ;; walk the loop, tracking inner-loop bounds and declarations
     (define loop-bound (make-hash))   ; inner loop var -> bound expr
     (define inner-decl (make-hash))
     (define writes (make-hash))       ; base -> list of (cons sub line)
     (define reads (make-hash))        ; base -> list of (cons sub line)
     (hash-set! inner-decl iv #t)
     (define (wexpr e line)
       (match e
         [(EIndex b ix)
          (hash-update! reads b (λ (l) (cons (cons ix line) l)) '())
          (wexpr ix line)]
         [(EBin _ l r) (wexpr l line) (wexpr r line)]
         [_ (void)]))
     (define (wstmts stmts)
       (for ([s (in-list stmts)])
         (match s
           [(SLocal _ name init line)
            (wexpr init line)
            (hash-set! inner-decl name #t)]
           [(SAssign target op value line)
            (wexpr value line)
            (match target
              [(LvIndex b ix)
               (wexpr ix line)
               (hash-update! writes b (λ (l) (cons (cons ix line) l)) '())
               (when (eq? op 'add)
                 (hash-update! reads b (λ (l) (cons (cons ix line) l)) '()))]
              [(LvVar nm)
               (unless (hash-ref inner-decl nm #f)
                 (emit! (diag "WVN025"
                              (format "cannot prove parallelism legal: scalar `~a` is carried across iterations of `~a`" nm iv)
                              line
                              '("declare it inside the loop, or remove @parallel"))))])]
           [(SFor v2 init cond-e body line)
            (hash-set! inner-decl v2 #t)
            (match cond-e
              [(EBin '< (EVar cv) b) #:when (string=? cv v2)
               (hash-set! loop-bound v2 b)]
              [_ (void)])
            (wexpr init line)
            (wexpr cond-e line)
            (wstmts body)]
           [(SReturn _ line)
            (emit! (diag "WVN025" "return inside a @parallel loop is not supported" line '()))]
           [_ (void)])))
     (wstmts lbody)
     ;; write subscripts must be injective in iv
     (define (injective-in-iv? sub)
       (match sub
         [(EVar v3) (string=? v3 iv)]
         [(EBin '+ (EBin '* (EVar v1) bexpr) (EVar j2))
          #:when (string=? v1 iv)
          (define jb (hash-ref loop-bound j2 #f))
          (and jb (equal? jb bexpr))]
         [_ #f]))
     (for ([(b subs) (in-hash writes)])
       (for ([sl (in-list subs)])
         (unless (injective-in-iv? (car sl))
           (emit! (diag "WVN025"
                        (format "cannot prove parallelism legal: write subscript `~a[~a]` is not injective in `~a`"
                                b (expr->string (car sl)) iv)
                        (cdr sl)
                        '("remove @parallel, or rewrite the store in `i` or `i*B + j` form")))))
       ;; reads of a written array must be cell-local
       (define wsubs (map car subs))
       (for ([rl (in-list (hash-ref reads b '()))])
         (unless (ormap (λ (w) (equal? w (car rl))) wsubs)
           (emit! (diag "WVN025"
                        (format "cannot prove parallelism legal: `~a` is read at `~a[~a]`, which is not one of its write locations"
                                b b (expr->string (car rl)))
                        (cdr rl)
                        '("remove @parallel, or make the access cell-local"))))))
     diags]
    [_
     (emit! (diag "WVN025"
                  (format "@parallel(~a) requires the kernel body to be exactly one loop over `~a` running `0 .. bound`" iv iv)
                  (Parallel-line par) '()))
     diags]))

;; ------------------------------------------------ manual vectorization
;;
;; @vectorize(manual, width: N): wyvec vectorizes the loop itself, so it can
;; place @stream's nontemporal hint on the vector store. Stage 0 restricts
;; this to pure elementwise loops — the shape where hand-vectorization is
;; unambiguous (WVN040 refuses everything else):
;;   - the body is exactly one loop `for (usize i = 0; i < bound; i++)`
;;   - no locals, no nested loops, no return
;;   - every statement is `arr[i] = <expr>` (plain set, not +=)
;;   - every subscript is exactly `i` (offset 0): no neighbors, no reductions
;;   - expressions use only scalar params, float literals, arr[i] loads, and
;;     arithmetic — no comparisons

(define (manual-check decl def params v)
  (define diags '())
  (define (emit! msg line) (set! diags (append diags (list (diag "WVN040" msg line '())))))
  (define line (Vectorize-line v))
  (define (elementwise-expr? e)
    (match e
      [(EFloat _) #t]
      [(EInt _) #t]
      [(EVar n) (and (hash-ref params n #f)
                     (not (Ptr? (Param-ty (hash-ref params n)))))] ; scalar param
      [(EIndex b ix) (and (hash-ref params b #f) (match ix [(EVar _) #t] [_ #f]))]
      [(EBin op l r) (and (not (cmp-op? op)) (elementwise-expr? l) (elementwise-expr? r))]
      [_ #f]))
  (match (MethodDef-body def)
    [(list (SFor iv (EInt 0) (EBin '< (EVar iv2) bound) lbody _))
     #:when (string=? iv iv2)
     (unless (match bound [(EVar _) #t] [(EInt _) #t] [_ #f])
       (emit! "@vectorize(manual) needs a simple `i < bound` loop" line))
     (for ([s (in-list lbody)])
       (match s
         [(SAssign (LvIndex base (EVar j)) 'set value sline)
          (cond
            [(not (string=? j iv))
             (emit! (format "@vectorize(manual): subscript `~a[~a]` must be exactly `~a`" base j iv) sline)]
            [(not (hash-ref params base #f))
             (emit! (format "@vectorize(manual): `~a` is not a pointer parameter" base) sline)]
            [(not (elementwise-expr? value))
             (emit! (format "@vectorize(manual): the right-hand side is not elementwise (only scalar params, literals, `arr[~a]`, and arithmetic)" iv) sline)]
            ;; every indexed read in value must also be at offset 0
            [else
             (let check ([e value])
               (match e
                 [(EIndex _ (EVar j2)) (unless (string=? j2 iv)
                                         (emit! (format "@vectorize(manual): read `~a[~a]` must be at offset 0 (`~a`)"
                                                        (EIndex-base e) j2 iv) sline))]
                 [(EIndex _ _) (emit! "@vectorize(manual): non-affine read subscript" sline)]
                 [(EBin _ l r) (check l) (check r)]
                 [_ (void)]))])]
         [(SAssign (LvIndex _ _) 'add _ sline)
          (emit! "@vectorize(manual): `+=` is a reduction, not elementwise" sline)]
         [(SLocal _ _ _ sline)
          (emit! "@vectorize(manual): locals are not supported in stage 0" sline)]
         [(SFor _ _ _ _ sline)
          (emit! "@vectorize(manual): nested loops are not supported" sline)]
         [(SReturn _ sline)
          (emit! "@vectorize(manual): return is not supported" sline)]
         [_ (emit! "@vectorize(manual): unsupported statement" line)]))
     diags]
    [_
     (emit! "@vectorize(manual) requires the body to be exactly one elementwise loop" line)
     diags]))

;; ----------------------------------------------------- @simd vector kernels
;;
;; Explicit, shuffle-shaped vector code: vector locals, slice loads/stores,
;; and shuffle. Stage 0 shape (WVN041 refuses the rest):
;;   - void kernel; body is vector-local declarations then slice stores
;;   - floatN with N in {2,4,8,16}
;;   - floatN v = base[idx : N]    (base a pointer param, idx usize)
;;   - floatN v = shuffle(a, b, i…)  (a,b same floatN, each i in 0..2N-1,
;;                                     index count in {2,4,8,16})
;;   - base[idx : N] = v           (store a floatN into a slice)
;;   - no loops, no scalar arithmetic, no return

(define (vec-width? n) (and (memq n '(2 4 8 16)) #t))

(define (simd-check decl def params)
  (define diags '())
  (define (emit! msg line) (set! diags (append diags (list (diag "WVN041" msg line '())))))
  (define locals (make-hash))   ; name -> n (floatN)
  (unless (eq? (Sig-ret decl) 'void)
    (emit! "@simd kernels must return void" (Sig-line decl)))
  (define (idx-ok? e)
    (match e
      [(EInt _) #t]
      [(EVar n) (let ([p (hash-ref params n #f)]) (and p (eq? (Param-ty p) 'usize)))]
      [_ #f]))
  ;; returns the vector width of an expression, or #f (after emitting)
  (define (scalar-float? n)
    (let ([p (hash-ref params n #f)]) (and p (eq? (Param-ty p) 'float))))
  ;; infer returns: a vector width (int), 'scalar (a broadcastable float), or #f
  (define (infer e line)
    (match e
      [(EVar n)
       (cond
         [(hash-ref locals n #f)]
         [(scalar-float? n) 'scalar]    ; a scalar float param broadcasts
         [else (emit! (format "`~a` is not a vector local or scalar float" n) line) #f])]
      [(EFloat _) 'scalar]
      [(EBin op l r)
       (cond
         [(cmp-op? op) (emit! "comparisons are not vector arithmetic" line) #f]
         [else
          (define nl (infer l line))
          (define nr (infer r line))
          (cond
            [(or (not nl) (not nr)) #f]
            [(and (eq? nl 'scalar) (eq? nr 'scalar))
             (emit! "at least one operand of a vector expression must be a vector" line) #f]
            [(eq? nl 'scalar) nr]       ; scalar broadcasts to the vector width
            [(eq? nr 'scalar) nl]
            [(not (= nl nr)) (emit! "vector arithmetic operands must have the same width" line) #f]
            [else nl])])]
      [(EVecLoad base idx len)
       (cond
         [(not (vec-width? len)) (emit! (format "slice length ~a must be 2, 4, 8, or 16" len) line) #f]
         [(not (let ([p (hash-ref params base #f)]) (and p (Ptr? (Param-ty p)))))
          (emit! (format "`~a` is not a pointer parameter" base) line) #f]
         [(not (idx-ok? idx)) (emit! "slice offset must be a usize value" line) #f]
         [else len])]
      [(EShuffle a b idxs)
       (define na (infer a line))
       (define nb (infer b line))
       (cond
         [(or (not na) (not nb)) #f]
         [(not (= na nb)) (emit! "shuffle operands must have the same width" line) #f]
         [(not (vec-width? (length idxs)))
          (emit! (format "shuffle produces ~a lanes; must be 2, 4, 8, or 16" (length idxs)) line) #f]
         [(not (andmap (λ (i) (and (>= i 0) (< i (* 2 na)))) idxs))
          (emit! (format "shuffle index out of range 0..~a" (sub1 (* 2 na))) line) #f]
         [else (length idxs)])]
      ;; cmul(x, y): complex multiply, structure-of-arrays [re… im…]
      [(ECall "cmul" args)
       (cond
         [(not (= (length args) 2)) (emit! "cmul takes 2 arguments" line) #f]
         [else
          (define na (infer (car args) line))
          (define nb (infer (cadr args) line))
          (cond
            [(or (not na) (not nb)) #f]
            [(not (= na nb)) (emit! "cmul operands must have the same width" line) #f]
            [(odd? na) (emit! "cmul needs an even width (real then imaginary halves)" line) #f]
            [else na])])]
      [(ECall name _) (emit! (format "unknown @simd builtin `~a` (cmul)" name) line) #f]
      [_ (emit! "@simd expressions are slice loads, shuffles, cmul, and vector locals only" line) #f]))
  (for ([s (in-list (MethodDef-body def))])
    (match s
      [(SLocal (VecF n) name init line)
       (cond
         [(not (vec-width? n)) (emit! (format "float~a is not a valid vector width (2, 4, 8, 16)" n) line)]
         [(hash-ref locals name #f) (emit! (format "`~a` is already defined" name) line)]
         [else
          (define m (infer init line))
          (cond
            [(not m) (void)]
            [(eq? m 'scalar)
             (emit! (format "cannot initialize vector local `~a` from a scalar (use it inside a vector expression)" name) line)]
            [(not (= m n))
             (emit! (format "initializer is float~a, but `~a` is float~a" m name n) line)])
          (hash-set! locals name n)])]
      [(SLocal _ name _ line)
       (emit! (format "@simd locals must be vector-typed (floatN); `~a` is not" name) line)]
      [(SAssign (LvSlice base idx len) 'set value line)
       (cond
         [(not (vec-width? len)) (emit! (format "slice length ~a must be 2, 4, 8, or 16" len) line)]
         [(not (let ([p (hash-ref params base #f)]) (and p (Ptr? (Param-ty p)))))
          (emit! (format "`~a` is not a pointer parameter" base) line)]
         [(and (hash-ref params base #f) (Ptr-const? (Param-ty (hash-ref params base))))
          (emit! (format "cannot store through `~a`: it is a const pointer" base) line)]
         [(not (idx-ok? idx)) (emit! "slice offset must be a usize value" line)]
         [else
          (define m (infer value line))
          (cond
            [(not m) (void)]
            [(eq? m 'scalar) (emit! "cannot store a scalar into a vector slice" line)]
            [(not (= m len)) (emit! (format "storing float~a into a float~a slice" m len) line)])])]
      [(SAssign _ _ _ line)
       (emit! "@simd statements are vector-local declarations and slice stores only" line)]
      [(SFor _ _ _ _ line) (emit! "@simd kernels have no loops in stage 0" line)]
      [(SReturn _ line) (emit! "@simd kernels return void implicitly" line)]
      [_ (emit! "unsupported @simd statement" (Sig-line decl))]))
  diags)
