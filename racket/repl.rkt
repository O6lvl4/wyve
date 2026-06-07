#lang racket/base
;; The conversation room. Load a .wyv file, then interrogate LLVM:
;;
;;   (wyve-load "examples/saxpy.wyv")
;;   (ask)                                  ; full conversation
;;   (ask #:without-noalias '("x" "y"))     ; retract a contract, ask again
;;   (ask #:without-noalias '("x" "y") #:force #t)  ; overrule wyvec, send anyway
;;   (run)                                  ; execute on LLVM
(require racket/match racket/string racket/file
         "ast.rkt" "lexer.rkt" "parser.rkt" "sema.rkt" "codegen.rkt"
         "diag.rkt" "talk.rkt" "runner.rkt" "cli.rkt" "rewrite.rkt" "tune.rkt")
(provide wyve-load ask run tune)

(define current-state (box #f)) ; (vector mod file)

(define (wyve-load path)
  (define src (file->string path))
  (with-handlers ([diag? (λ (d) (eprintf "~a" (diag-render d path)) (void))])
    (define mod (parse (lex src)))
    (set-box! current-state (vector mod path))
    (define-values (kernels diags) (check mod))
    (if (pair? diags)
        (begin
          (for ([d (in-list diags)]) (eprintf "~a" (diag-render d path)))
          (printf "wyvec: loaded with refusals — fix the contracts or argue with #:force\n"))
        (printf "wyvec: ~a kernel(s), contracts verified — (ask) to talk to LLVM\n"
                (length kernels)))))

(define (need-state!)
  (or (unbox current-state)
      (error 'wyve "no module loaded — (wyve-load \"file.wyv\") first")))

(define (ask #:without-noalias [without '()] #:force [force? #f]
             #:width [width #f] #:interleave [interleave #f])
  (define st (need-state!))
  (define mod0 (vector-ref st 0))
  (define file (vector-ref st 1))
  (define mod1 (if (null? without) mod0 (strip-noalias-mod mod0 without)))
  (define mod (if (or width interleave) (override-vectorize-mod mod1 width interleave) mod1))
  (unless (null? without)
    (printf "you : (retracting @noalias from: ~a)\n" (string-join without ", "))
    (flush-output))
  (when (or width interleave)
    (printf "you : (turning knobs:~a~a)\n"
            (if width (format " width→~a" width) "")
            (if interleave (format " interleave→~a" interleave) ""))
    (flush-output))
  (define-values (kernels diags) (check mod))
  (cond
    [(and (pair? diags) (not force?))
     (for ([d (in-list diags)]) (eprintf "~a" (diag-render d file)))
     (printf "wyvec: refused — it will not relay an unproven claim to LLVM (override with #:force #t)\n")
     #f]
    [else
     (define ks (if (pair? diags) (pair-kernels mod) kernels))
     (when (pair? diags)
       (for ([d (in-list diags)]) (eprintf "~a" (diag-render d file)))
       (printf "wyvec: objection noted — sending anyway (#:force). LLVM now decides alone:\n")
       (flush-output))
     (talk-to-llvm ks (emit-module file ks) #:verified? (null? diags))]))

(define (run)
  (define st (need-state!))
  (define mod (vector-ref st 0))
  (define file (vector-ref st 1))
  (define-values (kernels diags) (check mod))
  (cond
    [(pair? diags)
     (for ([d (in-list diags)]) (eprintf "~a" (diag-render d file)))
     #f]
    [else
     (run-kernels kernels (emit-module file kernels))]))

;; sweep the schedule space and report the winner
(define (tune #:n [n 2048] #:widths [widths '(4 8 16)] #:interleaves [ils '(1 2 4 8)])
  (define st (need-state!))
  (tune-module (vector-ref st 0) (vector-ref st 1)
               #:n n #:widths widths #:interleaves ils))
