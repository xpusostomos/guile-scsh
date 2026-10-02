;;; scheme-shell-test.scm -- sandbox-proof test for the structured scsh editor.
;;;
;;; Loads the real editor (examples/readline-editor.scm) but replaces the
;;; readline/FFI layer with a pure in-memory model (a (buffer . point) pair),
;;; then drives keystrokes through the ACTUAL rule callbacks and checks the
;;; buffer at every step.  No tty, no readline, no processes -- run anywhere:
;;;
;;;   (from the repo root)  make -C test-suite editor   -- or --
;;;   env SCSH_EDITOR_NO_LOOP=1 GUILE_AUTO_COMPILE=0 guile -q -L . test-suite/scheme-shell-test.scm
;;;
;;; Exits non-zero if any assertion fails.

;;; ---- load the real editor (definitions only, no REPL loop) ---------------

(load (string-append (or (getenv "SCHI_REPO") (getcwd)) "/examples/readline-editor.scm"))

;;; ---- pure model stands in for readline's buffer/point --------------------

(define *st*    (cons "" 0))      ; buffer . point
(define *dings* 0)

(define (buffer-text)  (car *st*))
(define (point)        (cdr *st*))
(define (set-point! w) (set! *st* (cons (car *st*) w)))
(define (replace-line! t w) (set! *st* (cons t w)))

(define (rl-insert-text s)       ; note: call-with-cstr stub passes the STRING
  (let ((b (car *st*)) (p (cdr *st*)))
    (set! *st* (cons (string-replace b s p p) (+ p (string-length s))))))
(define (call-with-cstr s thunk) (thunk s))
(define (rl-redisplay) #f)
(define (rl-ding) (set! *dings* (1+ *dings*)))
(define (log! . stuff) #f)

;;; ---- keystroke driver ----------------------------------------------------

(define (type-key k)
  (cond ((= k 40)  (loparen-cb 1 k))
        ((= k 41)  (rpare-cb 1 k))
        ((= k 62)  (redir-cb 1 k))
        ((= k 124) (pipe-cb 1 k))
        ((= k 127) (bspace-cb 1 k))
        (else      (smart-insert-cb 1 k))))

(define (type str)
  (let ((n (string-length str)))
    (let lp ((i 0))
      (when (< i n)
        (type-key (char->integer (string-ref str i)))
        (lp (1+ i))))))

(define (reset!)
  (set! *st* (cons "" 0))
  (set! *dings* 0))

;;; ---- tiny assertion harness ----------------------------------------------

(define failures '())
(define (check label expect got)
  (if (equal? expect got)
      (display (string-append "ok     " label))
      (begin
        (set! failures (cons label failures))
        (display (string-append "FAIL   " label "   expect="))
        (write expect)
        (display " got=")
        (write got)
        (newline))))

(define (check-buffer label buf)
  (check label buf (buffer-text)))

;;; ---- the canonical session:  ls -l | wc ----------------------------------

(reset!)
(type "l")
(check-buffer "after 'l'  wrap"            "(run (l))")
(type "s -l")
(check-buffer "after 'ls -l'"              "(run (ls -l))")
(type "|")
(check "(point inside slot after '|')"     17 (point))
(check-buffer "after '|'  pipe struct"     "(run (| (ls -l) ()))")
(type "wc")
(check-buffer "after 'wc' in slot"         "(run (| (ls -l) (wc)))")
(let ((g (guess-line (buffer-text))))
  (check "Enter: template passes through" (cons #f '(run (| (ls -l) (wc))))
         (and g (cons (car g) (cdr g)))))

;;; ---- the ( -rule: ls -l ( wc )  (no arrow keys) --------------------------

(reset!)
(type "ls -l(wc)")
(check-buffer "loparen: (run (ls -l) (wc))" "(run (ls -l) (wc))")

;;; ---- redirection rule -----------------------------------------------------

(reset!)
(type "ls>f")
(check-buffer "redir: (run (ls) (> f))"    "(run (ls) (> f))")

;;; ---- backspace deletes inside slots, never brackets ----------------------

(reset!)
(type "lss")
(type-key 127)
(check-buffer "backspace drops one char"    "(run (ls))")

;;; ---- spare ) is refused ------------------------------------- ------------

(reset!)
(type "ls")
(type-key 41)
(check-buffer "spare ) leaves buffer"       "(run (ls))")
(check "spare ) dings" 1 *dings*)

;;; ---- Enter repairs mangled / raw lines -----------------------------------

(reset!)
(set! *st* (cons "(run (ls -l))(wc))" 0))
(let ((g (guess-line (buffer-text))))
  (check "mangled template repaired"
         (list #t '(run ("ls" "-l" "wc")))
         (and g (list (car g) (cdr g)))))

(reset!)
(set! *st* (cons "echo a | wc -c" 0))
(let ((g (guess-line (buffer-text))))
  (check "raw shell pipe -> scsh"
         (list #t '(run (| ("echo" "a") ("wc" "-c"))))
         (and g (list (car g) (cdr g)))))

;;; ---- literal fallbacks: assist, never block ---------------------------------

(reset!)
(type "ls")                           ; (run (ls)), point after ls inside the slot
(type "(")                            ; assisted: open a second command
(check-buffer "assisted ( slot"       "(run (ls) ())")
(type "wc")                           ; fill it
(check-buffer "assisted (run (ls) (wc))" "(run (ls) (wc))")
(set-point! 8)                        ; arrow back INTO the line
(type "|")                            ; now | is literal, not captured
(check-buffer "| literal mid-edit"    "(run (ls|) (wc))")

(reset!)
(type "ls")
(set-point! 0)                        ; arrow home
(type "(")                            ; literal, not a new slot
(check-buffer "( pairs at point 0"   "()(run (ls))")

(reset!)
(type "ls")
(set-point! 6)                        ; point on the ( of the command
(type-key 127)                        ; backspace deletes a bracket now
(check-buffer "backspace removes bracket" "(run ls))")

;;; ---- close-preserving repair (the user's |>| transcript) -------------------

(reset!)
(type "ls|wc")                        ; assisted pipeline -> (run (| (ls) (wc)))
(set-point! (string-length (buffer-text)))
(type-key 127)                        ; backspace: drop the final ) -- now unbalanced
(check-buffer "user's exact unbalanced buffer" "(run (| (ls) (wc))")
(let ((g (guess-line (buffer-text))))
  (check "close-preserving repair keeps the pipe"
         (cons #t '(run (| (ls) (wc))))
         (and g (cons (car g) (cdr g)))))

(reset!)
(set! *st* (cons "(run (ls) (wc)))" 0))
(let ((g (guess-line (buffer-text))))
  (check "stray closer dropped, structure kept"
         (cons #t '(run (ls) (wc)))
         (and g (cons (car g) (cdr g)))))

;;; ---- TAB: rebalance machinery ---------------------------------------------

(define (bal buf) (- (string-count buf #\() (string-count buf #\))))

(reset!)
(set! *st* (cons "(run (ls) (wc)))" 16))      ; one stray close
(tab-rebalance-cb 1 9)
(check-buffer "TAB repairs stray close"  "(run (ls) (wc))")
(check "TAB repair is balanced" 0 (bal (buffer-text)))

(reset!)
(set! *st* (cons "(run (| (ls) (wc))" 17))    ; one missing close
(tab-rebalance-cb 1 9)
(check-buffer "TAB closes missing paren" "(run (| (ls) (wc)))")
(check "TAB close-up is balanced" 0 (bal (buffer-text)))

; cursor in the pipeline -- Tab makes SOME balanced move
(reset!)
(set! *st* (cons "(run (| (ls) (wc)))" 18))
(tab-rebalance-cb 1 9)
(check "TAB in pipe stays balanced" 0 (bal (buffer-text)))

; tab never leaves the line unbalanced, whatever it does
(reset!)
(set! *st* (cons "(run (| (ls) (wc)))" 5))
(tab-rebalance-cb 1 9)
(check "TAB from cursor-in-pipe stays balanced" 0 (bal (buffer-text)))

;;; ---- verdict --------------------------------------------------------------

(newline)
(if (null? failures)
    (begin (display "ALL CHECKS PASSED") (newline) (exit 0))
    (begin (display "FAILURES: ") (write failures) (newline) (exit 1)))
