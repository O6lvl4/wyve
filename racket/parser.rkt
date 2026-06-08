#lang racket/base
;; Recursive-descent parser over the Objective-C grammar slice.
(require "lexer.rkt" "ast.rkt" "diag.rkt")
(provide parse)

(define (parse toks)
  (define pos 0)
  (define (cur) (vector-ref toks pos))
  (define (cur-line) (tok-line (cur)))
  (define (bump!)
    (begin0 (cur)
      (when (< pos (sub1 (vector-length toks)))
        (set! pos (add1 pos)))))
  (define (perr msg) (raise (diag #f msg (cur-line) '())))
  (define (at-type? ty) (eq? (tok-type (cur)) ty))
  (define (at-kw? k) (and (at-type? 'kw) (eq? (tok-val (cur)) k)))
  (define (at-directive? name) (and (at-type? 'at) (string=? (tok-val (cur)) name)))
  (define (eat? ty) (and (at-type? ty) (begin (bump!) #t)))
  (define (eat-kw? k) (and (at-kw? k) (begin (bump!) #t)))
  (define (expect! ty what) (unless (eat? ty) (perr (format "expected ~a" what))))
  (define (expect-ident what)
    (if (at-type? 'ident)
        (tok-val (bump!))
        (perr (format "expected ~a" what))))

  ;; ---------------------------------------------------------------- module
  (define (parse-module)
    (define ifaces '())
    (define impls '())
    (let loop ()
      (cond
        [(at-directive? "interface")
         (set! ifaces (append ifaces (list (parse-interface))))
         (loop)]
        [(at-directive? "implementation")
         (set! impls (append impls (list (parse-impl))))
         (loop)]
        [(at-type? 'eof) (void)]
        [else (perr "expected `@interface` or `@implementation` at top level")]))
    (Module ifaces impls))

  (define (parse-interface)
    (define line (cur-line))
    (bump!) ; @interface
    (define name (expect-ident "interface name"))
    (define methods '())
    (let loop ()
      (cond
        [(at-directive? "end") (bump!)]
        [(at-type? 'eof) (perr "unterminated @interface (missing @end)")]
        [else
         (define contracts (parse-contracts))
         (define sig (parse-method-sig contracts))
         (expect! 'semi "`;` after method declaration")
         (set! methods (append methods (list sig)))
         (loop)]))
    (Iface name methods line))

  (define (parse-impl)
    (define line (cur-line))
    (bump!) ; @implementation
    (define name (expect-ident "implementation name"))
    (define methods '())
    (let loop ()
      (cond
        [(at-directive? "end") (bump!)]
        [(at-type? 'eof) (perr "unterminated @implementation (missing @end)")]
        [else
         (define cline (cur-line))
         (define contracts (parse-contracts))
         (unless (contracts-empty? contracts)
           (raise (diag #f
                        "contracts belong on the @interface declaration, not the @implementation"
                        cline '())))
         (define sig (parse-method-sig contracts))
         (expect! 'lbrace "`{` to begin method body")
         (define body (parse-block))
         (set! methods (append methods (list (MethodDef sig body))))
         (loop)]))
    (Impl name methods line))

  ;; ------------------------------------------------------------- contracts
  (define (parse-contracts)
    (define effect #f)
    (define vectorize #f)
    (define unroll #f)
    (define tile #f)
    (define interchange #f)
    (define parallel #f)
    (define stream #f)
    (define simd #f)
    (define fp-flags '())
    (let loop ()
      (define line (cur-line))
      (cond
        [(at-directive? "effect")
         (bump!)
         (expect! 'lparen "`(` after @effect")
         (define reads '())
         (define writes '())
         (let clause-loop ()
           (define kind (expect-ident "`reads` or `writes`"))
           (expect! 'lparen "`(`")
           (define names '())
           (let name-loop ()
             (set! names (append names (list (expect-ident "parameter name"))))
             (when (eat? 'comma) (name-loop)))
           (expect! 'rparen "`)`")
           (cond
             [(string=? kind "reads") (set! reads (append reads names))]
             [(string=? kind "writes") (set! writes (append writes names))]
             [else (raise (diag #f
                                (format "unknown effect clause `~a` (expected `reads` or `writes`)" kind)
                                line '()))])
           (when (eat? 'comma) (clause-loop)))
         (expect! 'rparen "`)` to close @effect")
         (set! effect (Effect reads writes line))
         (loop)]
        [(at-directive? "vectorize")
         (bump!)
         (expect! 'lparen "`(` after @vectorize")
         (define require? #f)
         (define manual? #f)
         (define width #f)
         (define interleave #f)
         (define predicate? #f)
         (define scalable? #f)
         (define disable? #f)
         (define (int-item! what store!)
           (expect! 'colon (format "`:` after `~a`" what))
           (if (at-type? 'int)
               (store! (tok-val (bump!)))
               (perr (format "expected integer ~a" what))))
         (let item-loop ()
           (define item (expect-ident "a @vectorize item"))
           (cond
             [(string=? item "require") (set! require? #t)]
             [(string=? item "manual") (set! manual? #t)]
             [(string=? item "disable") (set! disable? #t)]
             [(string=? item "predicate") (set! predicate? #t)]
             [(string=? item "scalable") (set! scalable? #t)]
             [(string=? item "width") (int-item! "width" (λ (v) (set! width v)))]
             [(string=? item "interleave") (int-item! "interleave" (λ (v) (set! interleave v)))]
             [else (raise (diag #f
                                (format "unknown @vectorize item `~a` (expected require, manual, disable, width, interleave, predicate, scalable)" item)
                                line '()))])
           (when (eat? 'comma) (item-loop)))
         (expect! 'rparen "`)` to close @vectorize")
         (set! vectorize (Vectorize require? manual? width interleave predicate? scalable? disable? line))
         (loop)]
        [(at-directive? "unroll")
         (bump!)
         (expect! 'lparen "`(` after @unroll")
         (define require? #f)
         (define count #f)
         (let item-loop ()
           (define item (expect-ident "`require` or `count`"))
           (cond
             [(string=? item "require") (set! require? #t)]
             [(string=? item "count")
              (expect! 'colon "`:` after `count`")
              (if (at-type? 'int)
                  (set! count (tok-val (bump!)))
                  (perr "expected integer count"))]
             [else (raise (diag #f
                                (format "unknown @unroll item `~a` (expected `require` or `count`)" item)
                                line '()))])
           (when (eat? 'comma) (item-loop)))
         (expect! 'rparen "`)` to close @unroll")
         (unless count
           (raise (diag #f "@unroll needs a count (e.g. @unroll(count: 4))" line '())))
         (set! unroll (Unroll require? count line))
         (loop)]
        [(at-directive? "tile")
         (bump!)
         (expect! 'lparen "`(` after @tile")
         (define pairs '())
         (let item-loop ()
           (define iv (expect-ident "induction variable"))
           (expect! 'colon "`:` after the induction variable")
           (if (at-type? 'int)
               (set! pairs (append pairs (list (cons iv (tok-val (bump!))))))
               (perr "expected integer tile size"))
           (when (eat? 'comma) (item-loop)))
         (expect! 'rparen "`)` to close @tile")
         (set! tile (Tile pairs line))
         (loop)]
        [(at-directive? "interchange")
         (bump!)
         (expect! 'lparen "`(` after @interchange")
         (define new-outer (expect-ident "the loop to hoist (new outer)"))
         (expect! 'comma "`,`")
         (define new-inner (expect-ident "the loop it crosses (new inner)"))
         (expect! 'rparen "`)` to close @interchange")
         (set! interchange (Interchange new-outer new-inner line))
         (loop)]
        [(at-directive? "parallel")
         (bump!)
         (expect! 'lparen "`(` after @parallel")
         (define iv (expect-ident "induction variable"))
         (expect! 'rparen "`)` to close @parallel")
         (set! parallel (Parallel iv line))
         (loop)]
        [(at-directive? "stream")
         (bump!)
         (set! stream #t)
         (loop)]
        [(at-directive? "simd")
         (bump!)
         (set! simd #t)
         (loop)]
        [(at-directive? "fp")
         (bump!)
         (expect! 'lparen "`(` after @fp")
         (let flag-loop ()
           (define flag (string->symbol (expect-ident "fp flag")))
           (unless (memq flag fp-flag-names)
             (raise (diag #f
                          (format "unknown fp flag `~a` (expected one of: ~a)"
                                  flag (fp-flags->string fp-flag-names))
                          line '())))
           (set! fp-flags (append fp-flags (list flag)))
           (when (eat? 'comma) (flag-loop)))
         (expect! 'rparen "`)` to close @fp")
         (loop)]
        [else (void)]))
    (Contracts effect vectorize unroll tile interchange parallel stream simd fp-flags))

  ;; -------------------------------------------------------------- methods
  (define (parse-method-sig contracts)
    (define line (cur-line))
    (unless (eat? 'plus)
      (perr "expected `+` (kernels are class methods; instance methods are not part of stage 0)"))
    (expect! 'lparen "`(` before return type")
    (define ret (parse-base-type))
    (when (at-type? 'star)
      (perr "pointer return types are not part of stage 0"))
    (expect! 'rparen "`)` after return type")
    (define first-label (expect-ident "selector"))
    (define parts '())
    (cond
      [(eat? 'colon)
       (define param (parse-param))
       (set! parts (list (SelPart first-label param)))
       (let loop ()
         (when (at-type? 'ident)
           (define label (tok-val (bump!)))
           (expect! 'colon "`:` after selector label")
           (define p (parse-param))
           (set! parts (append parts (list (SelPart label p))))
           (loop)))]
      [else
       (set! parts (list (SelPart first-label #f)))])
    (Sig contracts ret parts line))

  (define (parse-param)
    (define line (cur-line))
    (expect! 'lparen "`(` before parameter type")
    (define noalias #f)
    (define align #f)
    ;; type qualifiers: @noalias and @align(n), in any order, before const
    (let qual-loop ()
      (when (at-type? 'at)
        (define q (tok-val (cur)))
        (cond
          [(string=? q "noalias") (bump!) (set! noalias #t) (qual-loop)]
          [(string=? q "align")
           (bump!)
           (expect! 'lparen "`(` after @align")
           (if (at-type? 'int)
               (set! align (tok-val (bump!)))
               (perr "expected integer alignment"))
           (expect! 'rparen "`)` to close @align")
           (qual-loop)]
          [else (perr (format "unknown type qualifier `@~a`" q))])))
    (define is-const (eat-kw? 'const))
    (define base (parse-base-type))
    (define ty
      (cond
        [(eat? 'star) (Ptr is-const base)]
        [else
         (when is-const
           (raise (diag #f "`const` on a by-value parameter has no meaning in Wyve" line '())))
         (when (eq? base 'void)
           (raise (diag #f "parameter cannot be void" line '())))
         base]))
    (when (and noalias (not (Ptr? ty)))
      (raise (diag #f "@noalias applies only to pointer parameters" line '())))
    (when (and align (not (Ptr? ty)))
      (raise (diag #f "@align applies only to pointer parameters" line '())))
    (expect! 'rparen "`)` after parameter type")
    (define name (expect-ident "parameter name"))
    (Param noalias align ty name))

  (define (parse-base-type)
    (cond
      [(eat-kw? 'float) 'float]
      [(eat-kw? 'double) 'double]
      [(eat-kw? 'usize) 'usize]
      [(eat-kw? 'int) 'int]
      [(eat-kw? 'void) 'void]
      [(at-type? 'vecf) (VecF (tok-val (bump!)))]
      [else (perr "expected a type (`float`, `double`, `usize`, `int`, `void`, `floatN`)")]))

  ;; ------------------------------------------------------------ statements
  ;; assumes `{` already consumed; consumes through matching `}`
  (define (parse-block)
    (define stmts '())
    (let loop ()
      (cond
        [(eat? 'rbrace) (void)]
        [(at-type? 'eof) (perr "unterminated block (missing `}`)")]
        [else
         (set! stmts (append stmts (list (parse-stmt))))
         (loop)]))
    stmts)

  (define (parse-stmt)
    (define line (cur-line))
    (cond
      [(or (at-kw? 'float) (at-kw? 'double) (at-kw? 'usize) (at-kw? 'int) (at-type? 'vecf))
       (define ty (parse-base-type))
       (define name (expect-ident "variable name"))
       (expect! 'assign "`=` (locals must be initialized)")
       (define init (parse-expr))
       (expect! 'semi "`;`")
       (SLocal ty name init line)]
      [(at-kw? 'for)
       (bump!)
       (expect! 'lparen "`(` after `for`")
       (unless (eat-kw? 'usize)
         (perr "loop induction variable must be `usize`"))
       (define var (expect-ident "induction variable"))
       (expect! 'assign "`=`")
       (define init (parse-expr))
       (expect! 'semi "`;`")
       (define cond-e (parse-expr))
       (expect! 'semi "`;`")
       (define step (expect-ident "induction variable in step"))
       (unless (string=? step var)
         (perr (format "step must increment the induction variable `~a`" var)))
       (expect! 'plusplus "`++` (stage 0 supports unit-stride loops only)")
       (expect! 'rparen "`)`")
       (expect! 'lbrace "`{`")
       (define body (parse-block))
       (SFor var init cond-e body line)]
      [(at-kw? 'return)
       (bump!)
       (define value (if (at-type? 'semi) #f (parse-expr)))
       (expect! 'semi "`;`")
       (SReturn value line)]
      [(at-type? 'lbracket)             ; [Iface label:arg …]  — kernel call
       (bump!)
       (define iface (expect-ident "receiver (interface name)"))
       (define labels '())
       (define args '())
       (let loop ()
         (when (at-type? 'ident)
           (define lbl (tok-val (bump!)))
           (expect! 'colon "`:` after selector label")
           (set! labels (append labels (list lbl)))
           (set! args (append args (list (parse-expr))))
           (loop)))
       (when (null? labels) (perr "a kernel call needs at least one `label:arg`"))
       (expect! 'rbracket "`]` to close the call")
       (expect! 'semi "`;`")
       (SCall iface labels args line)]
      [(at-kw? 'if)
       (bump!)
       (expect! 'lparen "`(` after `if`")
       (define c (parse-expr))
       (expect! 'rparen "`)`")
       (expect! 'lbrace "`{`")
       (define then-body (parse-block))
       (define else-body
         (cond
           [(eat-kw? 'else)
            (expect! 'lbrace "`{` after `else`")
            (parse-block)]
           [else '()]))
       (SIf c then-body else-body line)]
      [(at-type? 'ident)
       (define name (tok-val (bump!)))
       (define target
         (cond
           [(eat? 'lbracket)
            (define idx (parse-expr))
            (cond
              [(eat? 'colon)              ; base[idx : len] = vec  (slice store)
               (unless (at-type? 'int) (perr "expected slice length"))
               (define len (tok-val (bump!)))
               (expect! 'rbracket "`]`")
               (LvSlice name idx len)]
              [else
               (expect! 'rbracket "`]`")
               (LvIndex name idx)])]
           [else (LvVar name)]))
       (define op
         (cond [(eat? 'pluseq) 'add]
               [(eat? 'assign) 'set]
               [else (perr "expected `=` or `+=`")]))
       (define value (parse-expr))
       (expect! 'semi "`;`")
       (SAssign target op value line)]
      [else (perr "expected a statement")]))

  ;; ----------------------------------------------------------- expressions
  (define (parse-expr)
    (define lhs (parse-add))
    (define op
      (cond [(at-type? 'lt) '<]
            [(at-type? 'le) '<=]
            [(at-type? 'gt) '>]
            [(at-type? 'ge) '>=]
            [(at-type? 'eqeq) '==]
            [(at-type? 'ne) '!=]
            [else #f]))
    (cond
      [op
       (bump!)
       (EBin op lhs (parse-add))]
      [else lhs]))

  (define (parse-add)
    (let loop ([lhs (parse-mul)])
      (cond
        [(at-type? 'plus) (bump!) (loop (EBin '+ lhs (parse-mul)))]
        [(at-type? 'minus) (bump!) (loop (EBin '- lhs (parse-mul)))]
        [else lhs])))

  (define (parse-mul)
    (let loop ([lhs (parse-unary)])
      (cond
        [(at-type? 'star) (bump!) (loop (EBin '* lhs (parse-unary)))]
        [(at-type? 'slash) (bump!) (loop (EBin '/ lhs (parse-unary)))]
        [(at-type? 'percent) (bump!) (loop (EBin '% lhs (parse-unary)))]
        [else lhs])))

  (define (parse-unary)
    (cond
      [(at-type? 'minus) (bump!) (ENeg (parse-unary))]
      [else (parse-primary)]))

  (define (parse-primary)
    (cond
      [(at-type? 'int) (EInt (tok-val (bump!)))]
      [(at-type? 'float) (EFloat (tok-val (bump!)))]
      [(at-type? 'double) (EDouble (tok-val (bump!)))]
      [(at-type? 'shuffle)             ; shuffle(a, b, i0, i1, …)
       (bump!)
       (expect! 'lparen "`(` after shuffle")
       (define a (parse-expr))
       (expect! 'comma "`,`")
       (define b (parse-expr))
       (define idxs '())
       (let loop ()
         (expect! 'comma "`,`")
         (unless (at-type? 'int) (perr "shuffle index must be an integer"))
         (set! idxs (append idxs (list (tok-val (bump!)))))
         (when (at-type? 'comma) (loop)))
       (expect! 'rparen "`)` to close shuffle")
       (EShuffle a b idxs)]
      [(at-type? 'ident)
       (define name (tok-val (bump!)))
       (cond
         [(eat? 'lbracket)
          (define idx (parse-expr))
          (cond
            [(eat? 'colon)             ; base[idx : len]  (slice load)
             (unless (at-type? 'int) (perr "expected slice length"))
             (define len (tok-val (bump!)))
             (expect! 'rbracket "`]`")
             (EVecLoad name idx len)]
            [else
             (expect! 'rbracket "`]`")
             (EIndex name idx)])]
         [(eat? 'lparen)               ; name(args…)  (math builtin)
          (define args '())
          (unless (at-type? 'rparen)
            (let loop ()
              (set! args (append args (list (parse-expr))))
              (when (eat? 'comma) (loop))))
          (expect! 'rparen "`)` to close call")
          (ECall name args)]
         [else (EVar name)])]
      [(at-type? 'lparen)
       (bump!)
       (cond
         ;; (type)expr — a numeric cast (scalar types only)
         [(or (at-kw? 'float) (at-kw? 'double) (at-kw? 'usize) (at-kw? 'int))
          (define ty (parse-base-type))
          (expect! 'rparen "`)` after cast type")
          (ECast ty (parse-primary))]
         [else
          (define e (parse-expr))
          (expect! 'rparen "`)`")
          e])]
      [else (perr "expected an expression")]))

  (parse-module))
