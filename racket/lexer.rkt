#lang racket/base
;; Objective-C grammar slice, character-level lexer.
(require "diag.rkt")
(provide lex (struct-out tok))

;; tok types:
;;   'at (val: directive name string)   'ident (string)
;;   'int (exact integer)               'float (double from f32 literal)
;;   'kw (symbol: for return const void float usize)
;;   'plus 'plusplus 'pluseq 'minus 'star 'slash
;;   'lt 'le 'gt 'ge 'eqeq 'ne 'assign
;;   'lparen 'rparen 'lbrace 'rbrace 'lbracket 'rbracket
;;   'semi 'comma 'colon 'eof
(struct tok (type val line) #:transparent)

(define reserved-objc '("in" "out" "inout" "oneway" "bycopy" "byref"))
(define keywords '("for" "return" "const" "void" "float" "usize" "if" "else"))

(define (lex src)
  (define n (string-length src))
  (define toks '())
  (define line 1)
  (define i 0)
  (define (push! type [val #f]) (set! toks (cons (tok type val line) toks)))
  (define (next-is? ch) (and (< (add1 i) n) (char=? (string-ref src (add1 i)) ch)))
  (define (ident-start? c) (or (char-alphabetic? c) (char=? c #\_)))
  (define (ident-char? c) (or (char-alphabetic? c) (char-numeric? c) (char=? c #\_)))
  (define (read-ident!)
    (define start i)
    (let loop ()
      (when (and (< i n) (ident-char? (string-ref src i)))
        (set! i (add1 i))
        (loop)))
    (substring src start i))
  (define (single! type) (push! type) (set! i (add1 i)))
  (define (double! type) (push! type) (set! i (+ i 2)))

  (let loop ()
    (when (< i n)
      (define c (string-ref src i))
      (cond
        [(char=? c #\newline) (set! line (add1 line)) (set! i (add1 i))]
        [(memv c '(#\space #\tab #\return)) (set! i (add1 i))]
        [(and (char=? c #\/) (next-is? #\/))
         (let skip ()
           (when (and (< i n) (not (char=? (string-ref src i) #\newline)))
             (set! i (add1 i))
             (skip)))]
        [(char=? c #\/) (single! 'slash)]
        [(char=? c #\@)
         (set! i (add1 i))
         (define name (read-ident!))
         (when (string=? name "")
           (raise (diag #f "expected directive name after `@`" line '())))
         (push! 'at name)]
        [(ident-start? c)
         (define s (read-ident!))
         (define vecf (regexp-match #px"^float([0-9]+)$" s))
         (cond
           [(member s reserved-objc)
            (raise (diag #f
                         (format "`~a` is reserved by Objective-C's grammar (protocol qualifier)" s)
                         line '()))]
           [vecf (push! 'vecf (string->number (cadr vecf)))]   ; float2/4/8/16
           [(string=? s "shuffle") (push! 'shuffle)]
           [(member s keywords) (push! 'kw (string->symbol s))]
           [else (push! 'ident s)])]
        [(char-numeric? c)
         (define start i)
         (let dig ()
           (when (and (< i n) (char-numeric? (string-ref src i)))
             (set! i (add1 i)) (dig)))
         (define is-float #f)
         (when (and (< i n) (char=? (string-ref src i) #\.))
           (set! is-float #t)
           (set! i (add1 i))
           (let dig ()
             (when (and (< i n) (char-numeric? (string-ref src i)))
               (set! i (add1 i)) (dig))))
         (define text (substring src start i))
         (when (and (< i n) (char=? (string-ref src i) #\f))
           (set! is-float #t)
           (set! i (add1 i)))
         (if is-float
             (push! 'float (exact->inexact (string->number text)))
             (push! 'int (string->number text)))]
        [(char=? c #\+)
         (cond [(next-is? #\+) (double! 'plusplus)]
               [(next-is? #\=) (double! 'pluseq)]
               [else (single! 'plus)])]
        [(char=? c #\-) (single! 'minus)]
        [(char=? c #\*) (single! 'star)]
        [(char=? c #\<) (if (next-is? #\=) (double! 'le) (single! 'lt))]
        [(char=? c #\>) (if (next-is? #\=) (double! 'ge) (single! 'gt))]
        [(char=? c #\=) (if (next-is? #\=) (double! 'eqeq) (single! 'assign))]
        [(char=? c #\!)
         (if (next-is? #\=)
             (double! 'ne)
             (raise (diag #f "unexpected `!`" line '())))]
        [(char=? c #\() (single! 'lparen)]
        [(char=? c #\)) (single! 'rparen)]
        [(char=? c #\{) (single! 'lbrace)]
        [(char=? c #\}) (single! 'rbrace)]
        [(char=? c #\[) (single! 'lbracket)]
        [(char=? c #\]) (single! 'rbracket)]
        [(char=? c #\;) (single! 'semi)]
        [(char=? c #\,) (single! 'comma)]
        [(char=? c #\:) (single! 'colon)]
        [else (raise (diag #f (format "unexpected character `~a`" c) line '()))])
      (loop)))
  (push! 'eof)
  (list->vector (reverse toks)))
