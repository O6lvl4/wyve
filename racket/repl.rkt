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
         "diag.rkt" "talk.rkt" "runner.rkt" "cli.rkt")
(provide wyve-load ask run)

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

(define (strip-noalias-mod mod names)
  (define (fix-param p)
    (if (and p (member (Param-name p) names))
        (struct-copy Param p [noalias? #f])
        p))
  (define (fix-sig s)
    (struct-copy Sig s
                 [parts (for/list ([sp (in-list (Sig-parts s))])
                          (struct-copy SelPart sp [param (fix-param (SelPart-param sp))]))]))
  (struct-copy Module mod
               [interfaces (for/list ([i (in-list (Module-interfaces mod))])
                             (struct-copy Iface i [methods (map fix-sig (Iface-methods i))]))]
               [impls (for/list ([im (in-list (Module-impls mod))])
                        (struct-copy Impl im
                                     [methods (for/list ([d (in-list (Impl-methods im))])
                                                (struct-copy MethodDef d [sig (fix-sig (MethodDef-sig d))]))]))]))

(define (override-vectorize-mod mod width interleave)
  (define (fix-sig s)
    (define c (Sig-contracts s))
    (define v (Contracts-vectorize c))
    (if v
        (struct-copy Sig s
                     [contracts (struct-copy Contracts c
                                             [vectorize (struct-copy Vectorize v
                                                                     [width (or width (Vectorize-width v))]
                                                                     [interleave (or interleave (Vectorize-interleave v))])])])
        s))
  (struct-copy Module mod
               [interfaces (for/list ([i (in-list (Module-interfaces mod))])
                             (struct-copy Iface i [methods (map fix-sig (Iface-methods i))]))]
               [impls (for/list ([im (in-list (Module-impls mod))])
                        (struct-copy Impl im
                                     [methods (for/list ([d (in-list (Impl-methods im))])
                                                (struct-copy MethodDef d [sig (fix-sig (MethodDef-sig d))]))]))]))

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
