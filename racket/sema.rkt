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
            (define kds (check-kernel (Iface-name iface) decl def))
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

(define (check-kernel iface-name decl def)
  (define diags '())
  (define (emit! d) (set! diags (append diags (list d))))
  (define params (for/hash ([p (in-list (sig-params decl))]) (values (Param-name p) p)))
  (define contracts (Sig-contracts decl))

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

  (set! diags (append diags (typecheck params (Sig-ret decl) def)))
  (cond
    [(pair? diags) diags]
    [else
     (when eff
       (set! diags (append diags (effect-check iface-name eff params (MethodDef-body def)))))
     (define v (Contracts-vectorize contracts))
     (when (and v (Vectorize-require? v))
       (set! diags (append diags (vectorize-check decl def params v))))
     diags]))

;; ------------------------------------------------------------- type check

(define (typecheck params ret def)
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

  (define (infer e line)
    (match e
      [(EInt _) 'usize]
      [(EFloat _) 'float]
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
          (when (and it (not (eq? it 'usize)))
            (emit! #f "subscript must be `usize`" line))
          (Ptr-pointee (Param-ty p))])]
      [(EBin op l r)
       (define lt (infer l line))
       (define rt (infer r line))
       (cond
         [(or (not lt) (not rt)) #f]
         [(not (equal? lt rt))
          (emit! #f (format "type mismatch: `~a` vs `~a`" (type->string lt) (type->string rt)) line) #f]
         [(not (type-numeric? lt))
          (emit! #f "operands must be numeric" line) #f]
         [(cmp-op? op) 'bool]
         [else lt])]))

  (define (do-block stmts)
    (define saved locals)
    (for ([s (in-list stmts)]) (do-stmt s))
    (set! locals saved))

  (define (do-stmt s)
    (match s
      [(SLocal ty name init line)
       (define t (infer init line))
       (when (and t (not (equal? t ty)))
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
               (when (and it (not (eq? it 'usize)))
                 (emit! #f "subscript must be `usize`" line))
               (Ptr-pointee (Param-ty p))])]))
       (when tty
         (define vt (infer value line))
         (when (and vt (not (equal? vt tty)))
           (emit! #f (format "cannot assign `~a` to `~a`" (type->string vt) (type->string tty)) line))
         (when (and (eq? op 'add) (not (type-numeric? tty)))
           (emit! #f "`+=` requires a numeric target" line)))]
      [(SFor var init cond-e body line)
       (define it (infer init line))
       (when (and it (not (eq? it 'usize)))
         (emit! #f "loop bounds must be `usize`" line))
       (define saved locals)
       (declare! var 'usize line)
       (match cond-e
         [(EBin op _ _) #:when (cmp-op? op) (infer cond-e line) (void)]
         [_ (emit! #f "loop condition must be a comparison" line)])
       (do-block body)
       (set! locals saved)]
      [(SReturn value line)
       (define vt (if value (infer value line) 'void))
       (when (and vt (not (equal? vt ret)))
         (emit! #f (format "return type `~a` does not match kernel return type `~a`"
                           (type->string vt) (type->string ret))
                line))]))

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
        [(SReturn value line) (when value (walk-expr value line))])))

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

(define (vectorize-check decl def params v)
  (define diags '())
  (define (emit! d) (set! diags (append diags (list d))))
  (define w (Vectorize-width v))
  (when (and w (not (power-of-two? w)))
    (emit! (diag #f (format "vectorize width must be a power of two, got ~a" w) (Vectorize-line v) '())))
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
                                 (Contracts-fp-reassoc? (Sig-contracts decl))))))
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
        [(SReturn _ line)
         (emit! (diag #f "return inside a @vectorize(require) loop is not vectorizable" line '()))])))

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
