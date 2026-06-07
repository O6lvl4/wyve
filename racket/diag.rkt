#lang racket/base
;; Diagnostics. Same WVN codes and rendering as the Rust reference compiler.
(provide (struct-out diag) diag-render)

(struct diag (code msg line notes) #:transparent)

(define (diag-render d file)
  (apply string-append
         (if (diag-code d)
             (format "error[~a]: ~a\n" (diag-code d) (diag-msg d))
             (format "error: ~a\n" (diag-msg d)))
         (format "  --> ~a:~a\n" file (diag-line d))
         (for/list ([n (in-list (diag-notes d))])
           (format "note: ~a\n" n))))
