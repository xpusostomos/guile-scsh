;;; editor-textline-test.scm -- the unstructured text editor.
;;;
;;;   make -C test-suite textline
;;;
;;; The editor is a pure loop (editor/textline.scm): keys come from a list,
;;; the display is a stub, and there is no terminal at all.  A committed line
;;; is pure Scheme, read and committed.

(use-modules (ice-9 receive) (srfi srfi-1))
(use-modules (editor engine) (editor render) (editor history) (editor textline)
             (editor scsh))

(define failures '())

(define (check label expect got)
  (if (equal? expect got)
      (display (string-append "ok   " label "\n"))
      (begin (set! failures (cons label failures))
             (display (string-append "FAIL " label "\n  expect "))
             (write expect) (newline)
             (display "  got    ") (write got) (newline))))

;;; a session: KEYS over a line that starts as INITIAL, with a clean history
;;; built from TREES.  Nothing is drawn.
(define (session keys initial . trees)
  (history-file #f)
  (history-clear!)
  (for-each history-add! trees)
  (text-loop (lambda ()
               (let ((k (if (pair? keys) (car keys) 'enter)))
                 (when (pair? keys) (set! keys (cdr keys)))
                 k))
             (lambda (buf pt) #f)
             initial))

;;; ---- typing, movement, deletion ----------------------------------------------

(receive (text a) (session (string->list "ls -l") "")
  (check "typing builds the line"          "ls -l" text)
  (check "and enter commits"               'evaluate a))

(receive (text a) (session (append (string->list "ls l") (list 'backspace #\- #\l)) "")
  (check "backspace takes a character out" "ls -l" text))

(receive (text a) (session (append (string->list "abc") (list 'home) (string->list "x")) "")
  (check "home and type puts it first"     "xabc" text))

(receive (text a) (session (append (string->list "abc") (list 'left 'left) (string->list "X")) "")
  (check "left moves and inserts there"    "aXbc" text))

(receive (text a) (session (append (string->list "ab") (list 'end) (string->list "c")) "")
  (check "end jumps to the line's end"     "abc" text))

(receive (text a) (session (list 'eof) "")
  (check "C-d on an empty line ends the shell" 'exit a))

(receive (text a) (session (list 'delete) "")
  (check "Del on an empty line does nothing" "" text))

(receive (text a) (session (append (string->list "abx") (list 'left 'delete)) "")
  (check "Del deletes at the point"        "ab" text))

(receive (text a) (session (list 'interrupt) "")
  (check "C-c aborts the line"             'interrupt a))

(receive (text a) (session (append (string->list "ls") (list 'escape)) "")
  (check "ESC hands the line to the structure editor" 'structured a)
  (check "with the text so far"                       "ls" text))

;;; ---- a committed line is pure Scheme -----------------------------------------
;;; The line is read as Scheme and committed, nothing more.  The checks read
;;; the committed tree back with tree->sexp, unwrapping the comma a bare
;;; value line rides on.  Shell commands are typed the scsh way: (run ...).

(check "a run form is the shell"
       '(run (ls -l)) (tree->sexp (text-commit-tree "(run (ls -l))")))

(check "a bare word is the value it names -- car, not a command"
       'car (line-datum (tree->sexp (text-commit-tree "car"))))

(check "a bare number names itself"
       5 (line-datum (tree->sexp (text-commit-tree "5"))))

(check "a comma line is Scheme with the marker riding in the tree"
       'x (line-datum (tree->sexp (text-commit-tree ",x"))))

(check "a define defines"
       '(define x 42) (tree->sexp (text-commit-tree "(define x 42)")))

(check "a quoted list reads through the reader"
       '(car (quote (1 2))) (tree->sexp (text-commit-tree "(car '(1 2))")))

(check "a comment line says nothing"
       '() (text-commit-tree "; nothing here"))

(check "more than one form on a line is refused, not guessed at"
       '() (text-commit-tree "1 2"))

(check "a line that does not read commits nothing"
       '() (text-commit-tree "(begin (dis"))

(check "the crossing closes a half-built form so the work survives"
       '(begin (dis)) (tree->sexp (text-carry-tree "(begin (dis")))

;;; ---- history recall shares the shell's history -------------------------------

(receive (text a)
    (session (append (string->list "zzz") (list 'up)) ""
             (sexp->tree '(run (echo hi)))
             (sexp->tree '(run (ls))))
  (check "UP recalls the newest item"      "(run (ls))" text))

(receive (text a)
    (session (append (string->list "zzz") (list 'up 'up)) ""
             (sexp->tree '(run (echo hi)))
             (sexp->tree '(run (ls))))
  (check "UP UP walks back through the items" "(run (echo hi))" text))

(receive (text a)
    (session (append (string->list "zzz") (list 'up 'up 'down)) ""
             (sexp->tree '(run (echo hi)))
             (sexp->tree '(run (ls))))
  (check "DOWN comes forward again"        "(run (ls))" text))

(receive (text a)
    (session (append (string->list "zzz") (list 'up 'up 'down 'down)) ""
             (sexp->tree '(run (echo hi)))
             (sexp->tree '(run (ls))))
  (check "DOWN past the newest returns the draft" "zzz" text))

(receive (text a)
    (session (append (string->list "zzz") (list 'up 'up 'up)) ""
             (sexp->tree '(run (echo hi))))
  (check "UP at the oldest item stays put" "(run (echo hi))" text))

;;; ---- verdict -----------------------------------------------------------------

(unless (null? failures)
  (for-each (lambda (f) (display (string-append "FAILED: " f "\n"))) (reverse failures))
  (exit 1))
(display "all textline checks pass\n")
(check "a bare word crosses as the value line it is"
       '("," "car") (text-carry-tree "car"))
