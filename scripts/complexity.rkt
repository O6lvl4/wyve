#lang racket/base
;; A tiny complexity report for Wyve's Racket sources. For each top-level
;; `define`, reports: SIZE (cons cells — overall heft), DEPTH (max nesting of
;; branching/binding forms — how hard to follow), BRANCHES (cond/match/case
;; clauses — decision points, ~ cyclomatic complexity). Usage:
;;   racket scripts/complexity.rkt racket/*.rkt
(require racket/list racket/string)

(define (pad s w) (let ([t (format "~a" s)]) (if (>= (string-length t) w) t (string-append t (make-string (- w (string-length t)) #\space)))))

(define branching '(cond match case if when unless for for/list for/fold
                    for*/list let let* let-values letrec λ lambda
                    match-define struct-copy parameterize))

;; car/cdr recursion so dotted lambda lists (define (f . args) …) are safe
(define (size e) (if (pair? e) (+ 1 (size (car e)) (size (cdr e))) 1))

(define (depth e)
  (if (pair? e)
      (let ([here (if (and (symbol? (car e)) (memq (car e) branching)) 1 0)])
        (+ here (max (depth (car e)) (depth (cdr e)))))
      0))

(define (branches e)
  (if (pair? e)
      (+ (if (and (symbol? (car e)) (memq (car e) '(cond match case)) (list? (cdr e)))
             (length (filter pair? (cdr e)))
             0)
         (branches (car e)) (branches (cdr e)))
      0))

(define (defn-name f)
  (define head (cadr f))
  (cond [(pair? head) (let loop ([h head]) (if (pair? h) (loop (car h)) h))]
        [else head]))

(define (read-forms file)
  ;; skip the #lang line, then read s-expressions
  (call-with-input-file file
    (λ (in)
      (read-line in)                 ; #lang …
      (let loop ([acc '()])
        (define f (read in))
        (if (eof-object? f) (reverse acc) (loop (cons f acc)))))))

(define rows '())
(for ([file (in-vector (current-command-line-arguments))])
  (for ([f (in-list (read-forms file))]
        #:when (and (pair? f) (memq (car f) '(define define-values))
                    (pair? (cadr f))))
    (set! rows (cons (list (defn-name f) (size f) (depth f) (branches f)
                           (let-values ([(_ name __) (split-path file)]) (path->string name)))
                     rows))))

(define sorted (sort rows > #:key cadr))   ; by size, biggest first
(printf "~a  ~a ~a ~a   ~a\n" (pad "FUNCTION" 30) (pad "SIZE" 6) (pad "DEPTH" 6) (pad "BRANCH" 7) "FILE")
(for ([r (in-list (take sorted (min 25 (length sorted))))])
  (printf "~a  ~a ~a ~a   ~a\n"
          (pad (car r) 30) (pad (cadr r) 6) (pad (caddr r) 6) (pad (cadddr r) 7) (list-ref r 4)))
