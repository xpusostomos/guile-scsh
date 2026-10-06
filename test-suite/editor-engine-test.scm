;;; editor-engine-test.scm -- tests for structured-scsh/engine.scm + structured-scsh/render.scm
;;;
;;; These assert on the STRUCTURE (tree -> sexp), except where the renderer is
;;; the thing under test.  No terminal, no readline, no processes.
;;;
;;;   make -C test-suite engine        (or, from the repo root:)
;;;   guile -q -L . test-suite/editor-engine-test.scm

(use-modules (ice-9 receive))
(use-modules (structured-scsh engine) (structured-scsh render))

(define failures '())
(define (check label expect got)
  (if (equal? expect got)
      (display (string-append "ok   " label "\n"))
      (begin (set! failures (cons label failures))
             (display (string-append "FAIL " label "\n  expect "))
             (write expect) (newline)
             (display "  got    ") (write got) (newline))))

;;; the property that matters: whatever we render is ONE readable datum, i.e.
;;; the structure can never be malformed no matter what keys were pressed
(define (parses? s)
  (catch #t (lambda () (read (open-input-string s)) #t) (lambda args #f)))

;;; ---- rendering -------------------------------------------------------------

(check "an empty document is an empty line" "" (render-tree '()))
(check "render plain"       "(run (ls -l))"          (render-tree (sexp->tree '(run (ls -l)))))
(check "render pipeline"    "(run (| (ls -l) (wc)))" (render-tree (sexp->tree '(run (| (ls -l) (wc))))))
(check "render empty form"  "(run ())"               (render-tree (sexp->tree '(run ()))))

;;; the document is the line and is bracketed -- except when it names a value,
;;; which is what a leading comma means; then it is drawn bare
(check "a comma line is drawn bare"   ",foo" (render-tree (list ",foo")))
(check "and with the comma typed apart" ",foo" (render-tree (list "," "foo")))
(check "and a comma expr"             ",(f 1)" (render-tree (list "," (list "f" "1"))))
(check "a comma inside a form is not the line's marker"
       "(run (echo ,x))" (render-tree (list "run" (list "echo" ",x"))))

(receive (text col row bold) (render (sexp->tree '(run (ls -l))) (make-locus '(1) 0 1))
  (check "render leaves text alone" "(run (ls -l))" text)
  (check "cursor column inside ls"  7 col)
  (check "only the parens of that form are bold, nothing inside"
         (list (cons 5 6) (cons 11 12)) bold))     ; the "(" and ")" of (ls -l)

;;; ---- bold: the parens of the form the cursor is in ---------------------------

(define (bold-of tree locus)
  (call-with-values (lambda () (render tree locus)) (lambda (t c r b) b)))

(define (bold-text tree locus)
  (let ((t (render-tree tree)))
    (map (lambda (s) (substring t (car s) (cdr s))) (bold-of tree locus))))

(check "inside a word: that form's two parens"
       '("(" ")") (bold-text (sexp->tree '(run (ls -l))) (make-locus '(1) 0 1)))
(check "inside a nested form: that form's, not each subform's"
       '("(" ")") (bold-text (sexp->tree '(run (| (ls -l) (wc))))
                             (make-locus '(1 2) 0 1)))
(check "at the root, in a word: the line's own parens"
       '("(" ")") (bold-text (sexp->tree '(run (ls -l))) (make-locus '() 0 3)))
(check "a comma line has no parens, so nothing"
       '() (bold-text (list ",foo") (make-locus '() 0 1)))

;;; ---- ON a "(" is IN that form ------------------------------------------------
;;; The cursor sits on a "(" exactly when the element at its index is a form,
;;; and then that form is the target -- not the one containing it.

(define (on-the-paren tree) (make-locus '() 1 0))   ; cursor on the ( of element 1

(check "on the ( of a form: that form's parens are bold, not the line's"
       '("(" ")") (bold-text (sexp->tree '(run (ls -l))) (on-the-paren (sexp->tree '(run (ls -l))))))

(check "Tab on a ( targets that form: the empty command form barfs its word"
       "(run () ls)"
       (render-tree (call-with-values
                     (lambda () (transpose-node (sexp->tree '(run (ls))) (make-locus '() 1 0)))
                     (lambda (t l) t))))
(check "and the cursor stays on that ("
       '((() 1 0))
       (call-with-values
        (lambda () (transpose-node (sexp->tree '(run (ls))) (make-locus '() 1 0)))
        (lambda (t l) (list l))))

;;; ... and back again: the empty form slurps its word back in
(receive (t l) (transpose-node (sexp->tree '(run (ls))) (make-locus '() 1 0))
  (receive (t2 l2) (transpose-node t l)
    (check "Tab on a ( cycles: the empty form slurps the word back"
           "(run (ls))" (render-tree t2))
    (check "still on the same (" '((() 1 0)) (list l2))))

;;; the pipe form from its (: barf, and the cursor does not move
(receive (t l) (transpose-node (sexp->tree '(run (| (ls) (wc)))) (make-locus '() 1 0))
  (check "Tab on the ( of the pipe form barfs its last stage"
         "(run (| (ls)) (wc))" (render-tree t))
  (check "with the cursor still on its (" '((() 1 0)) (list l)))
(receive (t l) (transpose-node (sexp->tree '(run (| (ls)) (wc))) (make-locus '() 1 0))
  (check "and slurps it back" "(run (| (ls) (wc)))" (render-tree t)))
(check "an empty line has nothing to be bold"
       '() (bold-of '() (make-locus '() 0 0)))
(check "with no locus, no styling" '() (bold-of (sexp->tree '(run (ls))) #f))

;;; ---- the scenario from the terminal, in the tree ---------------------------
;;; type "ls" -> (run (ls)); put the locus on the second "(" ; press "(" ->
;;; (run () (ls))   [what you saw]   ; then Tab to regroup, and Tab again.

(define t0 (sexp->tree '(run ())))
(receive (t1 l1) (insert-char t0 (make-locus '(1) 0 0) #\l)
  (receive (t2 l2) (insert-char t1 l1 #\s)
    (check "typing ls"        '(run (ls))   (tree->sexp t2))
    (check "typing ls text"   "(run (ls))"  (render-tree t2))
    (check "typing ls locus"  '((1) 0 2)    l2)

    (receive (t3 l3) (insert-form t2 (make-locus '() 1 0))
      (check "insert-form text"  "(run () (ls))" (render-tree t3))
      (check "insert-form locus enters it" '((1) 0 0) l3)
      (check "insert-form is one datum"    #t (parses? (render-tree t3)))

      (receive (t4 l4) (transpose-node t3 l3)
        (check "Tab slurp"        "(run ((ls)))" (render-tree t4))
        (check "Tab slurp parses" #t (parses? (render-tree t4)))
        (receive (t5 l5) (transpose-node t4 l4)
          (check "Tab barf returns" "(run () (ls))" (render-tree t5))
          (check "Tab barf parses"  #t (parses? (render-tree t5))))))))

;;; ---- Tab: the cursor does not move, so Tab cycles ----------------------------
;;; Everything Tab does happens to the RIGHT of the locus, so the locus keeps
;;; its place: an element inside the form keeps its index and a word keeps its
;;; offset.  If the cursor wandered, the next Tab would be regrouping something
;;; else, and the two options could never be cycled.

(define (tab-n tree locus n)
  (let lp ((k n) (tree tree) (locus locus) (seen '()))
    (if (zero? k)
        (values tree locus (reverse seen))
        (receive (t l) (transpose-node tree locus)
          (lp (- k 1) t l (cons (render-tree t) seen))))))

;; the reported case: (run (| (ls) (wc))) with the cursor on the l of "ls"
(receive (t l seen) (tab-n (sexp->tree '(run (| (ls) (wc)))) (make-locus '(1 1) 0 1) 4)
  (check "Tab: the cursor stays on the character it was on" '((1 1) 0 1) l)
  (check "Tab: and the two groupings alternate"
         '("(run (| (ls (wc))))" "(run (| (ls) (wc)))"
           "(run (| (ls (wc))))" "(run (| (ls) (wc)))")
         seen))

;;; ---- Tab walks through every grouping, not just the last two ----------------
;;; Reported: on (ls (a) () () () ()) with the cursor on the a, the ")" after it
;;; moves out on each Tab, but at the end it toggles between the last two
;;; groupings for ever.  Slurp and barf are exact inverses, so a Tab that chose
;;; by looking at the tree alone could never do anything else.  Tab now keeps
;;; its direction until it runs out of room, then turns round.

(define (tab-cycle tree locus n)
  (let lp ((k n) (tr tree) (lo locus) (dir 'slurp) (seen '()))
    (if (zero? k)
        (reverse seen)
        (receive (a b d) (regroup tr lo dir)
          (lp (- k 1) a b d (cons (render-tree a) seen))))))

(check "Tab walks out through every grouping and back again"
       '("(ls (a ()) () () ())"   "(ls (a () ()) () ())"  "(ls (a () () ()) ())"
         "(ls (a () () () ()))"   "(ls (a () () ()) ())"  "(ls (a () ()) () ())"
         "(ls (a ()) () () ())"   "(ls (a) () () () ())")
       (tab-cycle (sexp->tree '(ls (a) () () () ())) (make-locus '(1) 0 1) 8))

;; past the grouping it started in, the form gives up its last child -- the
;; other end of the same walk -- and the next Tab takes it back in
(check "the walk continues past the starting point rather than sticking"
       '("(ls () a () () () ())" "(ls (a) () () () ())")
       (list-tail (tab-cycle (sexp->tree '(ls (a) () () () ()))
                             (make-locus '(1) 0 1) 10)
                  8))

;;; the two-grouping case still alternates the way it did
(check "one sibling: the two groupings alternate"
       '("(run (| (ls (wc))))" "(run (| (ls) (wc)))")
       (tab-cycle (sexp->tree '(run (| (ls) (wc)))) (make-locus '(1 1) 0 1) 2))

;; just after the form's "(" is a place too, and it stays that place
(receive (t l seen) (tab-n (sexp->tree '(run (| (ls) (wc)))) (make-locus '(1 1) 0 0) 2)
  (check "Tab: just after a ( it stays just after that ("
         '((1 1) 0 0) l))

;; a word inside the form keeps its offset, so the same letter stays under it
(receive (t l seen) (tab-n (sexp->tree '(run (ls -l))) (make-locus '(1) 1 1) 2)
  (check "Tab: the form grows and shrinks around it"
         '("(run (ls) -l)" "(run (ls -l))") seen)
  (check "Tab: and the end slot follows the ) back out"
         '((1) 2 0) l))

;; an offset inside a word is kept while the word stays put; here the word the
;; cursor is in is the one barfed out, so the locus clamps to the form's end
(receive (t l) (transpose-node (sexp->tree '(run (ls -l))) (make-locus '(1) 1 1))
  (check "Tab: an offset inside a barfed word clamps to the end"
         '((1) 1 0) l))

;; the slot at the right edge is the one thing that adjusts: it means "just
;; before the )", so it follows the ) as the form shrinks and grows again
(receive (t l seen) (tab-n (sexp->tree '(run (ls -l))) (make-locus '(1) 2 0) 2)
  (check "Tab: the end slot follows the )" '((1) 2 0) l)
  (check "Tab: and it cycles there too"
         '("(run (ls) -l)" "(run (ls -l))") seen))

;;; ---- LEFT and RIGHT are opposites --------------------------------------------
;;; Reported: with the cursor on the z of (((ls df) sdf dsf) zf), LEFT jumped to
;;; the second "(" -- it stepped onto the START of the form to the left, i.e.
;;; clean over the whole form.  Leftwards of a form's ")" is that form's END.

(define nested (sexp->tree '(((ls df) sdf dsf) zf)))

(define (at tree locus)
  (receive (text col row bold) (render tree locus)
    (string-append (substring text 0 col) "|" (substring text col))))

(check "LEFT from the z goes into the form on its left, at its end"
       "(((ls df) sdf dsf|) zf)" (at nested (move-left nested (make-locus '() 1 0))))
(check "LEFT inside a form reaches the end of the form before it"
       "(((ls df|) sdf dsf) zf)" (at nested (move-left nested (make-locus '(0) 1 0))))
(check "LEFT at the start of the line stays put, on the line's own ("
       "|(((ls df) sdf dsf) zf)" (at nested (move-left nested (make-locus '() 0 0))))
(check "the line's first ( hosts the cursor: root index 0 renders at column 0"
       "|(ls (wc))" (at (sexp->tree '(ls (wc))) (make-locus '() 0 0)))
(check "a just-opened empty form keeps the cursor between its parens"
       "(|)" (at (list "") (make-locus '() 0 0)))

;; and the two movements undo each other, which is what makes them movements
(for-each
 (lambda (locus)
   (check "LEFT then RIGHT is where you were"
          (at nested locus) (at nested (move-right nested (move-left nested locus)))))
 (list (make-locus '() 1 0) (make-locus '(0) 1 0) (make-locus '(0 0) 0 1)
       (make-locus '() 1 2) (make-locus '(0) 3 0)))

;;; ---- ; wraps the line in (begin ...) ----------------------------------------
;;; The begin body is a second toplevel: whatever works at the prompt works
;;; inside it.  At the very start of the line the cursor stays before the old
;;; form; anywhere else it lands at the begin's toplevel, after the old form.

(receive (t l) (wrap-begin (sexp->tree '(run (ls))) (make-locus '(1) 0 2))
  (check "; mid-form wraps the line"        "(begin (run (ls)))" (render-tree t))
  (check "and lands after the old form"     '((() 2 0)) (list l))
  (check "still one readable datum"         #t (parses? (render-tree t))))

(receive (t l) (wrap-begin (sexp->tree '(run (ls))) (make-locus '() 0 0))
  (check "; at the very start wraps too"    "(begin (run (ls)))" (render-tree t))
  (check "and leaves the cursor before the old form" '((() 1 0)) (list l)))

(receive (t l) (wrap-begin '() (make-locus '() 0 0))
  (check "; on an empty line does nothing"  "" (render-tree t)))

(receive (t l) (wrap-begin (sexp->tree '(run (ls))) (make-locus '(1) 0 2))
  (receive (t2 l2) (wrap-begin t l)
    (check "; again wraps again, as the tree says" "(begin (begin (run (ls))))" (render-tree t2))))

;;; ---- atom edits ------------------------------------------------------------

(receive (t l) (insert-char (sexp->tree '(run (ls -l))) (make-locus '(1) 0 1) #\X)
  (check "insert mid-symbol"       "(run (lXs -l))" (render-tree t))
  (check "insert mid-symbol locus" '((1) 0 2) l))

(receive (t l) (delete-left (sexp->tree '(ls -l)) (make-locus '() 1 0))
  (check "backspace at word start joins with the previous word"
         "(ls-l)" (render-tree t)))

;;; ---- backspace walks back out of a form --------------------------------------
;;; Typing "l" gives (run (l)); backspace must be able to take that all the way
;;; back to an empty line -- (run ()), (run), nothing -- since there is no "("
;;; character to delete and stopping half-way out would strand you in the tree.

(define (backspace-all tree locus n)
  (let lp ((n n) (tree tree) (locus locus))
    (if (zero? n)
        (values tree locus)
        (receive (t l) (delete-left tree locus) (lp (- n 1) t l)))))

;;; the user's exact sequence: type l, then backspace three times
(receive (t l) (insert-char (sexp->tree '(run ())) (make-locus '(1) 0 0) #\l)
  (check "typing l" "(run (l))" (render-tree t))
  (receive (t1 l1) (delete-left t l)              ; delete the "l"
    (check "backspace once clears the word" "(run ())" (render-tree t1))
    (check "and stays inside the form"      '((1) 0 0) l1)
    (receive (t2 l2) (delete-left t1 l1)          ; the empty form goes
      (check "backspace again kills the form" "(run)" (render-tree t2))
      (check "and the locus is where it stood" '(() 1 0) l2)
      (check "the tree is still well formed"   #t (parses? (render-tree t2)))
      (receive (t3 l3) (delete-left t2 l2)        ; the word goes too
        (check "and again empties the line" "" (render-tree t3))
        (check "the document is empty"      '() (tree->sexp t3))
        (receive (t4 l4) (delete-left t3 l3)
          (check "backspace on an empty line does nothing"
                 "" (render-tree t4)))))))

;;; just inside a form that has content: the form goes, not its first word
(receive (t l) (delete-left (sexp->tree '(run (ls -l))) (make-locus '(1) 0 0))
  (check "backspace just after a ( kills that form" '(run) (tree->sexp t))
  (check "and nothing is left unbalanced"           #t (parses? (render-tree t))))

;;; at the end of a form: its last element goes, cursor at the end of what is left
(receive (t l) (delete-left (sexp->tree '(run (ls -l))) (make-locus '(1) 2 0))
  (check "backspace at the end of a form drops the last element"
         "(run (ls))" (render-tree t))
  (check "and rests at the end of the new last element" '((1) 0 2) l))

(receive (t l) (delete-left (sexp->tree '(echo a b)) (make-locus '() 3 0))
  (check "at the end of the line it drops the last word" "(echo a)" (render-tree t)))

;;; ---- no dead keys: there is something to the left, and it goes ---------------

;;; between two elements -- (run |(ls)) -- the character to the left is the "n"
;;; of run, and it goes; the locus comes to rest where that character was
(receive (t l) (delete-left (sexp->tree '(run (ls))) (make-locus '() 1 0))
  (check "backspace between two elements takes the character on its left"
         "(ru (ls))" (render-tree t))
  (check "and leaves the locus at the end of that word" '(() 0 2) l)
  (check "and the tree is still well formed" #t (parses? (render-tree t))))

;;; an empty word is a placeholder, not text: typing "(" leaves one, and the
;;; line can never be emptied until it can be deleted
(receive (t l) (delete-left (list "") (make-locus '() 0 0))
  (check "backspace removes an empty word" '() t)
  (check "and the line is empty"           "" (render-tree t)))

(receive (t l) (delete-left (list "" "ls") (make-locus '() 0 0))
  (check "an empty word at the head of a line goes too" "(ls)" (render-tree t)))

;;; inside a form the placeholder is killed with the form, as before
(receive (t l) (delete-left (list "run" (list "")) (make-locus '(1) 0 0))
  (check "inside a form the empty form goes, not just its word"
         "(run)" (render-tree t)))

;;; ---- SPC splits words (and joins them back, cf. delete-left) ------------------

(receive (t l) (insert-char (sexp->tree '(ls-l)) (make-locus '() 0 2) #\space)
  (check "SPC inside a word splits it" "(ls -l)" (render-tree t))
  (check "SPC split locus"             '(() 1 0) l))

(receive (t l) (insert-char (sexp->tree '(run (ls))) (make-locus '(1) 0 2) #\space)
  (check "SPC at the end of a word opens a new one" "(run (ls ))" (render-tree t))
  (check "SPC new-word locus"                       '((1) 1 0) l))

(check "tree->sexp drops empty words" '(run (ls -l)) (tree->sexp '("run" ("ls" "" "-l"))))

(receive (t l) (insert-char (sexp->tree '(run (ls ""))) (make-locus '(1) 1 0) #\space)
  (check "SPC in an empty word does nothing" "(run (ls ))" (render-tree t)))

;;; ---- "(" goes where the cursor is, splitting a word --------------------------
;;; typing  ' (  must leave the quote in front of the new form

(receive (t l) (insert-form (list "car" "'") (make-locus '() 1 1))
  (check "insert-form splits a word at the cursor" "(car '())" (render-tree t))
  (check "and the quote stays in front"            '(car (quote ())) (tree->sexp t)))

;;; ---- literals and quote prefixes at the read boundary -------------------------

(check "a number leaf reads back as a number"  '(display 5)     (tree->sexp '("display" "5")))
(check "a string leaf reads back as a string"  '(display "hi")  (tree->sexp '("display" "\"hi\"")))
(check "a boolean leaf reads back as a boolean" '(display #t)   (tree->sexp '("display" "#t")))
(check "other literal kinds stay symbols"      '(display #{#\\a}#) (tree->sexp '("display" "#\\a")))
(check "a quote prefix applies to the form after it"
       '(car (quote (1))) (tree->sexp '("car" "'" ("1"))))
(check "and to a word after it"                '(x (quote y))   (tree->sexp '("x" "'" "y")))
(check "a quasiquote too"                      '(x (quasiquote y)) (tree->sexp '("x" "`" "y")))

(check "a bare quote prefix hugs what follows"
       "(car '(1))" (render-tree '("car" "'" ("1"))))

;;; ---- leaving forms, deleting nodes, no-op Tab -------------------------------

(receive (t l) (leave-form (sexp->tree '(run (ls))) (make-locus '(1) 0 0))
  (check "leave-form puts the locus after the form" '(() 2 0) l))

(receive (t l) (delete-node (sexp->tree '(run (ls) (wc))) (make-locus '() 2 0))
  (check "delete-node removes the element" "(run (ls))" (render-tree t)))

(receive (t l) (transpose-node (sexp->tree '(run (ls))) (make-locus '() 0 0))
  (check "Tab at the root is a no-op" "(run (ls))" (render-tree t)))

;;; ---- M-RET: breaks in the tree ----------------------------------------------
;;; A break is an element; the reader never sees it (tree->sexp drops it), it
;;; renders as a newline plus derived indentation, and it moves with the
;;; structure when slurp/barf carry it.

(receive (t l) (insert-break (sexp->tree '(run (ls))) (make-locus '(1) 0 2))
  (check "M-RET at the end of a word puts the break after it"
         #t (and (= 1 (length (filter break? (list-ref t 1)))) #t))
  (check "the cursor starts the new line" '((1) 2 0) l)
  (check "tree->sexp drops the break" '(run (ls)) (tree->sexp t))
  (check "rendered as two lines, indented to the args"
         "(run (ls\n         ))" (render-tree t))
  (receive (t2 l2) (delete-left t l)
    (check "backspace at a line start removes the break" "(run (ls))" (render-tree t2))
    (check "and the words stay where they were" '(run (ls)) (tree->sexp t2))))

(receive (t l) (insert-break (sexp->tree '(run (ls))) (make-locus '(1) 0 1))
  (check "M-RET inside a word splits it -- as the reader would too"
         '(run (l s)) (tree->sexp t))
  (check "and renders the split across the line"
         "(run (l\n        s))" (render-tree t)))

;; a break in a special form's body hangs two past the "("
(receive (t l) (insert-break (sexp->tree '(let ((x 1)) x)) (make-locus '() 2 0))
  (check "a special form's body hangs two"
         "(let ((x 1))\n  x)" (render-tree t)))

;; breaks are ordinary elements: a slurp takes the next sibling, which may be
;; a break -- the structure carries it, as it carries everything
(receive (t l) (insert-break (sexp->tree '(run (ls) (wc))) (make-locus '() 2 0))
  (check "break before (wc)" "(run (ls)\n     (wc))" (render-tree t))
  (receive (t2 l2) (slurp-node t (make-locus '(1) 0 2))
    (check "slurp from inside (ls) takes the break that follows it"
           "(run (ls\n         ) (wc))" (render-tree t2))
    (receive (t3 l3) (transpose-node t2 (make-locus '(1) 0 2))
      (check "and the next slurp takes (wc) after the break"
             "(run (ls\n         (wc)))" (render-tree t3)))))

;; arrows cross a break in both directions: the break has no column of its own,
;; so RIGHT from the end of a line lands at the START of the next one
(receive (t l) (insert-break (sexp->tree '(run (ls) (wc))) (make-locus '() 2 0))
  (check "RIGHT from the end of ls reaches the form's end slot"
         '((1) 1 0) (move-right t (make-locus '(1) 0 2)))
  (check "RIGHT again skips the break to (wc)'s ("
         '((() 2 0)) (list (move-right t (make-locus '(1) 1 0))))
  (check "and LEFT twice returns to the end of ls"
         '((1) 0 2) (move-left t (move-left t (make-locus '() 2 0)))))

;;; ---- verdict ----------------------------------------------------------------

(newline)
(if (null? failures)
    (begin (display "ALL CHECKS PASSED") (newline) (exit 0))
    (begin (display "FAILURES: ") (write failures) (newline) (exit 1)))
