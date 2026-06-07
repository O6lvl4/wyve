#lang racket/base
;; Pipeline glue + CLI.
;;   racket -l wyve/cli -- check <file.wyv>
;;   racket -l wyve/cli -- build <file.wyv> [-o out.ll]
;;   racket -l wyve/cli -- talk  <file.wyv>     ; converse with the optimizer
;;   racket -l wyve/cli -- run   <file.wyv>     ; talk, then execute on LLVM
(require racket/string racket/file racket/path racket/match
         "lexer.rkt" "parser.rkt" "sema.rkt" "codegen.rkt" "diag.rkt"
         "talk.rkt" "runner.rkt")
(provide compile-source run-source run-cli)

;; `#lang wyve` files reach the lexer with the hash-lang line still present
;; when read as plain text; blank it out so line numbers stay aligned.
(define (strip-hash-lang src)
  (if (regexp-match? #rx"^#lang" src)
      (let ([nl (regexp-match-positions #rx"\n" src)])
        (if nl
            (string-append (make-string (caar nl) #\space) (substring src (caar nl)))
            ""))
      src))

(define (source-name file)
  (define p (file-name-from-path (string->path file)))
  (if p (path->string p) file))

;; returns (values mod kernels ir diags); non-empty diags means rejection
(define (compile-source src file)
  (with-handlers ([diag? (λ (d) (values #f '() #f (list d)))])
    (define toks (lex (strip-hash-lang src)))
    (define mod (parse toks))
    (define-values (kernels diags) (check mod))
    (if (pair? diags)
        (values mod '() #f diags)
        (values mod kernels (emit-module (source-name file) kernels) '()))))

(define (print-diags! diags file)
  (for ([d (in-list diags)])
    (eprintf "~a" (diag-render d file))))

;; what `#lang wyve` programs do when you run them: verify, converse, execute
(define (run-source src file)
  (define-values (mod kernels ir diags) (compile-source src file))
  (cond
    [(pair? diags)
     (print-diags! diags file)
     (eprintf "\nwyvec: refused — the conversation with LLVM does not happen until the contracts hold\n")
     (exit 1)]
    [else
     (printf "wyvec: ~a kernel~a, contracts verified\n"
             (length kernels) (if (= (length kernels) 1) "" "s"))
     (define honored (talk-to-llvm kernels ir))
     (printf "\n; running on LLVM\n")
     (run-kernels kernels ir)
     (unless honored (exit 1))]))

(define (run-cli . args)
  (match args
    [(list "check" file)
     (define-values (_mod kernels _ir diags) (compile-source (file->string file) file))
     (cond
       [(pair? diags) (print-diags! diags file) (exit 1)]
       [else (printf "ok: ~a kernel(s), contracts verified\n" (length kernels))])]
    [(list "build" file)
     (define-values (_mod _kernels ir diags) (compile-source (file->string file) file))
     (cond
       [(pair? diags) (print-diags! diags file) (exit 1)]
       [else (display ir)])]
    [(list "build" file "-o" out)
     (define-values (_mod _kernels ir diags) (compile-source (file->string file) file))
     (cond
       [(pair? diags) (print-diags! diags file) (exit 1)]
       [else (display-to-file ir out #:exists 'replace)])]
    [(list "talk" file)
     (define-values (_mod kernels ir diags) (compile-source (file->string file) file))
     (cond
       [(pair? diags) (print-diags! diags file) (exit 1)]
       [else
        (printf "wyvec: ~a kernel(s), contracts verified\n" (length kernels))
        (unless (talk-to-llvm kernels ir) (exit 1))])]
    [(list "run" file)
     (run-source (file->string file) file)]
    [_
     (eprintf "usage: racket -l wyve/cli -- <check|build|talk|run> <file.wyv> [-o out.ll]\n")
     (exit 1)]))

(module+ main
  (apply run-cli (vector->list (current-command-line-arguments))))
