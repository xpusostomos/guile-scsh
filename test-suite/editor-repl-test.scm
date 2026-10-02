;;; editor-repl-test.scm -- the structural REPL loop, driven by scripted keys.
;;;
;;; No terminal is involved: the key "reader" is a list of keys, and the "draw"
;;; function records the frames.  So the whole loop -- dispatch, edit, render,
;;; redisplay, commit -- is machine-checked.
;;;
;;;   make -C test-suite engine

(use-modules (ice-9 receive) (ice-9 optargs) (srfi srfi-1))
(use-modules (editor engine) (editor render) (editor repl) (editor scsh))

(define failures '())
(define (check label expect got)
  (if (equal? expect got)
      (display (string-append "ok   " label "\n"))
      (begin (set! failures (cons label failures))
             (display (string-append "FAIL " label "\n  expect "))
             (write expect) (newline)
             (display "  got    ") (write got) (newline))))

(define (last lst) (car (reverse lst)))

(define (parses? s)
  (catch #t (lambda () (read (open-input-string s)) #t) (lambda args #f)))

;;; ---- the harness: a session is a list of keys -------------------------------

(define (start)          (sexp->tree '(run ())))       ; the shell's initial document
(define (inside-first)   (make-locus '(1) 0 0))        ; inside the empty command form

;;; (session KEYS TREE LOCUS) -> (values tree locus reason frames)
(define* (session keys tree locus #:key (seed #f) (rules #f))
  (let ((drawn '()))
    (receive (t l reason)
        (run-loop (lambda () (let ((k (car keys))) (set! keys (cdr keys)) k))
                  (lambda (text col row bold) (set! drawn (cons (list text col bold row) drawn)))
                  tree locus #:seed seed #:rules rules)
      (values t l reason (reverse drawn)))))

;;; ---- a whole line, keystroke by keystroke -----------------------------------

(receive (t l reason frames) (session (list #\l #\s 'enter) (start) (inside-first))
  (check "session: typing ls"            "(run (ls))"  (render-tree t))
  (check "session: Enter commits"        'evaluate     reason)
  (check "session: a frame per key, plus the line" 4 (length frames))
  (check "session: the last frame is the line" "(run (ls))" (car (last frames))))

;;; ---- words: SPC separates them ----------------------------------------------

(receive (t l reason frames) (session (list #\l #\s #\space #\- #\l 'enter) (start) (inside-first))
  (check "session: type  ls -l"    "(run (ls -l))" (render-tree t))
  (check "session: and it commits" 'evaluate reason)
  (check "session: every frame parses" #t (every (lambda (f) (parses? (car f))) frames)))

;;; ---- a fresh shell line: empty until you type, then (run ...) ----------------

(receive (t l reason frames)
    (session (list #\l #\s 'enter) '() (make-locus '() 0 0)
             #:seed seed)
  (check "seeded session: the first frame is an empty line" "" (car (car frames)))
  (check "seeded session: the first word opens (run ...)"  "(run (ls))" (render-tree t))
  (check "seeded session: and Enter commits"               'evaluate reason))

;;; ---- movement, then typing at the locus -------------------------------------

(receive (t l reason frames) (session (list #\l 'left #\X 'enter) (start) (inside-first))
  (check "session: LEFT then type inserts before" "(run (Xl))" (render-tree t)))

(receive (t l reason frames) (session (list #\l 'right 'right #\X 'enter) (start) (inside-first))
  (check "session: RIGHT steps out of the form, then a new symbol"
         "(run (l) X)" (render-tree t)))

;;; ---- Tab regroups ------------------------------------------------------------

(receive (t l reason frames) (session (list #\l 'tab 'enter) (start) (inside-first))
  ;; ("run" ("l"))  -- Tab -->  ("run" () "l"): the same text otherwise, but a
  ;; different grouping -- which is exactly why the tree, not the text, is truth
  (check "session: Tab regroups" "(run () l)" (render-tree t)))

;;; Tab keeps the cursor where it was, so pressing it again cycles the two
;;; groupings rather than wandering off into a different form
(receive (t l reason frames)
    (session (list #\l #\s 'tab 'enter) (start) (inside-first))
  (check "session: Tab barfs the word out" "(run () ls)" (render-tree t))
  (check "session: leaving the cursor in the form it acted on" '((1) 0 0) l))

(receive (t l reason frames)
    (session (list #\l #\s 'tab 'tab 'enter) (start) (inside-first))
  (check "session: and Tab again slurps it back" "(run (ls))" (render-tree t)))

;;; ---- forms: ( opens one, ) leaves it -----------------------------------------

;; up/down are history now: the same shape is reached by stepping out with LEFT
(receive (t l reason frames)
    (session (list #\l #\s 'left 'left 'left #\( 'enter) (start) (inside-first))
  (check "session: left out of the form, then ( beside it" "(run () (ls))" (render-tree t)))

;;; ---- operators do not fire where the user is building a form -----------------

(receive (t l reason frames)
    (session (list #\l #\s 'left 'left #\| 'enter) (start) (inside-first))
  (check "session: | at the form start is literal" "(run (|ls))" (render-tree t)))

;;; ---- a line may be plain Scheme ----------------------------------------------

(receive (t l reason frames)
    (session (list #\( #\d #\i #\s #\p #\l #\a #\y #\space #\h 'enter)
             '() (make-locus '() 0 0) #:seed seed)
  (check "a line may be plain Scheme"    "(display h)" (render-tree t))
  (check "and it is not a shell command" '(display h)  (tree->sexp t))
  (check "it commits"                    'evaluate     reason))

(receive (t l reason frames)
    (session (list #\) 'enter) '() (make-locus '() 0 0) #:seed seed)
  (check "a leading ) is swallowed" "" (render-tree t)))

;;; ---- a quoted form typed naturally --------------------------------------------

(receive (t l reason frames)
    (session (list #\( #\c #\a #\r #\space #\' #\( #\1 #\) #\) 'enter)
             '() (make-locus '() 0 0) #:seed seed)
  (check "the quote stays in front of the form" "(car '(1))" (render-tree t))
  (check "and reads as a quote form"            '(car (quote (1))) (tree->sexp t)))

;;; ---- a space before "(" leaves no stray word --------------------------------

(receive (t l reason frames)
    (session (list #\( #\& #\space #\( #\w #\c #\) #\) 'enter)
             '() (make-locus '() 0 0) #:seed seed)
  (check "typing  (& (wc))  gives (& (wc))" "(& (wc))" (render-tree t))
  (check "and no stray empty word"           '(& (wc))  (tree->sexp t)))

;;; ---- backspace walks back out of the seeded form ------------------------------
;;; Type "l", then backspace until the line is empty.  Every frame must parse --
;;; half-deleted structure is never on screen.

(receive (t l reason frames)
    (session (list #\l 'backspace 'backspace 'backspace 'enter)
             '() (make-locus '() 0 0) #:seed seed)
  (check "backspace: the line ends up empty" "" (render-tree t))
  (check "backspace: the document is empty"  '() (tree->sexp t))
  (check "backspace: every frame parsed"
         #t (every (lambda (f) (parses? (car f))) frames))
  ;; the first frame is the seeded empty line; then one per key
  (check "backspace: the frames walk out of the form"
         (list "(run (l))" "(run ())" "(run)" "")
         (list-head (cdr (map car frames)) 4)))

;;; the same on a line you built yourself, without the seed
(receive (t l reason frames)
    (session (list #\l #\s #\space #\- #\l 'backspace 'backspace 'backspace
                   'backspace 'backspace 'backspace 'backspace 'backspace 'enter)
             (start) (inside-first))
  (check "backspace: a hand-built line unwinds too" "" (render-tree t)))

;;; ---- a "(" typed on a fresh line can be taken back ----------------------------
;;; Typing "(" leaves a form with an empty word in it (a placeholder for the
;;; cursor), which renders as "()" -- and before that could be deleted the line
;;; was stuck like that forever.

(receive (t l reason frames)
    (session (list #\( 'backspace 'backspace 'enter) '() (make-locus '() 0 0) #:seed seed)
  (check "a typed ( renders as ()"    "()" (cadr (map car frames)))
  (check "backspace empties the line" ""   (render-tree t))
  (check "the document is empty"      '()  (tree->sexp t))
  (check "and every frame parsed"
         #t (every (lambda (f) (parses? (car f))) frames)))

;;; ---- between two elements, backspace is not a dead key -----------------------

(receive (t l reason frames)
    (session (list #\l #\s 'left 'left 'left 'backspace 'enter) (start) (inside-first))
  ;; ... "left" three times puts the locus between "run" and the form
  (check "backspace between elements takes the character on its left"
         "(ru (ls))" (render-tree t)))

;;; ---- bold: the form the cursor is in, frame by frame --------------------------
;;; The styling is part of what is drawn, so the loop carries it: the terminal
;;; turns the spans into escape sequences and these checks read them as data.

(define (bold-texts frame)
  (let ((text (car frame)))
    (map (lambda (s) (substring text (car s) (cdr s))) (caddr frame))))

(receive (t l reason frames) (session (list #\l #\s 'enter) (start) (inside-first))
  (check "bold: the form you are typing in has its parens marked"
         '("(" ")") (bold-texts (last frames))))
;; ... and while the line is still empty there is nothing to bold
(receive (t l reason frames)
    (session (list 'enter) '() (make-locus '() 0 0) #:seed seed)
  (check "bold: an empty line has none" '() (bold-texts (car frames))))

(receive (t l reason frames)
    (session (list #\, #\x 'enter) '() (make-locus '() 0 0) #:seed seed)
  (check "bold: a comma line has no parens to mark"
         '() (bold-texts (last frames))))

;;; ---- ; : a second toplevel ----------------------------------------------------
;;; ls ; ls -- the first line wrapped in begin, the second typed at the begin's
;;; toplevel exactly as at the prompt

(receive (t l reason frames)
    (session (list #\l #\s #\; #\l #\s 'enter) '() (make-locus '() 0 0)
             #:seed seed #:rules (append shell-rules core-rules))
  (check ";: begin wraps the first line"  "(begin (run (ls)) (run (ls)))" (render-tree t))
  (check ";: and reads as a begin of two" '(begin (run (ls)) (run (ls))) (tree->sexp t))
  (check ";: every frame parsed" #t (every (lambda (f) (parses? (car f))) frames)))

;; ; at the very start, then ( -- a scheme form opened BEFORE the old line.
;; Seven lefts carry the cursor from inside the command form to the line's (.
(receive (t l reason frames)
    (session (append (list #\l #\s) (make-list 7 'left) (list #\; #\( #\d 'enter))
                     '() (make-locus '() 0 0)
                     #:seed seed #:rules (append shell-rules core-rules))
  (check "; at start then (: a form before the old one"
         "(begin (d) (run (ls)))" (render-tree t)))

;;; ---- exit, and keys we do not know -------------------------------------------

(receive (t l reason frames) (session (list 'eof) (start) (inside-first))
  (check "session: EOF exits" 'exit reason))

(receive (t l a) (dispatch-key (start) (inside-first) 'frobnicate)
  (check "unknown key is ignored" 'continue a)
  (check "unknown key leaves the tree alone" "(run ())" (render-tree t)))

;;; ---- the property that matters: every frame was a well-formed datum ----------

(receive (t l reason frames)
    (session (list #\l #\s #\( 'tab #\) 'right #\X 'enter) (start) (inside-first))
  (check "every frame along the way parses"
         #t (every (lambda (f) (parses? (car f))) frames))
  (check "and so does the committed line" #t (parses? (render-tree t))))

;;; ---- M-RET: a line becomes a block -------------------------------------------

(receive (t l reason frames)
    (session (list #\l #\s 'm-return 'enter) (start) (inside-first))
  ;; the cursor was at the end of "ls": the break goes after it, the command
  ;; form stays open on the new line
  (check "M-RET: two lines" "(run (ls\n         ))" (render-tree t))
  (check "M-RET: the cursor is on the new line" 9 (cadr (last frames)))
  (check "M-RET: enter after it evaluates" 'evaluate reason))

;; backspace joins the lines again
(receive (t l reason frames)
    (session (list #\l #\s 'm-return 'backspace 'enter) (start) (inside-first))
  (check "M-RET then backspace: one line again" "(run (ls))" (render-tree t)))

;;; ---- verdict ----------------------------------------------------------------

(newline)
(if (null? failures)
    (begin (display "ALL CHECKS PASSED") (newline) (exit 0))
    (begin (display "FAILURES: ") (write failures) (newline) (exit 1)))
