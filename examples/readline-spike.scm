#!/usr/bin/guile --no-auto-compile
!#
(use-modules (system foreign) (ice-9 regex) (srfi srfi-13) (rnrs bytevectors))

(define lib (dynamic-link "libreadline"))

(define C-readline      (pointer->procedure '* (dynamic-func "readline" lib) (list '*)))
(define rl-bind-key     (pointer->procedure int  (dynamic-func "rl_bind_key" lib) (list int '*)))
(define rl-insert-text  (pointer->procedure int  (dynamic-func "rl_insert_text" lib) (list '*)))
(define rl-replace-line (pointer->procedure void (dynamic-func "rl_replace_line" lib) (list '* int)))
(define rl-redisplay    (pointer->procedure void (dynamic-func "rl_redisplay" lib) '()))
(define rl-ding         (pointer->procedure void (dynamic-func "rl_ding" lib) '()))
(define rl-line-buffer-ptr (dynamic-pointer "rl_line_buffer" lib))

(define (buffer-text)
  (pointer->string (dereference-pointer rl-line-buffer-ptr)))

(define (call-with-cstr s thunk)
  (let ((bv (string->utf8 s)))
    (thunk (bytevector->pointer bv))))

(define rl-point-bv (pointer->bytevector (dynamic-pointer "rl_point" lib) 4 0))

(define (set-point! where)
  ;; If pointer->bytevector is a LIVE view (as read-c-struct implies),
  ;; this writes through to readline's rl_point.  The demo output tells us.
  (bytevector-u32-native-set! rl-point-bv 0 where))

(define (replace-line! text where)
  (call-with-cstr text (lambda (p) (rl-replace-line p 1)))
  (set-point! where)
  (rl-redisplay))

;; @ key: probes rl-replace-line: buffer -> HELLO with point at 2
(define (at-cb count key)
  (catch #t
    (lambda ()
      (replace-line! "HELLO" 2)
      (display (string-append "[@ buffer now: '" (buffer-text) "' len "
                               (number->string (string-length (buffer-text)))))
      (newline))
    (lambda (k . a)
      (display "[@ ERR: ") (display k) (display " ") (display a)
      (display "]") (newline)))
  0)

;; | rule: only plays with the exact demo buffer
(define (pipe-cb count key)
  (catch #t
    (lambda ()
      (let ((buf (buffer-text)))
        (if (string=? buf "(run (ls -l))")
            (let ((new "(run (| (ls -l) ()))"))
              (display (string-append "[| rewrite: " new " point at "
                                       (number->string (- (string-length new) 2))))
              (newline)
              (replace-line! new (- (string-length new) 3))
              (display (string-append "[| buffer now: '" (buffer-text) "'"))
              (newline))
            (begin
              (display (string-append "[| refuse buf='" buf "']"))
              (newline)
              (rl-ding)))))
    (lambda (k . a)
      (display "[| ERR: ") (display k) (display " ") (display a)
      (display "]") (newline)))
  0)

;; ) rule: never let the buffer have more closes than opens
(define (rpare-cb count key)
  (catch #t
    (lambda ()
      (let ((buf (buffer-text)))
        (if (negative? (- (string-count buf #\() (string-count buf #\))))
            (begin
              (display (string-append "[) refuse buf='" buf "']"))
              (newline)
              (rl-ding))
            (begin
              (call-with-cstr ")" (lambda (p) (rl-insert-text p)))
              (rl-redisplay)))))
    (lambda (k . a)
      (display "[) ERR: ") (display k) (display " ") (display a)
      (display "]") (newline)))
  0)

(define (install! key proc)
  (rl-bind-key key (procedure->pointer int proc (list int int))))

(install! 124 pipe-cb)
(install! 41  rpare-cb)
(install! 64  at-cb)

(display "spike2 ready:  (run (ls -l))  then  |   [@ replaces line]")
(newline)

(let loop ()
  (let ((line (C-readline (bytevector->pointer (string->utf8 "shs> ")))))
    (cond ((null-pointer? line) (quit))
          (else
           (display (string-append "[line: '" (pointer->string line) "']"))
           (newline)
           (loop)))))