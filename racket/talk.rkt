#lang racket/base
;; The conversation with LLVM. wyvec speaks in contracts; LLVM answers in
;; optimization remarks (-foptimization-record-file YAML); this module
;; translates the replies back into the contract vocabulary.
(require racket/match racket/string racket/list racket/port racket/system racket/file
         "ast.rkt" "sema.rkt")
(provide talk-to-llvm find-clang clang-version)

(struct remark (verdict pass name function args) #:transparent) ; verdict: 'passed | 'missed | 'analysis

(define (remark-message r) (string-join (map cdr (remark-args r)) ""))
(define (remark-arg r key)
  (cond [(assoc key (remark-args r)) => cdr] [else #f]))

(define (find-clang)
  (or (find-executable-path "clang")
      (error 'wyve "`talk` needs clang on PATH to converse with LLVM")))

(define (clang-version)
  (define out (with-output-to-string (λ () (system* (find-clang) "--version"))))
  (string-trim (car (string-split out "\n"))))

;; ------------------------------------------------- remark YAML (tolerant)

(define (strip-quotes s)
  (if (and (>= (string-length s) 2)
           (char=? (string-ref s 0) #\')
           (char=? (string-ref s (sub1 (string-length s))) #\'))
      (substring s 1 (sub1 (string-length s)))
      s))

(define (parse-remarks text)
  (define remarks '())
  (define cur #f) ; (vector verdict pass name function args)
  (define in-args #f)
  (define (flush!)
    (when cur
      (set! remarks
            (append remarks
                    (list (remark (vector-ref cur 0) (vector-ref cur 1)
                                  (vector-ref cur 2) (vector-ref cur 3)
                                  (vector-ref cur 4)))))
      (set! cur #f)))
  (for ([line (in-list (string-split text "\n"))])
    (cond
      [(string-prefix? line "--- !")
       (flush!)
       (define tag (string-trim (substring line 5)))
       (set! cur (vector (match tag ["Passed" 'passed] ["Missed" 'missed] [_ 'analysis])
                         "" "" "" '()))
       (set! in-args #f)]
      [(not cur) (void)]
      [(string-prefix? line "...") (flush!) (set! in-args #f)]
      [(and (> (string-length line) 0) (not (char-whitespace? (string-ref line 0))))
       (define m (regexp-match #rx"^([A-Za-z]+): *(.*)$" line))
       (when m
         (define key (cadr m))
         (define val (strip-quotes (string-trim (caddr m))))
         (set! in-args (string=? key "Args"))
         (case key
           [("Pass") (vector-set! cur 1 val)]
           [("Name") (vector-set! cur 2 val)]
           [("Function") (vector-set! cur 3 val)]
           [else (void)]))]
      [in-args
       (define m (regexp-match #rx"^[ \t]*- ([A-Za-z]+): *(.*)$" line))
       (when m
         (vector-set! cur 4
                      (append (vector-ref cur 4)
                              (list (cons (cadr m) (strip-quotes (string-trim (caddr m))))))))]
      [else (void)]))
  (flush!)
  remarks)

;; --------------------------------------------------------- the conversation

;; returns #t when every required contract was honored
(define (talk-to-llvm kernels ir #:verified? [verified? #t])
  (define clang (find-clang))
  (define dir (build-path (find-system-path 'temp-dir)
                          (format "wyve-talk-~a" (current-milliseconds))))
  (make-directory* dir)
  (define ll (build-path dir "kernels.ll"))
  (define obj (build-path dir "kernels.o"))
  (define yaml (build-path dir "remarks.yaml"))
  (display-to-file ir ll #:exists 'replace)
  (define err-out (open-output-string))
  (define ok
    (parameterize ([current-error-port err-out]
                   [current-output-port (open-output-nowhere)])
      (system* clang "-O2" "-c" "-Wno-override-module"
               (format "-foptimization-record-file=~a" (path->string yaml))
               "-foptimization-record-passes=loop-vectorize"
               "-o" (path->string obj)
               (path->string ll))))
  (unless ok
    (error 'wyve (format "clang rejected wyvec's IR (a wyvec bug):\n~a" (get-output-string err-out))))
  (define remarks (parse-remarks (if (file-exists? yaml) (file->string yaml) "")))
  (printf "; talking to ~a\n" (clang-version))
  (define honored
    (for/fold ([all #t]) ([k (in-list kernels)])
      (define this-ok (report-kernel k remarks verified?))
      (and this-ok all)))
  (delete-directory/files dir #:must-exist? #f)
  (flush-output)
  honored)

(define (report-kernel k remarks verified?)
  (define decl (kernel-decl k))
  (define c (Sig-contracts decl))
  (printf "\n~a [~a]\n" (kernel-iface k) (sig-selector decl))
  ;; your side of the conversation
  (define e (Contracts-effect c))
  (when e
    (printf "  you : @effect(reads(~a), writes(~a)) — verified against the body\n"
            (string-join (Effect-reads e) ", ")
            (string-join (Effect-writes e) ", ")))
  (define noalias-params
    (for/list ([p (in-list (sig-params decl))] #:when (Param-noalias? p)) (Param-name p)))
  (unless (null? noalias-params)
    (printf "  you : @noalias ~a — lowered to LLVM `noalias`\n" (string-join noalias-params ", ")))
  (when (Contracts-fp-reassoc? c)
    (printf "  you : @fp(reassoc) — float math may be reassociated\n"))
  (define v (Contracts-vectorize c))
  (when v
    (printf "  you : @vectorize(~a~a) — ~a\n"
            (if (Vectorize-require? v) "require" "hint")
            (if (Vectorize-width v) (format ", width: ~a" (Vectorize-width v)) "")
            (if verified?
                "proven legal by wyvec's dependence analysis"
                "UNPROVEN — sent under protest, LLVM decides alone")))
  ;; LLVM's reply
  (define mine
    (for/list ([r (in-list remarks)]
               #:when (and (string=? (remark-function r) (kernel-symbol k))
                           (string=? (remark-pass r) "loop-vectorize")))
      r))
  (define passed (for/list ([r (in-list mine)] #:when (eq? (remark-verdict r) 'passed)) r))
  (define missed (for/list ([r (in-list mine)] #:unless (eq? (remark-verdict r) 'passed)) r))
  (cond
    [(and v (pair? passed))
     (for ([p (in-list passed)])
       (printf "  llvm: ~a\n" (remark-message p)))
     (define vf
       (let ([s (remark-arg (car passed) "VectorizationFactor")])
         (and s (string->number s))))
     (define w (Vectorize-width v))
     (cond
       [(and w vf (= w vf))
        (printf "  => contract honored: vectorized at the required width ~a\n" w)
        #t]
       [(and w vf)
        (printf "  => DISAGREEMENT: contract requires width ~a, LLVM chose ~a\n" w vf)
        #f]
       [else
        (printf "  => contract honored: loop vectorized\n")
        #t])]
    [v
     (if (null? mine)
         (printf "  llvm: (silence — no loop-vectorize report for this kernel)\n")
         (for ([m (in-list missed)])
           (printf "  llvm: ~a\n" (remark-message m))))
     (printf "  => DISAGREEMENT: wyvec proved this loop legal, but LLVM did not vectorize it\n")
     (printf "     toolchain regression or missing LLVM capability — wyvec's verdict stands\n")
     #f]
    [(pair? passed)
     (for ([p (in-list passed)])
       (printf "  llvm: (volunteered) ~a\n" (remark-message p)))
     #t]
    [else
     (printf "  llvm: (nothing to say)\n")
     #t]))
