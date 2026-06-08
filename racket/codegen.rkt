#lang racket/base
;; Textual LLVM IR emission. Contracts arrive verified; this is transcription:
;;   @noalias -> noalias, @effect -> readonly/writeonly, @vectorize -> !llvm.loop,
;;   @fp(...) -> fast-math flags on float arithmetic,
;;   @tile / @interchange -> AST transforms (transform.rkt) before emission,
;;   @parallel -> wrapper + worker + alwaysinline body over dispatch_apply_f,
;;   @vectorize(manual) -> wyvec emits the vector loop itself,
;;   @simd -> explicit vector code (slice loads, shuffles, vector stores).
;; Locals are alloca slots; LLVM's mem2reg rebuilds SSA. No datalayout or
;; triple is emitted — the host toolchain supplies its defaults.
;;
;; Structure: a kernel's shared, immutable emission data lives in an `ectx`;
;; each layout (scalar emit-fn / manual / simd / parallel) is a top-level
;; function over that ectx. emit-kernel just builds the ectx and dispatches.
(require racket/match racket/string racket/format racket/flonum racket/list
         "ast.rkt" "sema.rkt" "transform.rkt")
(provide emit-module)

(define (llty t)
  (match t
    ['void "void"] ['float "float"] ['double "double"]
    ['usize "i64"] ['int "i32"] ['bool "i1"]
    [(Ptr _ _) "ptr"]))

;; LLVM spells `float` constants as the bit pattern of the f64 that the f32
;; value widens to.
(define (flit x)
  (define s (flsingle (exact->inexact x)))
  (define bs (real->floating-point-bytes s 8 #t))
  (define n (integer-bytes->integer bs #f #t))
  (format "0x~a" (string-upcase (~r n #:base 16 #:min-width 16 #:pad-string "0"))))

;; `double` constants: the bit pattern of the f64 directly.
(define (flit-d x)
  (define bs (real->floating-point-bytes (exact->inexact x) 8 #t))
  (define n (integer-bytes->integer bs #f #t))
  (format "0x~a" (string-upcase (~r n #:base 16 #:min-width 16 #:pad-string "0"))))

;; the LLVM literal for a numeric constant of a given Wyve type
(define (numlit ty v)
  (match ty
    ['float (flit v)] ['double (flit-d v)]
    [_ (number->string v)]))   ; usize/int integer literal

;; the LLVM conversion opcode for a numeric cast (same type handled by caller)
(define (cast-instr from to)
  (match (list from to)
    ['(float double) "fpext"] ['(double float) "fptrunc"]
    [(list (or 'float 'double) 'int) "fptosi"]
    [(list (or 'float 'double) 'usize) "fptoui"]
    [(list 'int (or 'float 'double)) "sitofp"]
    [(list 'usize (or 'float 'double)) "uitofp"]
    ['(int usize) "sext"] ['(usize int) "trunc"]))

;; math builtins -> LLVM intrinsics
(define (intr-suffix ty) (match ty ['float "f32"] ['double "f64"] ['int "i32"] ['usize "i64"]))
(define (intr-name name ty)
  (define s (intr-suffix ty))
  (case name
    [("min") (if (type-float? ty) (format "@llvm.minnum.~a" s)
                 (if (eq? ty 'int) "@llvm.smin.i32" "@llvm.umin.i64"))]
    [("max") (if (type-float? ty) (format "@llvm.maxnum.~a" s)
                 (if (eq? ty 'int) "@llvm.smax.i32" "@llvm.umax.i64"))]
    [("abs") (if (type-float? ty) (format "@llvm.fabs.~a" s) (format "@llvm.abs.~a" s))]
    [("sqrt") (format "@llvm.sqrt.~a" s)]
    [("fma") (format "@llvm.fma.~a" s)]))
(define (intr-decl name ty)
  (define lt (llty ty))
  (define params
    (case name
      [("min" "max") (format "~a, ~a" lt lt)]
      [("sqrt") lt]
      [("abs") (if (type-float? ty) lt (format "~a, i1" lt))]
      [("fma") (format "~a, ~a, ~a" lt lt lt)]))
  (format "declare ~a ~a(~a)" lt (intr-name name ty) params))

;; the loop metadata a kernel's contracts ask for, as rendered node bodies
(define (loop-md-entries c)
  (define v (Contracts-vectorize c))
  (define u (Contracts-unroll c))
  (append
   (cond
     [(and v (Vectorize-disable? v))
      (list "!{!\"llvm.loop.vectorize.enable\", i1 false}")]
     [v
      (append
       (list "!{!\"llvm.loop.vectorize.enable\", i1 true}")
       (let ([w (Vectorize-width v)])
         (if w (list (format "!{!\"llvm.loop.vectorize.width\", i32 ~a}" w)) '()))
       (let ([il (Vectorize-interleave v)])
         (if il (list (format "!{!\"llvm.loop.interleave.count\", i32 ~a}" il)) '()))
       (if (Vectorize-predicate? v)
           (list "!{!\"llvm.loop.vectorize.predicate.enable\", i1 true}")
           '())
       (if (Vectorize-scalable? v)
           (list "!{!\"llvm.loop.vectorize.scalable.enable\", i1 true}")
           '()))]
     [else '()])
   (if u
       (list (format "!{!\"llvm.loop.unroll.count\", i32 ~a}" (Unroll-count u)))
       '())))

;; ------------------------------------------------------------ emission ctx
;; Shared, immutable per-kernel data. The mutable emission state (temp
;; counter, locals) lives inside each emitter; only this constant context
;; is threaded across them.
(struct ectx (o k decl eff fp-str params-hash params-by-name write-only body
              md-entries md-alloc! nt-id record-intr! callee-sigs))

(define (make-ectx o k md-alloc! nt-id record-intr! callee-sigs)
  (define decl (kernel-decl k))
  (define cs (Sig-contracts decl))
  (define eff (Contracts-effect cs))
  (define fp-str
    (apply string-append
           (for/list ([f (in-list (Contracts-fp-flags cs))]) (format " ~a" f))))
  (define params-hash
    (for/hash ([p (in-list (sig-params decl))]) (values (Param-name p) (Param-ty p))))
  (define params-by-name
    (for/hash ([p (in-list (sig-params decl))]) (values (Param-name p) p)))
  (define write-only
    (if (and (Contracts-stream? cs) eff)
        (for/hash ([w (in-list (Effect-writes eff))]
                   #:unless (member w (Effect-reads eff)))
          (values w #t))
        (hash)))
  ;; scheduling transforms run here, above LLVM, on the proven AST
  (define body
    (let* ([b (MethodDef-body (kernel-def k))]
           [b (let ([ti (Contracts-tile cs)]) (if ti (apply-tile b (Tile-pairs ti)) b))]
           [b (let ([ic (Contracts-interchange cs)])
                (if ic (apply-interchange b (Interchange-outer ic) (Interchange-inner ic)) b))])
      b))
  (ectx o k decl eff fp-str params-hash params-by-name write-only body
        (loop-md-entries cs) md-alloc! nt-id record-intr! callee-sigs))

;; the alignment for a vector load/store of `base` (param align, or element)
(define (varr-align ctx base)
  (or (Param-align (hash-ref (ectx-params-by-name ctx) base)) 4))

;; suffix appended to a store into a write-only array under @stream
(define (nt-suffix ctx base)
  (if (and (ectx-nt-id ctx) (hash-ref (ectx-write-only ctx) base #f))
      (format ", !nontemporal !~a" (ectx-nt-id ctx))
      ""))

;; one parameter's declaration: type + attributes (noalias/nocapture/
;; readonly/writeonly/align)
(define (param-decl ctx p)
  (define eff (ectx-eff ctx))
  (define attrs
    (if (Ptr? (Param-ty p))
        (let* ([r (if eff (and (member (Param-name p) (Effect-reads eff)) #t)
                      (Ptr-const? (Param-ty p)))]
               [w (if eff (and (member (Param-name p) (Effect-writes eff)) #t) #f)])
          (string-append
           (if (Param-noalias? p) " noalias" "")
           " nocapture"
           (cond [(and r (not w)) " readonly"]
                 [(and w (not r)) " writeonly"]
                 [else ""])
           (if (Param-align p) (format " align ~a" (Param-align p)) "")))
        ""))
  (format "~a~a %~a" (llty (Param-ty p)) attrs (Param-name p)))

;; ------------------------------------------------------ scalar emitter
;; The general one-function emitter: scalar expressions, loops, branches,
;; calls. Reused for the @parallel body. Mutable state (tmp/loopn/locals)
;; is local; the ectx supplies everything constant.
(define (emit-fn ctx #:name name #:stmts stmts
                 #:linkage [linkage ""] #:attrs [attrs "#0"]
                 #:extra-args [extra ""] #:extra-allocas [xall '()]
                 #:prologue [prologue '()] #:ret [ret (Sig-ret (ectx-decl ctx))])
  (define o (ectx-o ctx))
  (define decl (ectx-decl ctx))
  (define fp-str (ectx-fp-str ctx))
  (define params-hash (ectx-params-hash ctx))
  (define md-entries (ectx-md-entries ctx))
  (define md-alloc! (ectx-md-alloc! ctx))
  (define record-intr! (ectx-record-intr! ctx))
  (define callee-sigs (ectx-callee-sigs ctx))
  (define tmp 0)
  (define loopn 0)
  (define (t!) (begin0 (format "%t~a" tmp) (set! tmp (add1 tmp))))
  (define locals (make-hash))
  (define (line! s) (fprintf o "  ~a\n" s))
  (define (label! l) (fprintf o "~a:\n" l))

  (define (arith ty op)
    (define instr
      (match (list ty op)
        ['(float +) "fadd"] ['(float -) "fsub"] ['(float *) "fmul"] ['(float /) "fdiv"]
        ['(double +) "fadd"] ['(double -) "fsub"] ['(double *) "fmul"] ['(double /) "fdiv"]
        ['(usize +) "add"] ['(usize -) "sub"] ['(usize *) "mul"] ['(usize /) "udiv"]
        ['(int +) "add"] ['(int -) "sub"] ['(int *) "mul"] ['(int /) "sdiv"]))
    (string-append instr (if (type-float? ty) fp-str "")))

  (define (gep b ix)
    (define elem (Ptr-pointee (hash-ref params-hash b)))
    (define-values (iv _) (ev ix 'usize))   ; subscripts are usize-width
    (define r (t!))
    (line! (format "~a = getelementptr inbounds ~a, ptr %~a, i64 ~a" r (llty elem) b iv))
    (values r elem))

  ;; ev takes an optional expected type so an integer literal adopts the
  ;; type of its context (i32 in an int array, i64 as a usize)
  (define (ev e [expected #f])
    (match e
      [(EInt v)
       (values (number->string v) (if (and expected (type-integer? expected)) expected 'usize))]
      [(EFloat v) (values (flit v) 'float)]
      [(EDouble v) (values (flit-d v) 'double)]
      [(EVar n)
       (cond
         [(hash-ref params-hash n #f) => (λ (ty) (values (format "%~a" n) ty))]
         [else
          (define ty (hash-ref locals n))
          (define r (t!))
          (line! (format "~a = load ~a, ptr %~a.addr" r (llty ty) n))
          (values r ty)])]
      [(EMin a b)
       (define-values (av _ta) (ev a 'usize))
       (define-values (bv _tb) (ev b 'usize))
       (define c (t!))
       (line! (format "~a = icmp ult i64 ~a, ~a" c av bv))
       (define r (t!))
       (line! (format "~a = select i1 ~a, i64 ~a, i64 ~a" r c av bv))
       (values r 'usize)]
      [(EIndex b ix)
       (define-values (ptr elem) (gep b ix))
       (define r (t!))
       (line! (format "~a = load ~a, ptr ~a" r (llty elem) ptr))
       (values r elem)]
      [(ECall fname args)
       ;; evaluate non-literal args first to fix the type, then literals
       (define vals (make-vector (length args) #f))
       (define types (make-vector (length args) #f))
       (for ([a (in-list args)] [i (in-naturals)] #:unless (EInt? a))
         (define-values (v t) (ev a expected))
         (vector-set! vals i v) (vector-set! types i t))
       (define ty (or (for/or ([t (in-vector types)]) t) expected 'usize))
       (for ([a (in-list args)] [i (in-naturals)] #:when (EInt? a))
         (define-values (v _t) (ev a ty))
         (vector-set! vals i v))
       (record-intr! (intr-decl fname ty))
       (define arglist
         (if (and (string=? fname "abs") (type-integer? ty))
             (format "~a ~a, i1 false" (llty ty) (vector-ref vals 0))
             (string-join (for/list ([v (in-vector vals)]) (format "~a ~a" (llty ty) v)) ", ")))
       (define r (t!))
       (line! (format "~a = call ~a ~a(~a)" r (llty ty) (intr-name fname ty) arglist))
       (values r ty)]
      [(ECast ty e)
       (define-values (v et) (ev e))
       (if (equal? et ty)
           (values v ty)
           (let ([r (t!)])
             (line! (format "~a = ~a ~a ~a to ~a" r (cast-instr et ty) (llty et) v (llty ty)))
             (values r ty)))]
      [(EBin op l r0)
       ;; evaluate the non-literal side first so a literal adopts its type
       (define-values (lv lt rv rt)
         (cond
           [(and (EInt? l) (not (EInt? r0)))
            (define-values (rv0 rt0) (ev r0 expected))
            (define-values (lv0 lt0) (ev l rt0))
            (values lv0 lt0 rv0 rt0)]
           [(and (EInt? r0) (not (EInt? l)))
            (define-values (lv0 lt0) (ev l expected))
            (define-values (rv0 rt0) (ev r0 lt0))
            (values lv0 lt0 rv0 rt0)]
           [else
            (define-values (lv0 lt0) (ev l expected))
            (define-values (rv0 rt0) (ev r0 expected))
            (values lv0 lt0 rv0 rt0)]))
       (define r (t!))
       (cond
         [(cmp-op? op)
          (define pred
            (match (list lt op)
              ['(usize <) "icmp ult"] ['(usize <=) "icmp ule"]
              ['(usize >) "icmp ugt"] ['(usize >=) "icmp uge"]
              ['(usize ==) "icmp eq"] ['(usize !=) "icmp ne"]
              ['(int <) "icmp slt"] ['(int <=) "icmp sle"]
              ['(int >) "icmp sgt"] ['(int >=) "icmp sge"]
              ['(int ==) "icmp eq"] ['(int !=) "icmp ne"]
              ['(float <) "fcmp olt"] ['(float <=) "fcmp ole"]
              ['(float >) "fcmp ogt"] ['(float >=) "fcmp oge"]
              ['(float ==) "fcmp oeq"] ['(float !=) "fcmp une"]
              ['(double <) "fcmp olt"] ['(double <=) "fcmp ole"]
              ['(double >) "fcmp ogt"] ['(double >=) "fcmp oge"]
              ['(double ==) "fcmp oeq"] ['(double !=) "fcmp une"]))
          (line! (format "~a = ~a ~a ~a, ~a" r pred (llty lt) lv rv))
          (values r 'bool)]
         [else
          (line! (format "~a = ~a ~a ~a, ~a" r (arith lt op) (llty lt) lv rv))
          (values r lt)])]))

  (define (st s)
    (match s
      [(SLocal ty nm init _)
       (define-values (v _t) (ev init ty))
       (line! (format "store ~a ~a, ptr %~a.addr" (llty ty) v nm))]
      [(SAssign (LvVar n) op value _)
       (define ty (hash-ref locals n))
       (define-values (v _t) (ev value ty))
       (define fin
         (if (eq? op 'add)
             (let ([old (t!)])
               (line! (format "~a = load ~a, ptr %~a.addr" old (llty ty) n))
               (let ([r (t!)])
                 (line! (format "~a = ~a ~a ~a, ~a" r (arith ty '+) (llty ty) old v))
                 r))
             v))
       (line! (format "store ~a ~a, ptr %~a.addr" (llty ty) fin n))]
      [(SAssign (LvIndex b ix) op value _)
       (define elem0 (Ptr-pointee (hash-ref params-hash b)))
       (define-values (v _t) (ev value elem0))
       (define-values (ptr elem) (gep b ix))
       (define fin
         (if (eq? op 'add)
             (let ([old (t!)])
               (line! (format "~a = load ~a, ptr ~a" old (llty elem) ptr))
               (let ([r (t!)])
                 (line! (format "~a = ~a ~a ~a, ~a" r (arith elem '+) (llty elem) old v))
                 r))
             v))
       (line! (format "store ~a ~a, ptr ~a~a" (llty elem) fin ptr (nt-suffix ctx b)))]
      [(SFor var init cond-e fbody _)
       (define n loopn)
       (set! loopn (add1 loopn))
       (define-values (iv _t) (ev init 'usize))
       (line! (format "store i64 ~a, ptr %~a.addr" iv var))
       (line! (format "br label %for~a.cond" n))
       (label! (format "for~a.cond" n))
       (define-values (cv _t2) (ev cond-e))
       (line! (format "br i1 ~a, label %for~a.body, label %for~a.end" cv n n))
       (label! (format "for~a.body" n))
       (for ([s2 (in-list fbody)]) (st s2))
       (line! (format "br label %for~a.inc" n))
       (label! (format "for~a.inc" n))
       (define old (t!))
       (line! (format "~a = load i64, ptr %~a.addr" old var))
       (define inc (t!))
       (line! (format "~a = add nuw i64 ~a, 1" inc old))
       (line! (format "store i64 ~a, ptr %~a.addr" inc var))
       (define md-ref
         (if (null? md-entries) ""
             (format ", !llvm.loop !~a" (md-alloc! md-entries))))
       (line! (format "br label %for~a.cond~a" n md-ref))
       (label! (format "for~a.end" n))]
      [(SForStep var bound step sbody _)
       ;; tile loop: 0 .. bound, stride `step`; never carries vectorize
       ;; metadata — it exists to shape locality, not lanes
       (define n loopn)
       (set! loopn (add1 loopn))
       (line! (format "store i64 0, ptr %~a.addr" var))
       (line! (format "br label %for~a.cond" n))
       (label! (format "for~a.cond" n))
       (define iv (t!))
       (line! (format "~a = load i64, ptr %~a.addr" iv var))
       (define-values (bv _tb) (ev bound))
       (define cmp (t!))
       (line! (format "~a = icmp ult i64 ~a, ~a" cmp iv bv))
       (line! (format "br i1 ~a, label %for~a.body, label %for~a.end" cmp n n))
       (label! (format "for~a.body" n))
       (for ([s2 (in-list sbody)]) (st s2))
       (line! (format "br label %for~a.inc" n))
       (label! (format "for~a.inc" n))
       (define old (t!))
       (line! (format "~a = load i64, ptr %~a.addr" old var))
       (define inc (t!))
       (line! (format "~a = add nuw i64 ~a, ~a" inc old step))
       (line! (format "store i64 ~a, ptr %~a.addr" inc var))
       (line! (format "br label %for~a.cond" n))
       (label! (format "for~a.end" n))]
      [(SReturn value _)
       (if value
           (let-values ([(v _t) (ev value ret)])
             (line! (format "ret ~a ~a" (llty ret) v)))
           (line! "ret void"))]
      [(SCall iface labels args _)
       (define sym (format "~a_~a" iface (car labels)))
       (define ps (hash-ref callee-sigs sym))
       (define argstrs
         (for/list ([a (in-list args)] [p (in-list ps)])
           (define-values (v _t) (ev a (Param-ty p)))
           (format "~a ~a" (llty (Param-ty p)) v)))
       (line! (format "call void @~a(~a)" sym (string-join argstrs ", ")))]
      [(SIf cond-e then-body else-body _)
       (define n loopn)
       (set! loopn (add1 loopn))
       (define-values (cv _t) (ev cond-e))
       (define has-else (pair? else-body))
       (line! (format "br i1 ~a, label %if~a.then, label %if~a.~a"
                      cv n n (if has-else "else" "end")))
       (label! (format "if~a.then" n))
       (for ([s2 (in-list then-body)]) (st s2))
       (line! (format "br label %if~a.end" n))
       (when has-else
         (label! (format "if~a.else" n))
         (for ([s2 (in-list else-body)]) (st s2))
         (line! (format "br label %if~a.end" n)))
       (label! (format "if~a.end" n))]))

  ;; header
  (fprintf o "define ~a~a @~a(~a~a) ~a {\n"
           linkage (llty ret) name
           (string-join (for/list ([p (sig-params decl)]) (param-decl ctx p)) ", ")
           extra attrs)
  (label! "entry")
  ;; allocas (deduped — transforms may reuse loop vars in sibling loops)
  (define allocs '())
  (define seen-allocs (make-hash))
  (define (alloca! nm ty)
    (unless (hash-ref seen-allocs nm #f)
      (hash-set! seen-allocs nm #t)
      (set! allocs (append allocs (list (cons nm ty))))))
  (for ([a (in-list xall)]) (alloca! (car a) (cdr a)))
  (define (collect! stmts*)
    (for ([s (in-list stmts*)])
      (match s
        [(SLocal ty nm _ _) (alloca! nm ty)]
        [(SFor var _ _ fb _) (alloca! var 'usize) (collect! fb)]
        [(SForStep var _ _ fb _) (alloca! var 'usize) (collect! fb)]
        [(SIf _ tb eb _) (collect! tb) (collect! eb)]
        [_ (void)])))
  (collect! stmts)
  (for ([a (in-list allocs)])
    (hash-set! locals (car a) (cdr a))
    (line! (format "%~a.addr = alloca ~a, align ~a"
                   (car a) (llty (cdr a))
                   (match (cdr a) ['usize 8] ['double 8] [_ 4]))))
  (for ([pl (in-list prologue)]) (line! pl))
  (for ([s (in-list stmts)]) (st s))
  (when (and (eq? ret 'void)
             (not (and (pair? stmts) (SReturn? (car (reverse stmts))))))
    (line! "ret void"))
  (fprintf o "}\n"))

;; ------------------------------------------------------ manual vectorizer
;; @vectorize(manual): wyvec vectorizes the elementwise loop itself — a
;; vector main loop (so @stream's nontemporal can ride a vector store, and
;; @align gives aligned vector ops) plus a scalar remainder.
(define (emit-manual ctx)
  (define o (ectx-o ctx))
  (define k (ectx-k ctx))
  (define decl (ectx-decl ctx))
  (define fp-str (ectx-fp-str ctx))
  (define W (Vectorize-width (Contracts-vectorize (Sig-contracts decl))))
  (define vty (format "<~a x float>" W))
  (match-define (list (SFor _iv (EInt 0) (EBin '< _ bound-e) lbody _)) (ectx-body ctx))
  (define bound (match bound-e [(EVar n) (format "%~a" n)] [(EInt c) (number->string c)]))
  (fprintf o "; kernel ~a [~a] — @vectorize(manual, width: ~a)\n"
           (kernel-iface k) (sig-selector decl) W)
  (fprintf o "define void @~a(~a) #0 {\n" (kernel-symbol k)
           (string-join (for/list ([p (sig-params decl)]) (param-decl ctx p)) ", "))
  (define tmp 0)
  (define (t!) (begin0 (format "%t~a" tmp) (set! tmp (add1 tmp))))
  (define (line! s) (fprintf o "  ~a\n" s))
  (define (label! l) (fprintf o "~a:\n" l))
  (define (gep base idx)
    (define r (t!))
    (line! (format "~a = getelementptr inbounds float, ptr %~a, i64 ~a" r base idx))
    r)
  ;; float arithmetic instruction + the kernel's fp flags (same for scalar
  ;; and vector — only the operand type differs)
  (define (fop op)
    (string-append (match op ['+ "fadd"] ['- "fsub"] ['* "fmul"] ['/ "fdiv"]) fp-str))
  (define (vsplat scalar)
    (define a (t!))
    (line! (format "~a = insertelement ~a poison, float ~a, i64 0" a vty scalar))
    (define b (t!))
    (line! (format "~a = shufflevector ~a ~a, ~a poison, <~a x i32> zeroinitializer" b vty a vty W))
    b)
  (define (vev e idx)
    (match e
      [(EFloat c) (format "<~a>" (string-join (make-list W (format "float ~a" (flit c))) ", "))]
      [(EVar n) (vsplat (format "%~a" n))]      ; scalar float param
      [(EIndex base (EVar _)) ; offset 0, guaranteed by sema
       (define p (gep base idx))
       (define r (t!))
       (line! (format "~a = load ~a, ptr ~a, align ~a" r vty p (varr-align ctx base)))
       r]
      [(EBin op l r0)
       (define lv (vev l idx))
       (define rv (vev r0 idx))
       (define res (t!))
       (line! (format "~a = ~a ~a ~a, ~a" res (fop op) vty lv rv))
       res]))
  (define (sev e idx)
    (match e
      [(EFloat c) (flit c)]
      [(EVar n) (format "%~a" n)]
      [(EIndex base (EVar _))
       (define p (gep base idx))
       (define r (t!))
       (line! (format "~a = load float, ptr ~a" r p))
       r]
      [(EBin op l r0)
       (define lv (sev l idx))
       (define rv (sev r0 idx))
       (define res (t!))
       (line! (format "~a = ~a float ~a, ~a" res (fop op) lv rv))
       res]))
  (label! "entry")
  (line! "%i.addr = alloca i64, align 8")
  (line! "store i64 0, ptr %i.addr")
  (line! (format "%vn = and i64 ~a, ~a" bound (- W)))   ; bound rounded down to a multiple of W
  (line! "br label %vec.cond")
  (label! "vec.cond")
  (define vi (t!))
  (line! (format "~a = load i64, ptr %i.addr" vi))
  (define vc (t!))
  (line! (format "~a = icmp ult i64 ~a, %vn" vc vi))
  (line! (format "br i1 ~a, label %vec.body, label %tail.cond" vc))
  (label! "vec.body")
  (define vidx (t!))
  (line! (format "~a = load i64, ptr %i.addr" vidx))
  (for ([s (in-list lbody)])
    (match-define (SAssign (LvIndex base (EVar _)) 'set value _) s)
    (define val (vev value vidx))
    (define dp (gep base vidx))
    (line! (format "store ~a ~a, ptr ~a, align ~a~a" vty val dp (varr-align ctx base) (nt-suffix ctx base))))
  (define vinc (t!))
  (line! (format "~a = add nuw i64 ~a, ~a" vinc vidx W))
  (line! (format "store i64 ~a, ptr %i.addr" vinc))
  (line! "br label %vec.cond")
  (label! "tail.cond")
  (define ti (t!))
  (line! (format "~a = load i64, ptr %i.addr" ti))
  (define tc (t!))
  (line! (format "~a = icmp ult i64 ~a, ~a" tc ti bound))
  (line! (format "br i1 ~a, label %tail.body, label %done" tc))
  (label! "tail.body")
  (define tidx (t!))
  (line! (format "~a = load i64, ptr %i.addr" tidx))
  (for ([s (in-list lbody)])
    (match-define (SAssign (LvIndex base (EVar _)) 'set value _) s)
    (define val (sev value tidx))
    (define dp (gep base tidx))
    (line! (format "store float ~a, ptr ~a~a" val dp (nt-suffix ctx base))))
  (define tinc (t!))
  (line! (format "~a = add nuw i64 ~a, 1" tinc tidx))
  (line! (format "store i64 ~a, ptr %i.addr" tinc))
  (line! "br label %tail.cond")
  (label! "done")
  (line! "ret void")
  (fprintf o "}\n"))

;; ------------------------------------------------------------ simd emitter
;; @simd: explicit vector code — straight-line, SSA, no loop. Vector locals
;; are SSA values; slice loads/stores and shuffles map 1:1 to LLVM.
(define (emit-simd ctx)
  (define o (ectx-o ctx))
  (define k (ectx-k ctx))
  (define decl (ectx-decl ctx))
  (define fp-str (ectx-fp-str ctx))
  (fprintf o "; kernel ~a [~a] — @simd (explicit vectors)\n"
           (kernel-iface k) (sig-selector decl))
  (fprintf o "define void @~a(~a) #0 {\nentry:\n" (kernel-symbol k)
           (string-join (for/list ([p (sig-params decl)]) (param-decl ctx p)) ", "))
  (define tmp 0)
  (define (t!) (begin0 (format "%t~a" tmp) (set! tmp (add1 tmp))))
  (define (line! s) (fprintf o "  ~a\n" s))
  (define ssa (make-hash))   ; local name -> (cons operand n)
  (define (vty n) (format "<~a x float>" n))
  (define (idxval e) (match e [(EInt c) (number->string c)] [(EVar n) (format "%~a" n)]))
  (define (gep base idx)
    (define r (t!))
    (line! (format "~a = getelementptr inbounds float, ptr %~a, i64 ~a" r base (idxval idx)))
    r)
  (define (fop op)
    (string-append (match op ['+ "fadd"] ['- "fsub"] ['* "fmul"] ['/ "fdiv"]) fp-str))
  (define (splat scalar n)
    (define a (t!))
    (line! (format "~a = insertelement ~a poison, float ~a, i64 0" a (vty n) scalar))
    (define b (t!))
    (line! (format "~a = shufflevector ~a ~a, ~a poison, <~a x i32> zeroinitializer" b (vty n) a (vty n) n))
    b)
  ;; returns (values operand n), where n is the vector width or 'scalar
  (define (vev e)
    (match e
      [(EVar nm)
       (cond [(hash-ref ssa nm #f) => (λ (c) (values (car c) (cdr c)))]
             [else (values (format "%~a" nm) 'scalar)])]   ; scalar float param
      [(EFloat c) (values (flit c) 'scalar)]
      [(EBin op l r0)
       (define-values (lv ln) (vev l))
       (define-values (rv rn) (vev r0))
       ;; broadcast a scalar operand to the vector's width (FFT twiddle)
       (define n (if (number? ln) ln rn))
       (define lo (if (eq? ln 'scalar) (splat lv n) lv))
       (define ro (if (eq? rn 'scalar) (splat rv n) rv))
       (define res (t!))
       (line! (format "~a = ~a ~a ~a, ~a" res (fop op) (vty n) lo ro))
       (values res n)]
      [(EVecLoad base idx len)
       (define p (gep base idx))
       (define r (t!))
       (line! (format "~a = load ~a, ptr ~a, align ~a" r (vty len) p (varr-align ctx base)))
       (values r len)]
      [(EShuffle a b idxs)
       (define-values (va na) (vev a))
       (define-values (vb _nb) (vev b))
       (define m (length idxs))
       (define mask (string-join (map (λ (i) (format "i32 ~a" i)) idxs) ", "))
       (define r (t!))
       (line! (format "~a = shufflevector ~a ~a, ~a ~a, <~a x i32> <~a>"
                      r (vty na) va (vty na) vb m mask))
       (values r m)]
      [(ECall "cmul" (list xe ye))
       ;; complex multiply, SoA [re_0…re_{h-1} im_0…im_{h-1}]:
       ;;   (a+bi)(c+di) = (ac-bd) + (ad+bc)i
       (define-values (xv n) (vev xe))
       (define-values (yv _n) (vev ye))
       (define h (quotient n 2))
       (define (dup-mask lo) (string-join (for*/list ([_ (in-range 2)] [i (in-range h)])
                                            (format "i32 ~a" (+ lo i))) ", "))
       (define (bcast v half)   ; broadcast one half of v across the full width
         (define r (t!))
         (line! (format "~a = shufflevector ~a ~a, ~a poison, <~a x i32> <~a>"
                        r (vty n) v (vty n) n (dup-mask (* half h))))
         r)
       (define xr (bcast xv 0)) (define xi (bcast xv 1))
       (define yr (bcast yv 0)) (define yi (bcast yv 1))
       (define (vop op a b)
         (define r (t!)) (line! (format "~a = ~a ~a ~a, ~a" r (fop op) (vty n) a b)) r)
       (define re (vop '- (vop '* xr yr) (vop '* xi yi)))   ; ac - bd
       (define im (vop '+ (vop '* xr yi) (vop '* xi yr)))   ; ad + bc
       ;; interleave: re half -> low lanes, im half -> high lanes
       (define rmask (string-join (append (for/list ([i (in-range h)]) (format "i32 ~a" i))
                                          (for/list ([i (in-range h)]) (format "i32 ~a" (+ n i)))) ", "))
       (define r (t!))
       (line! (format "~a = shufflevector ~a ~a, ~a ~a, <~a x i32> <~a>"
                      r (vty n) re (vty n) im n rmask))
       (values r n)]))
  (for ([s (in-list (MethodDef-body (kernel-def k)))])
    (match s
      [(SLocal (VecF n) nm init _)
       (define-values (v m) (vev init))
       (hash-set! ssa nm (cons v m))]
      [(SAssign (LvSlice base idx len) 'set value _)
       (define-values (v _m) (vev value))
       (define p (gep base idx))
       (line! (format "store ~a ~a, ptr ~a, align ~a~a" (vty len) v p (varr-align ctx base) (nt-suffix ctx base)))]))
  (line! "ret void")
  (fprintf o "}\n"))

;; -------------------------------------------------------- parallel emitter
;; @parallel(i): wrapper packs args and dispatches; worker unpacks and calls
;; an alwaysinline body fn that keeps the original parameter attributes —
;; inlining turns noalias params into scoped metadata, so the inner loops
;; stay vectorizable.
(define (emit-parallel ctx)
  (define o (ectx-o ctx))
  (define k (ectx-k ctx))
  (define decl (ectx-decl ctx))
  (match-define (list (SFor piv _ pcond plbody _)) (ectx-body ctx))
  (define bound-v
    (match pcond
      [(EBin '< _ (EVar v)) (format "%~a" v)]
      [(EBin '< _ (EInt c)) (number->string c)]))
  (define sym (kernel-symbol k))
  (define ps (sig-params decl))
  (define ctx-ty (format "%~a.ctx" sym))
  (fprintf o "; kernel ~a [~a] — @parallel(~a) over dispatch_apply_f\n"
           (kernel-iface k) (sig-selector decl) piv)
  (fprintf o "~a = type { ~a }\n"
           ctx-ty (string-join (for/list ([p ps]) (llty (Param-ty p))) ", "))
  ;; wrapper (public ABI unchanged)
  (fprintf o "define void @~a(~a) #0 {\nentry:\n  %ctx = alloca ~a, align 8\n"
           sym (string-join (for/list ([p ps]) (param-decl ctx p)) ", ") ctx-ty)
  (for ([p ps] [i (in-naturals)])
    (fprintf o "  %f~a = getelementptr inbounds ~a, ptr %ctx, i32 0, i32 ~a\n" i ctx-ty i)
    (fprintf o "  store ~a %~a, ptr %f~a\n" (llty (Param-ty p)) (Param-name p) i))
  (fprintf o "  call void @dispatch_apply_f(i64 ~a, ptr null, ptr %ctx, ptr @~a.worker)\n"
           bound-v sym)
  (fprintf o "  ret void\n}\n")
  ;; worker (libdispatch shape): unpack, call body
  (fprintf o "define internal void @~a.worker(ptr %ctx, i64 %chunk) #0 {\nentry:\n" sym)
  (for ([p ps] [i (in-naturals)])
    (fprintf o "  %f~a = getelementptr inbounds ~a, ptr %ctx, i32 0, i32 ~a\n" i ctx-ty i)
    (fprintf o "  %~a = load ~a, ptr %f~a\n" (Param-name p) (llty (Param-ty p)) i))
  (fprintf o "  call void @~a.body(~a, i64 %chunk)\n"
           sym
           (string-join (for/list ([p ps])
                          (format "~a %~a" (llty (Param-ty p)) (Param-name p)))
                        ", "))
  (fprintf o "  ret void\n}\n")
  ;; body: one iteration of the outer loop, original attrs, alwaysinline
  (emit-fn ctx
           #:name (format "~a.body" sym)
           #:stmts plbody
           #:linkage "internal "
           #:attrs "#1"
           #:extra-args ", i64 %chunk"
           #:extra-allocas (list (cons piv 'usize))
           #:prologue (list (format "store i64 %chunk, ptr %~a.addr" piv))
           #:ret 'void))

;; --------------------------------------------------------------- dispatch
(define (emit-kernel o k md-alloc! nt-id record-intr! callee-sigs)
  (define ctx (make-ectx o k md-alloc! nt-id record-intr! callee-sigs))
  (define cs (Sig-contracts (ectx-decl ctx)))
  (cond
    [(Contracts-simd? cs) (emit-simd ctx)]
    [(and (Contracts-vectorize cs) (Vectorize-manual? (Contracts-vectorize cs)))
     (emit-manual ctx)]
    [(Contracts-parallel cs) (emit-parallel ctx)]
    [else
     (fprintf o "; kernel ~a [~a]\n" (kernel-iface k) (sig-selector (ectx-decl ctx)))
     (emit-fn ctx #:name (kernel-symbol k) #:stmts (ectx-body ctx))]))

(define (emit-module source-name kernels)
  (define any-stream?
    (ormap (λ (k) (and (Contracts-stream? (Sig-contracts (kernel-decl k))) #t)) kernels))
  ;; reserve !0 for the shared nontemporal node when any kernel streams
  (define nt-id (and any-stream? 0))
  (define md '())     ; list of (id . entries)
  (define md-next (if any-stream? 1 0))
  (define (md-alloc! entries)
    (define id md-next)
    (set! md-next (+ md-next 1 (length entries)))
    (set! md (append md (list (cons id entries))))
    id)
  (define any-parallel?
    (ormap (λ (k) (and (Contracts-parallel (Sig-contracts (kernel-decl k))) #t)) kernels))
  (define intrinsics (make-hash))   ; declare-string -> #t (deduped)
  (define (record-intr! decl) (hash-set! intrinsics decl #t))
  ;; mangled symbol -> parameter list, so a call site knows the callee's types
  (define callee-sigs
    (for/hash ([k (in-list kernels)]) (values (kernel-symbol k) (sig-params (kernel-decl k)))))
  (define o (open-output-string))
  (fprintf o "; generated by wyvec 0.1 (Wyve stage 0, Racket)\nsource_filename = \"~a\"\n" source-name)
  (for ([k (in-list kernels)])
    (fprintf o "\n")
    (emit-kernel o k md-alloc! nt-id record-intr! callee-sigs))
  (unless (zero? (hash-count intrinsics))
    (fprintf o "\n")
    (for ([d (in-list (sort (hash-keys intrinsics) string<?))]) (fprintf o "~a\n" d)))
  (when any-parallel?
    (fprintf o "\ndeclare void @dispatch_apply_f(i64, ptr, ptr, ptr)\n"))
  (fprintf o "\nattributes #0 = { nounwind }\n")
  (when any-parallel?
    (fprintf o "attributes #1 = { nounwind alwaysinline }\n"))
  (when (or any-stream? (not (null? md)))
    (fprintf o "\n")
    (when any-stream?
      (fprintf o "!0 = !{i32 1}\n"))
    (for ([entry (in-list md)])
      (define id (car entry))
      (define bodies (cdr entry))
      (fprintf o "!~a = distinct !{~a}\n" id
               (string-join (for/list ([i (in-range (add1 (length bodies)))])
                              (format "!~a" (+ id i)))
                            ", "))
      (for ([b (in-list bodies)] [i (in-naturals 1)])
        (fprintf o "!~a = ~a\n" (+ id i) b))))
  (get-output-string o))
