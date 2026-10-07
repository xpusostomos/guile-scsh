;;; editor-textline-test.scm -- the unstructured text editor.
;;;
;;;   guile -q -L . test-suite/editor-textline-test.scm   (from the repo root)
;;;
;;; The editor is a pure loop (structured-scsh/textline.scm): keys come from a list,
;;; the display is a stub, and there is no terminal at all.  A committed line
;;; is pure Scheme, read and committed.

(use-modules (ice-9 receive) (srfi srfi-1))
(use-modules (structured-scsh engine) (structured-scsh render) (structured-scsh history) (structured-scsh textline)
             (structured-scsh scsh) (structured-scsh properties) (structured-scsh complete))

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
(define *frames* '())

(define (session keys initial . trees)
  (history-file #f)
  (history-clear!)
  (for-each history-add! trees)
  (set! *frames* '())
  (text-loop (lambda ()
               (let ((k (if (pair? keys) (car keys) 'enter)))
                 (when (pair? keys) (set! keys (cdr keys)))
                 k))
             (lambda (buf pt) #f)
             initial
             ;; the search frames, oldest first, for the checks below
             #:search-draw (lambda (q m f) (set! *frames* (cons (list q m f) *frames*)))))

;;; the same, with the shell's Tab hook (structured-scsh/complete.scm): what the
;;; candidates hook was told lands in *candidates*, oldest first -- (NAMES LIST?)
;;; -- exactly as in the structure editor's suite
(define *candidates* '())

(define (completing-session keys initial complete)
  (history-file #f)
  (history-clear!)
  (set! *candidates* '())
  (receive (text action)
      (text-loop (lambda ()
                   (let ((k (if (pair? keys) (car keys) 'enter)))
                     (when (pair? keys) (set! keys (cdr keys)))
                     k))
                 (lambda (buf pt) #f)
                 initial
                 #:complete complete
                 #:candidates (lambda (names list?)
                                (set! *candidates* (cons (list names list?) *candidates*))))
    (set! *candidates* (reverse *candidates*))
    (values text action)))

(define Cr (integer->char 18))
(define Cg (integer->char 7))

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

(check "a string literal survives the commit round trip"
       '(display "hi") (tree->sexp (text-commit-tree "(display \"hi\")")))

(check "and it renders with its quotes, so recall shows it as typed"
       #t (and (string-contains (render-tree (text-commit-tree "(display \"hi\")"))
                                "\"hi\"") #t))

(check "a comment line says nothing"
       '() (text-commit-tree "; nothing here"))

;;; ---- the ! escape: a line for the standard shell -----------------------------

(check "a ! line is the marker hugging the verbatim command"
       '("!" "ls -l >f") (text-commit-tree "!ls -l >f"))

(check "the command is never read as Scheme -- pipes and all ride along"
       '("!" "echo a | tr a b >out") (text-commit-tree "!echo a | tr a b >out"))

(check "a ! line crosses as itself"
       '("!" "echo hi") (text-carry-tree "!echo hi"))

(check "it commits as the standard shell running the command"
       (list 'run (list (bourne-shell) '-c "echo hi"))
       (bourne-line-datum '("!" "echo hi")))

(check "and it renders hugging its marker"
       #t (and (string-contains (render-tree '("!" "ls -l")) "!ls -l") #t))

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

;;; ---- C-r: the backward search, bash's keys -----------------------------------
;;; The same search the structure editor runs: letters narrow, C-r steps one
;;; match further back, backspace un-narrows, enter accepts the match as the
;;; line, escape accepts and keeps editing, C-g aborts to the line as C-r
;;; found it, and any other key accepts the match and runs as usual.

;; the match lands in the buffer, and enter commits it
(receive (text a)
    (session (append (string->list "zzz") (list Cr #\e #\c #\h 'enter)) ""
             (sexp->tree '(run (echo hi)))
             (sexp->tree '(run (ls))))
  (check "C-r narrows and enter takes the match"
         "(run (echo hi))" text)
  (check "  and commits" 'evaluate a))

;; the frames show the narrowing: the last frame has the query and the match
(receive (text a)
    (session (append (string->list "zzz") (list Cr #\e 'escape 'enter)) ""
             (sexp->tree '(run (echo)))
             (sexp->tree '(run (echo hi))))
  (check "C-r escape accepts and keeps editing"
         "(run (echo hi))" text)
  (check "  the frame showed the query and the match"
         '("e" "(run (echo hi))" #f) (car *frames*)))

;; C-r again walks back through the matches
(receive (text a)
    (session (append (string->list "zzz") (list Cr #\e 'enter)) ""
             (sexp->tree '(run (echo)))
             (sexp->tree '(run (echo hi))))
  (check "C-r narrows to the newest match first"
         "(run (echo hi))" text)
  (receive (text a)
      (session (append (string->list "zzz") (list Cr #\e Cr 'enter)) ""
               (sexp->tree '(run (echo)))
               (sexp->tree '(run (echo hi))))
    (check "C-r C-r steps one match further back"
           "(run (echo))" text)))

;; a dead query: the frame is failed, with the query as its line, and enter
;; keeps the line as C-r found it
(receive (text a)
    (session (append (string->list "zzz") (list Cr #\z #\z 'enter)) ""
             (sexp->tree '(run (echo hi))))
  (check "C-r on a dead query leaves the line as found" "zzz" text)
  (check "  and the frame said failed, query as the line"
         '("zz" #f #t) (car *frames*)))

;; C-g aborts to the line as C-r found it
(receive (text a)
    (session (append (string->list "zzz") (list Cr #\e Cg 'enter)) ""
             (sexp->tree '(run (echo hi))))
  (check "C-g aborts to the line as found" "zzz" text))

;; any other key accepts the match and runs as usual: a space after the
;; accepted match is inserted at the point
(receive (text a)
    (session (append (string->list "zzz") (list Cr #\e #\space 'enter)) ""
             (sexp->tree '(run (echo hi))))
  (check "a key after the search accepts and then runs"
         "(run (echo hi)) " text))

;; backspace un-narrows: the query shrinks, and the match stays while it
;; still matches -- a shorter query cannot unmatch the current item
(receive (text a)
    (session (append (string->list "zzz") (list Cr #\h #\i 'backspace 'enter)) ""
             (sexp->tree '(run (echo hi))))
  (check "backspace un-narrows, the match staying while it matches"
         '("h" "(run (echo hi))" #f) (car *frames*))
  (check "  and enter commits the still-matching line"
         "(run (echo hi))" text))

;;; ---- Tab completes a file name ------------------------------------------------
;;; The same shell hook the structure editor takes (structured-scsh/complete.scm),
;;; against a text line: the word before the point is replaced, a FILE takes
;;; bash's separator and a directory its slash, and a second Tab that cannot
;;; extend the word lists the matches.  Every expectation is bash's, measured.

(define dir (string-append "/tmp/scsh-textline-complete-" (number->string (getpid))))

(define (touch path)
  (let ((p (open-file path "w"))) (close-port p)))

(mkdir dir #o755)
(mkdir (string-append dir "/deep") #o755)
(mkdir (string-append dir "/documents") #o755)
(touch (string-append dir "/data.txt"))
(touch (string-append dir "/docu.txt"))
(chdir dir)

;; "doc" is shared by a file and a directory, so it extends and no further
(receive (text a) (completing-session (append (string->list "ls doc") (list 'tab)) "" text-complete)
  (check "Tab extends the word as far as it goes" "ls docu" text)
  (check "and says nothing when it could"         '() *candidates*))

(receive (text a) (completing-session (append (string->list "ls data") (list 'tab)) "" text-complete)
  (check "one match completes the word"        "ls data.txt " text)
  (check "with bash's separator after a file"  12 (string-length text)))

(receive (text a) (completing-session (append (string->list "ls deep") (list 'tab)) "" text-complete)
  (check "a directory gets a slash and no separator" "ls deep/" text))

(receive (text a) (completing-session
                   (append (string->list "(run (ls doc") (list 'tab)) "" text-complete)
  (check "the word after a ( is the one completed" "(run (ls docu" text))

;; an empty word completes to what EVERY name shares -- here "d" (bash: measured)
(receive (text a) (completing-session (append (string->list "ls ") (list 'tab)) "" text-complete)
  (check "an empty word extends to the common prefix" "ls d" text))

(receive (text a) (completing-session (append (string->list "ls zzz") (list 'tab)) "" text-complete)
  (check "no match leaves the line alone" "ls zzz" text)
  (check "and rings the bell" '((() #f)) *candidates*))

;; two Tabs that cannot extend the word: the first rings, the second lists
(receive (text a) (completing-session
                   (append (string->list "ls docu") (list 'tab 'tab)) "" text-complete)
  (check "the second Tab that cannot extend lists" '(#f #t) (map cadr *candidates*))
  (check "and the line is where it was" "ls docu" text))
(check "the listing shows the last segment only"
       (list "documents/" "docu.txt") (car (car *candidates*)))

;; the editor ignores Tab when no completion hook is given it (as it always did)
(receive (text a) (session (append (string->list "ls doc") (list 'tab)) "")
  (check "Tab with no hook is ignored" "ls doc" text))

;;; ---- verdict -----------------------------------------------------------------

(unless (null? failures)
  (for-each (lambda (f) (display (string-append "FAILED: " f "\n"))) (reverse failures))
  (exit 1))
(display "all textline checks pass\n")
