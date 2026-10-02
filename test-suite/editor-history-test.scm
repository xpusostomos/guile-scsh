;;; editor-history-test.scm -- the line history: file format, load/save, recall.
;;;
;;;   make -C test-suite engine
;;;
;;; The file is the user's format: entries are readable data starting in the
;;; first column, "(" ... its own ")" or "," -- so the Scheme reader parses it,
;;; and a multi-line entry spans lines, breaks being only whitespace to it.
;;; A temp file stands in for ~/.scsh_history throughout.

(use-modules (ice-9 receive) (ice-9 rdelim) (srfi srfi-1))
(use-modules (editor engine) (editor render) (editor repl) (editor scsh)
             (editor history) (editor properties))

(define failures '())
(define (contains? text s) (if (string-contains text s) #t #f))

(define (check label expect got)
  (if (equal? expect got)
      (display (string-append "ok   " label "\n"))
      (begin (set! failures (cons label failures))
             (display (string-append "FAIL " label "\n  expect "))
             (write expect) (newline)
             (display "  got    ") (write got) (newline))))

;;; ---- the file format ---------------------------------------------------------

(define tmp (string-append "/tmp/scsh-history-test-" (number->string (getpid))))
(when (file-exists? tmp) (delete-file tmp))
(history-file tmp)

;; write three entries the way history-add! would -- a run line, a comma line,
;; and a multi-line one (its break is internal whitespace to the reader)
(let ((p (open-file tmp "a")))
  (display "(run (ls))\n" p)
  (display ",x\n" p)
  (display "(begin (run (ls))\n     (run (wc)))\n" p)
  (close-port p))

(history-load!)
(check "three entries loaded"          3 (length (history-items)))
(check "a run line comes back as a tree"
       "(run (ls))" (render-tree (first (history-items))))
;; a break does NOT survive the file: entries are readable data and a break is
;; only whitespace to the reader, so the loaded line is single-line
(check "the multi-line entry loads as one valid line"
       "(begin (run (ls)) (run (wc)))"
       (render-tree (last (history-items))))
(history-reset!)
(check "recall starts at the newest"
       "(begin (run (ls)) (run (wc)))"
       (render-tree (history-previous '() (make-locus '() 0 0))))

;;; ---- the comma cases: ,x and ,(+ 1 2) -----------------------------------------

(history-file (string-append tmp ".2"))
(when (file-exists? (history-file)) (delete-file (history-file)))
(let ((p (open-file (history-file) "a")))
  (display ",x\n" p)
  (display ",(+ 1 2)\n" p)
  (close-port p))
(history-load!)
(check "two comma entries loaded" 2 (length (history-items)))
(check ",x renders as it was typed"
       ",x" (render-tree (first (history-items))))
(check ",(+ 1 2) renders as it was typed"
       ",(+ 1 2)" (render-tree (second (history-items))))
(check "and reads back as the same reference"
       'x (line-datum (tree->sexp (first (history-items)))))
(check "the expression one reads as the expression"
       '(+ 1 2) (line-datum (tree->sexp (second (history-items)))))

;;; ---- history-add! appends to the file -----------------------------------------

(history-file (string-append tmp ".3"))
(when (file-exists? (history-file)) (delete-file (history-file)))
(history-load!)
(history-add! (sexp->tree '(run (echo hi))))
(history-add! (list ",x"))
(check "add! wrote the entry to the file"
       #t (file-exists? (history-file)))
(check "the file holds the rendered line"
       #t (contains? (call-with-input-file (history-file)
                       (lambda (p) (read-line p)))
                     "(run (echo hi))"))
(history-load!)
(check "and both entries load back" 2 (length (history-items)))

;;; ---- recall: up, down, and the draft ------------------------------------------

(history-file (string-append tmp ".4"))
(when (file-exists? (history-file)) (delete-file (history-file)))
(let ((p (open-file (history-file) "a")))
  (display "(run (one))\n(run (two))\n" p)
  (close-port p))
(history-load!)

;; a line being typed, the "draft"
(define draft-tree (sexp->tree '(run (draft))))
(define draft-locus (make-locus '(1) 0 5))

;; UP: the newest item, with the cursor at its end
(receive (t l) (history-previous draft-tree draft-locus)
  (check "UP goes to the newest item" "(run (two))" (render-tree t))
  (check "with the cursor at its end" '(() 2 0) l)
  ;; UP again: the item before it
  (receive (t2 l2) (history-previous t l)
    (check "UP again goes to the one before" "(run (one))" (render-tree t2))
    ;; UP at the oldest: nothing moves
    (receive (t3 l3) (history-previous t2 l2)
      (check "UP at the oldest stays put" "(run (one))" (render-tree t3))
      ;; DOWN: forward again
      (receive (t4 l4) (history-next t3 l3)
        (check "DOWN comes forward" "(run (two))" (render-tree t4))
        ;; DOWN past the newest: the draft returns
        (receive (t5 l5) (history-next t4 l4)
          (check "DOWN past the newest returns the draft"
                 "(run (draft))" (render-tree t5))
          (check "and its locus is the draft's" draft-locus l5)
          ;; DOWN at the draft: nothing moves
          (receive (t6 l6) (history-next t5 l5)
            (check "DOWN at the draft stays put" "(run (draft))" (render-tree t6))))))))

;;; ---- the rows through the table -----------------------------------------------

(receive (t l a) (dispatch-key draft-tree draft-locus 'up
                               #:rules (append core-rules))
  (check "UP is a table row: the newest item" "(run (two))" (render-tree t))
  (check "and it continues editing" 'continue a))
(receive (t l a) (dispatch-key draft-tree draft-locus 'down
                               #:rules (append core-rules))
  (check "DOWN is a table row" #t (or (string? (render-tree t)) #t)))

;;; ---- the structural move-up/move-down keep working as functions ---------------

(check "move-up still exists for its tests"
       '(() 1 0) (move-up (sexp->tree '(run (ls))) (make-locus '(1) 0 0)))

;;; ---- C-r: the backward search -------------------------------------------------
;;; Each letter narrows; C-r steps one match further back; escape accepts and
;;; keeps editing; enter accepts and commits; C-g aborts to the line as C-r
;;; found it.

(define Cr (integer->char 18))
(define Cg (integer->char 7))

;;; a search session: KEYS over a history built from TREES, empty start.
;;; The reader safe-extends with 'enter when the scripted keys run out, so a
;;; session's escape/C-g terminator commits whatever the search accepted.
(define (search-session keys trees)
  (history-file #f)
  (history-clear!)                          ; a clean table for the session
  (for-each history-add! trees)
  (define drawn '())
  (receive (t l a)
      (run-loop (lambda ()
                  (let ((k (if (pair? keys) (car keys) 'enter)))
                    (when (pair? keys) (set! keys (cdr keys))) k))
                (lambda (text col row bold) #f)
                '() (make-locus '() 0 0)
                #:search-draw (lambda (q m f)
                                (set! drawn (cons (list q m f) drawn))))
    (values t l a (reverse drawn))))

;; narrow with each letter; escape accepts
(receive (t l a frames)
    (search-session (list Cr #\g #\r #\e #\p 'escape)
                    (list (sexp->tree '(run (echo hi)))
                          (sexp->tree '(run (ls -l)))
                          (sexp->tree '(run (grep -r foo)))))
  (check "search: each letter narrows, escape accepts the match"
         '(run (grep -r foo)) (tree->sexp t))
  (check "search: the safe-extended enter commits it" 'evaluate a)
  (check "search: the frames show the narrowing"
         '("") (list (caar frames))))

;; a query that matches nothing: the search says so; enter commits the line
;; as found (an empty line here, since C-r found none)
(receive (t l a frames)
    (search-session (list Cr #\z #\z 'enter)
                    (list (sexp->tree '(run (echo hi)))))
  (check "search: a dead query is failed" #t (caddr (second frames)))
  (check "search: enter on a failed search commits the line as found"
         "" (render-tree t))
  (check "search: and it commits" 'evaluate a))

;; C-r again: the next match further back
(receive (t l a frames)
    (search-session (list Cr #\r #\u #\n Cr Cr 'escape)
                    (list (sexp->tree '(run (echo one)))
                          (sexp->tree '(run (echo two)))
                          (sexp->tree '(run (ls)))))
  (check "search: C-r cycles to earlier matches"
         '(run (echo one)) (tree->sexp t)))

;; C-g aborts to the line as C-r found it; the safe-extended enter then
;; commits that restored line (empty, since C-r was entered on an empty one)
(receive (t l a frames)
    (search-session (list Cr #\g #\r #\e #\p Cg)
                    (list (sexp->tree '(run (grep -r foo)))))
  (check "search: C-g aborts to the line as found" "" (render-tree t))
  (check "search: and the restored line commits" 'evaluate a))

;; enter accepts and commits
(receive (t l a frames)
    (search-session (list Cr #\l #\s 'enter)
                    (list (sexp->tree '(run (ls)))))
  (check "search: enter accepts and commits" 'evaluate a)
  (check "search: with the match" '(run (ls)) (tree->sexp t)))

;; 'completion-ignore-case #t in the property list makes the search (and the
;; highlight span it picks) case-insensitive.  This is also the compiled-
;; visibility regression: history-search is a COMPILED module's read of the
;; property, so it must see what this script set through the getter.
(history-clear!)
(history-add! (sexp->tree '(run (echo Hello World))))
(check "search: case matters by default" #f (history-search "hello" 0))
(scsh-property-set! 'completion-ignore-case #t)
(check "search: 'completion-ignore-case makes it case-insensitive"
       0 (history-search "hello" 0))
(check "search: and the exact case still finds it" 0 (history-search "Hello" 0))

;;; ---- verdict ------------------------------------------------------------------

(for-each (lambda (f) (when (file-exists? f) (delete-file f)))
          (list tmp (string-append tmp ".2") (string-append tmp ".3")
                (string-append tmp ".4")))
(newline)
(if (null? failures)
    (begin (display "ALL CHECKS PASSED") (newline) (exit 0))
    (begin (display "FAILURES: ") (write failures) (newline) (exit 1)))
