#lang racket/base
;; `#lang wyve` — a .wyv file IS a Racket program whose surface syntax is
;; Objective-C. Running it verifies the contracts, converses with LLVM's
;; optimizer, and executes the kernels.
(require racket/port)
(provide (rename-out [wyve-read read]
                     [wyve-read-syntax read-syntax]))

(define (wyve-read in)
  (syntax->datum (wyve-read-syntax #f in)))

(define (wyve-read-syntax src in)
  (define text (port->string in))
  (define name (if (path? src) (path->string src) (format "~a" src)))
  (datum->syntax
   #f
   `(module wyve-program racket/base
      (require wyve/cli)
      (run-source ,text ,name))))
