;;; editor-scsh-test.scm -- the scsh layer: shell operators as restructurings.
;;;
;;;   make -C test-suite engine

(use-modules (ice-9 receive) (ice-9 optargs) (srfi srfi-1))
(use-modules (editor engine) (editor render) (editor repl) (editor scsh))

;;; the shell's rows, with the old decline protocol: HANDLED? tells whether an
;;; operator took the key (the walker itself hides declining behind the
;;; fall-through, so these checks look one level down)
(define (shell-operators tree locus key)
  (let lp ((rs shell-rules))
    (if (null? rs)
        (values tree locus #f)
        (if ((rule-match (car rs)) key)
            (call-with-values (lambda () ((rule-handle (car rs)) tree locus key))
              (lambda (t l a handled?) (values t l handled?)))
            (lp (cdr rs))))))



(define failures '())
(define (check label expect got)
  (if (equal? expect got)
      (display (string-append "ok   " label "\n"))
      (begin (set! failures (cons label failures))
             (display (string-append "FAIL " label "\n  expect "))
             (write expect) (newline)
             (display "  got    ") (write got) (newline))))

(define (parses? s)
  (catch #t (lambda () (read (open-input-string s)) #t) (lambda args #f)))

;;; ---- what a line starts as --------------------------------------------------

(receive (t l taken?) (seed #\l)
  (check "a letter opens a shell command"       "(run ())" (render-tree t))
  (check "the locus is in the command form"     '((1) 0 0) l)
  (check "and the letter is typed into it"      #f taken?))

(receive (t l taken?) (seed #\()
  (check "a ( opens a plain Scheme form"        "()" (render-tree t))
  (check "and is taken as its opening paren"    #t taken?))

(receive (t l taken?) (seed #\))
  (check "a ) opens nothing"                    "" (render-tree t))
  (check "and is swallowed"                     #t taken?))

(receive (t l taken?) (seed #\,)
  (check "a , opens no command"                 "" (render-tree t))
  (check "and the comma is typed, as the marker" #f taken?))

;;; ---- "," -- a line that names a value, not a command -------------------------
;;; A REPL has to be able to show you a variable.  Typing ,x leaves one word,
;;; which reads as a reference to x; the shell strips the marker, so what the
;;; interpreter sees is just the name.

;; the line's reading is a one-element list -- the document is a form -- so the
;; first element is the reference, and line-datum below unwraps it
(check "a comma word reads as an unquote"
       '(unquote x) (car (tree->sexp (sexp->tree '(,x)))))
(check ",x at the top of a line is just the name"
       'x (line-datum (tree->sexp (sexp->tree '(,x)))))
(check ",(f 1) is the expression itself"
       '(+ 1 2) (line-datum (tree->sexp (sexp->tree '(,(+ 1 2))))))
(check "a line without a comma is untouched"
       '(run (ls)) (line-datum (tree->sexp (sexp->tree '(run (ls))))))
(check "a comma INSIDE a command keeps its meaning"
       '(run (echo (unquote x))) (line-datum (tree->sexp (sexp->tree '(run (echo ,x))))))

;;; the marker is only at the head of a line: a word that merely contains a comma
;;; is a word
(check "a comma inside a word is not a marker"
       '(run (echo a,x)) (line-datum (tree->sexp (sexp->tree '(run (echo a,x))))))

;;; the structural sugar is for shell lines only: in a Scheme form, | and > are
;;; ordinary characters
(receive (t l handled) (shell-operators (sexp->tree '(display 5)) (make-locus '() 1 1) #\|)
  (check "| does not restructure a Scheme line" #f handled))
(receive (t l handled) (shell-operators (sexp->tree '(display 5)) (make-locus '() 1 1) #\>)
  (check "> neither"                            #f handled))

;;; ---- |  a pipeline -----------------------------------------------------------
;;; note the locus: at the END of the form (after "-l"), which is where the
;;; assistance applies.  At the end of "ls" -- with "-l" still to come -- the
;;; next visible thing is not the form's ")", so | would just be the atom.

(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls -l))) (make-locus '(1) 1 2) #\|)
  (check "| opens a pipeline"                     "(run (| (ls -l) ()))" (render-tree t))
  (check "| puts the locus in the new stage"      '((1 2) 0 0) l)
  (check "| is handled"                           #t handled)
  (check "| output parses"                        #t (parses? (render-tree t))))

;;; the dangling empty word left by typing space first is tidied away
(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls ""))) (make-locus '(1) 1 0) #\|)
  (check "| tidies a dangling empty word"  "(run (| (ls) ()))" (render-tree t))
  (check "| tidied stage is still stage 1" #t handled))

;;; a stage of a pipeline joins ITS pipeline: piping a stage extends the pipe
;;; in place rather than nesting a pipe inside a pipe
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (ls) (wc)))) (make-locus '(1 2) 0 2) #\|)
  (check "| on a stage extends the pipeline" "(run (| (ls) (wc) ()))" (render-tree t))
  (check "with the locus in the new stage"   '((1 3) 0 0) l)
  (check "and it is handled"                 #t handled))

;; ls | wc | wc -- the whole flow, three stages, no nesting.  Every key goes
;; through the real table: the letters fall through to the printer, the |s
;; restructure.
(receive (t1 l1 a) (dispatch-key (sexp->tree '(run (ls))) (make-locus '(1) 0 2) #\| #:rules (append shell-rules core-rules))
  (receive (t2 l2 a) (dispatch-key t1 l1 #\w #:rules (append shell-rules core-rules))
    (receive (t3 l3 a) (dispatch-key t2 l2 #\c #:rules (append shell-rules core-rules))
      (receive (t4 l4 a) (dispatch-key t3 l3 #\| #:rules (append shell-rules core-rules))
        (receive (t5 l5 a) (dispatch-key t4 l4 #\w #:rules (append shell-rules core-rules))
          (receive (t6 l6 a) (dispatch-key t5 l5 #\c #:rules (append shell-rules core-rules))
            (check "ls | wc | wc builds a flat three-stage pipeline"
                   "(run (| (ls) (wc) (wc)))" (render-tree t6))
            (check "and every stage sits in the one pipe"
                   '(run (| (ls) (wc) (wc))) (tree->sexp t6))))))))

;; a stage that is not the last: the fresh stage splices in beside it
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (wc) (grep)))) (make-locus '(1 1) 0 2) #\|)
  (check "| beside a middle stage splices there" "(run (| (wc) () (grep)))" (render-tree t)))

;; the cursor at the pipeline's own end: a stage joins it
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (ls) (wc)))) (make-locus '(1) 3 0) #\|)
  (check "| at the pipe's end grows it" "(run (| (ls) (wc) ()))" (render-tree t))
  (check "with the locus in the new stage" '((1 3) 0 0) l))

;;; ---- >  a redirection --------------------------------------------------------

(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls))) (make-locus '(1) 0 2) #\>)
  (check "> opens a redirection"                  "(run (ls) (> ))" (render-tree t))
  (check "> puts the locus in the file-name slot" '((2) 1 0) l)
  (check "> is handled"                           #t handled))

;;; ---- > and | keep a redirection aimed at its command -------------------------
;;; A redirection belongs to the form it follows.  > aims it at the command the
;;; cursor is on; | re-shapes the tree so an existing redirect keeps pointing
;;; where it pointed.  The epf form is how a pipeline stage carries its own.

;; > on the LAST stage of a pipeline opens after the pipeline: scsh applies a
;; pipeline's trailing redirect to its last stage, so the aim is unchanged
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (ls) (wc)))) (make-locus '(1 2) 0 2) #\>)
  (check "> on the last stage opens after the pipe" "(run (| (ls) (wc)) (> ))" (render-tree t))
  (check "  in the file-name slot"                  '((2) 1 0) l)
  (check "  handled"                                #t handled))

;; > on the pipeline itself is the same: it opens after the pipeline
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (ls) (wc)))) (make-locus '(1) 3 0) #\>)
  (check "> on the pipeline opens after it"       "(run (| (ls) (wc)) (> ))" (render-tree t)))

;; > on a NON-last stage: only an epf wrap keeps the redirect aimed at ls and
;; not at the pipe's end
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (ls) (wc)))) (make-locus '(1 1) 0 2) #\>)
  (check "> on a mid stage wraps the stage in epf" "(run (| (epf (ls) (> )) (wc)))" (render-tree t))
  (check "  in the file-name slot"                 '((1 1 2) 1 0) l))

;; > stacks after the redirects already there (scsh lets them accumulate)
(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls) (> f))) (make-locus '(2) 1 1) #\>)
  (check "> stacks after an existing redirect"    "(run (ls) (> f) (> ))" (render-tree t)))
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (ls) (wc)) (> f))) (make-locus '(1 2) 0 2) #\>)
  (check "> on the last stage stacks after the pipe's redirects"
         "(run (| (ls) (wc)) (> f) (> ))" (render-tree t)))

;; ls >foo | wc: | on the redirect wraps command and redirect as the first
;; stage, so the redirect still takes ls's output
(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls) (> foo))) (make-locus '(2) 1 3) #\|)
  (check "| on a redirect epf-wraps the pair"     "(run (| (epf (ls) (> foo)) ()))" (render-tree t))
  (check "  cursor in the fresh stage"            '((1 2) 0 0) l)
  (check "  handled"                              #t handled))

;; the same, with the cursor on the COMMAND the redirect follows
(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls) (> foo))) (make-locus '(1) 0 2) #\|)
  (check "| on the command takes its redirect along"
         "(run (| (epf (ls) (> foo)) ()))" (render-tree t)))

;; ls | wc >foo | grep: | on the pipeline-level redirect moves it down into the
;; last stage -- what it was aimed at -- and the fresh stage opens after it
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (ls) (wc)) (> foo))) (make-locus '(2) 1 3) #\|)
  (check "| moves a pipe-level redirect into the last stage"
         "(run (| (ls) (epf (wc) (> foo)) ()))" (render-tree t))
  (check "  cursor in the fresh stage"            '((1 3) 0 0) l))

;; the same move, | pressed at the pipeline's own end...
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (ls) (wc)) (> foo))) (make-locus '(1) 3 0) #\|)
  (check "| at the pipe's end takes the trailing redirect down with it"
         "(run (| (ls) (epf (wc) (> foo)) ()))" (render-tree t)))

;; ...and | pressed on the last stage itself
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (ls) (wc)) (> foo))) (make-locus '(1 2) 0 2) #\|)
  (check "| on the last stage takes the trailing redirect into it"
         "(run (| (ls) (epf (wc) (> foo)) ()))" (render-tree t)))

;; ls >f | wc | sort: chaining continues after an epf stage in the one pipe
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (epf (ls) (> f)) (wc)))) (make-locus '(1 2) 0 2) #\|)
  (check "| chains on after an epf stage"         "(run (| (epf (ls) (> f)) (wc) ()))" (render-tree t)))

;; | on a redirect that already lives inside an epf: it is where it belongs,
;; so the epf's stage is what pipes
(receive (t l handled)
    (shell-operators (sexp->tree '(run (| (epf (wc) (> f)) (grep))))
                     (make-locus '(1 1 2) 1 1) #\|)
  (check "| beside an epf stage opens after it"   "(run (| (epf (wc) (> f)) () (grep)))" (render-tree t)))

;;; ---- &  background, and back again -------------------------------------------

;;; with job control ON, & is just a background job: the kernel does the stopping
(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls))) (make-locus '(1) 0 2) #\&)
  (check "& backgrounds the line"                 "(& (ls))" (render-tree t))
  (check "& is handled"                           #t handled))

(receive (t l handled)
    (shell-operators (sexp->tree '(& (ls))) (make-locus '(1) 0 2) #\&)
  (check "& again puts run back"                  "(run (ls))" (render-tree t)))

;;; with job control OFF, fall back to the POSIX rule for that case: /dev/null
(job-control? #f)
(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls))) (make-locus '(1) 0 2) #\&)
  (check "& with job control off: /dev/null on stdin"
         "(& (ls) (< /dev/null))" (render-tree t)))
(receive (t l handled)
    (shell-operators (sexp->tree '(& (ls) (< /dev/null))) (make-locus '(1) 0 2) #\&)
  (check "& again takes the /dev/null away"       "(run (ls))" (render-tree t)))
(job-control? #t)

(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls) (< /tmp/in))) (make-locus '(1) 0 2) #\&)
  (check "& keeps an input redirection you wrote" "(& (ls) (< /tmp/in))" (render-tree t)))



;;; ---- at the start of a form, operators are just atoms --------------------------
;;; (you are building the form by hand; | must not wrap anything)

(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls))) (make-locus '(1) 0 0) #\|)
  (check "| at the start of a form is just the atom" #f handled))

(receive (t l handled)
    (shell-operators (sexp->tree '(run ((ls) (wc)))) (make-locus '(1) 0 0) #\|)
  (check "| at the start of a form whose first element is a form" #f handled))

(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls))) (make-locus '(1) 0 0) #\>)
  (check "> at the start of a form is just the atom" #f handled))

;;; ---- the guards ---------------------------------------------------------------

(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls))) (make-locus '(1) 0 1) #\|)
  (check "| from the middle of a word is left alone" #f handled))

(receive (t l handled)
    (shell-operators (sexp->tree '(run ())) (make-locus '(1) 0 0) #\|)
  (check "| with no command to pipe is left alone"   #f handled))

(receive (t l handled)
    (shell-operators (sexp->tree '(run (ls))) (make-locus '(1) 0 2) #\z)
  (check "an ordinary letter is not an operator"     #f handled))

;;; ---- a whole line, through the loop, with the shell wired in -------------------

(define (session keys tree locus)
  (let ((drawn '()))
    (receive (t l reason)
        (run-loop (lambda () (let ((k (car keys))) (set! keys (cdr keys)) k))
                  (lambda (text col row bold) (set! drawn (cons (list text col bold row) drawn)))
                  tree locus
                  #:seed seed
                  #:rules (append shell-rules core-rules))
      (values t l reason (reverse drawn)))))

(receive (t l reason frames)
    (session (list #\l #\s #\| #\w #\c 'enter) '() (make-locus '() 0 0))
  (check "session: ls | wc  ->  a pipeline"   (list 'run (list '| (list 'ls) (list 'wc)))
         (tree->sexp t))
  (check "session: and Enter commits"         'evaluate reason)
  (check "session: every frame parses"        #t (every (lambda (f) (parses? (car f))) frames)))

(receive (t l reason frames)
    (session (list #\l #\s #\> #\f 'enter) '() (make-locus '() 0 0))
  (check "session: ls > f"                    (list 'run (list 'ls) (list '> (string->symbol "f")))
         (tree->sexp t)))

(receive (t l reason frames)
    (session (list #\l #\s #\& 'enter) '() (make-locus '() 0 0))
  (check "session: ls & is a background job"   (list '& (list 'ls)) (tree->sexp t)))

;;; ---- verdict ------------------------------------------------------------------

(newline)
(if (null? failures)
    (begin (display "ALL CHECKS PASSED") (newline) (exit 0))
    (begin (display "FAILURES: ") (write failures) (newline) (exit 1)))