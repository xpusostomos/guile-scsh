;;; editor/engine.scm -- the structure editor's model.
;;;
;;; The document is a TREE, never text:
;;;
;;;     tree    ::= (element ...)     a NODE is a list of elements
;;;     element ::= string            a SYMBOL leaf (its characters)
;;;               | (element ...)     a NODE
;;;
;;; Text is only ever PRODUCED, by the renderer; it is never parsed back in and
;;; never edited as characters.  There are exactly two kinds of edit:
;;;
;;;   ATOM   edit -- type or backspace characters inside the current symbol.
;;;   STRUCT edit -- everything else operates on nodes: insert a form, leave a
;;;                  form, regroup with Tab, delete a node, move the locus.
;;;
;;; The cursor is a LOCUS (container-path index offset):
;;;
;;;   container-path : indices selecting a node; () is the root
;;;   index          : 0..len of that node; len is the empty position at the end
;;;   offset         : character offset within a symbol leaf (0 otherwise)
;;;
;;; Balanced parentheses are not an invariant we check -- they are not
;;; representable: a node simply IS a node.  Only the renderer knows about
;;; parentheses at all.

(define-module (structured-scsh engine)
  #:use-module (ice-9 receive)
  #:export (make-locus locus-path locus-index locus-offset
            node? sym? element?
            container-at with-container splice list-replace remove-at list-head! tree-copy
            insert-char insert-char* delete-left
            insert-form leave-form delete-node transpose-node delete-right
            insert-break break? wrap-begin
            slurp-node barf-node can-slurp? can-barf? regroup target-form-path
            move-left move-right move-home move-end move-up move-down
            focus-child focus-after
            sexp->tree tree->sexp))

;;; ---- small list helpers ---------------------------------------------------

(define (butlast lst)
  (if (null? lst) '() (reverse (cdr (reverse lst)))))

(define (last lst)
  (if (null? lst) #f (car (reverse lst))))

;;; These three are DESTRUCTIVE: they mutate the list they are handed and return
;;; it.  A cons cell is therefore never copied, so where a cell sits in the
;;; structure is stable across edits -- which is what anything hung off a cell
;;; (a rendering, or eventually a break marker) depends on.  See TREE-PLAN.md.
;;;
;;; They behave exactly as the copying versions did, errors included (verified
;;; over every index of lists up to length 4, valid and invalid): the same calls
;;; succeed and return equal lists, and the same calls raise.
;;;
;;; The price is the standing rule: an op mutates its input, so a caller must
;;; not hold a tree it is going to edit.  The places that must copy are listed
;;; in TREE-PLAN.md §6.3 -- today, history recall (history-previous).
;;;
;;; Only index 0 needs a fresh cons: the head cons IS the list, so a replacement
;;; there sets its car and an insertion returns a new head.
(define (list-replace lst i v)
  (set-car! (list-tail lst i) v)
  lst)

(define (splice lst i v)
  (if (= i 0)
      (cons v lst)
      (begin (set-cdr! (list-tail lst (- i 1)) (cons v (list-tail lst i)))
             lst)))

(define (remove-at lst i)
  (if (= i 0)
      (cdr lst)
      (begin (set-cdr! (list-tail lst (- i 1)) (list-tail lst (+ i 1)))
             lst)))

;;; append! needs no definition here: it is a core binding (Guile's destructive
;;; append), visible in every module.  It is NOT listed in this module's
;;; #:export -- exporting an imported (or core) name makes it an unbound binding
;;; in the module, which is exactly how it first looked "undefined" here.

;;; the destructive LIST-HEAD: keep exactly the first N conses, cutting the cdr
;;; at depth N-1 rather than allocating.  Every surviving cons stays where it is.
;;; N < 1 has no destructive form (the head cons IS the list), so it yields '().
;;;
;;; It DESTROYS the tail: take `(list-tail lst n)` BEFORE calling it, or the tail
;;; is gone -- and mind that APPEND! evaluates its arguments left to right, so an
;;; inline tail is read after the cut.  Verified a drop-in for list-head over
;;; every N of lists up to length 4, errors included.
(define (list-head! lst n)
  (if (< n 1)
      '()
      (let lp ((l lst) (k (- n 1)))
        (cond ((null? l) (error "list-head!: out of bounds" n))
              ((= k 0) (set-cdr! l '()) lst)
              (else (lp (cdr l) (- k 1)))))))

;;; a tree deep enough to edit without touching the original: the cons cells are
;;; new, and the leaves are shared (words are strings, and immutable).  %BREAK%
;;; is kept by identity -- a copy of it would no longer be break?.
;;;
;;; History hands out its stored trees, so it copies on the way out; see
;;; editor/history.scm.
(define (tree-copy t)
  (cond ((break? t) t)
        ((pair? t) (cons (tree-copy (car t)) (tree-copy (cdr t))))
        (else t)))

;;; ---- elements and loci ----------------------------------------------------

(define (node? x) (list? x))
(define (sym? x) (string? x))
(define (element? x) (or (node? x) (sym? x)))

;;; A line break, as its own element of a container: it renders as a newline
;;; and indentation, and TREE->SEXP drops it, because to Scheme a break is only
;;; whitespace -- the expression is unchanged.  It is an IMPROPER pair on
;;; purpose: not a string (a word), not a proper list (a form), so no editor
;;; operation can mistake it for either; and a unique object, so nothing the
;;; user types can ever be one -- the only way one comes to exist is M-RET.
;;; Breaks are ELEMENTS, so slurp/barf carry them along when they restructure.
(define %break% (cons 'break 'break))
(define (break? x) (eq? x %break%))

;;; M-RET: a break where the cursor is.  Inside a word the word splits there
;;; (the reader would read the two halves as two symbols too); at an end of
;;; word, on a "(", or in an empty slot the break goes at the cursor's index,
;;; before whatever is there.  The cursor comes to rest at the START of the new
;;; line -- just after the break.
(define (insert-break tree locus)
  (if (null? tree)                        ; an empty line has nothing to break
      (values tree locus)
      (let ((path (locus-path locus))
            (i (locus-index locus))
            (off (locus-offset locus)))
        (let ((cont (container-at tree path)))
          (cond
            ;; inside a word: split it, the break between the halves
            ((and (< i (length cont)) (sym? (list-ref cont i)) (> off 0)
                  (< off (string-length (list-ref cont i))))
             (let* ((el (list-ref cont i))
                    (left (substring el 0 off))
                    (right (substring el off)))
               ;; the tail is hoisted BEFORE the cut: list-head! truncates cont,
               ;; and append! reads its arguments left to right
               (let ((tail (list-tail cont (+ i 1))))
                 (values (with-container tree path
                                         (append! (list-head! cont i)
                                                  (list left %break% right)
                                                  tail))
                         (make-locus path (+ i 2) 0)))))
            ;; at the end of a word: the break goes after it
            ((and (< i (length cont)) (sym? (list-ref cont i))
                  (= off (string-length (list-ref cont i))))
             (values (with-container tree path (splice cont (+ i 1) %break%))
                     (make-locus path (+ i 2) 0)))
            ;; on a form, at a word's start, in an empty word, or at the end
            ;; slot: the break goes at the cursor's index
            (else (values (with-container tree path (splice cont i %break%))
                          (make-locus path (+ i 1) 0))))))))

(define (make-locus path index offset) (list path index offset))
(define (locus-path l) (car l))
(define (locus-index l) (cadr l))
(define (locus-offset l) (caddr l))

;;; the node addressed by PATH (a list of indices); () is the whole document
(define (container-at tree path)
  (if (null? path)
      tree
      (let ((sub (list-ref tree (car path))))
        (if (null? (cdr path))
            sub
            (container-at sub (cdr path))))))

;;; rebuild TREE with the node at PATH replaced by NEW
(define (with-container tree path new)
  (if (null? path)
      new
      (let ((i (car path))
            (sub (list-ref tree (car path))))
        (list-replace tree i
                      (if (null? (cdr path))
                          new
                          (with-container sub (cdr path) new))))))

;;; ---- ATOM edit: characters inside the current symbol ----------------------

;;; SPC splits words instead of living inside them: at the end of a symbol it
;;; opens a new one beside it; inside a symbol it cuts it in two ("ls-l" ->
;;; "ls" "-l").  This is the inverse of the join in DELETE-LEFT, and it is what
;;; makes a typed line say what a shell line says.
(define (insert-space tree locus)
  (let ((path (locus-path locus))
        (i (locus-index locus))
        (off (locus-offset locus)))
    (let ((cont (container-at tree path)))
      (if (and (< i (length cont)) (sym? (list-ref cont i)))
          (let* ((el (list-ref cont i))
                 (n (string-length el)))
            (cond ((and (= off n) (not (string=? el "")))
                   ;; at the end of a word: a new word after it
                   (values (with-container tree path (splice cont (+ i 1) ""))
                           (make-locus path (+ i 1) 0)))
                  ((= off n) (values tree locus))   ; already in an empty word
                  ((> off 0)                    ; inside: cut the word in two
                   (let ((left  (substring el 0 off))
                         (right (substring el off)))
                     (values (with-container tree path
                                             (list-replace (splice cont (+ i 1) right) i left))
                             (make-locus path (+ i 1) 0))))
                  (else (values tree locus))))  ; at the start: nothing to do
          ;; beside a form or at an empty position: a new word here
          (values (with-container tree path (splice cont i ""))
                  (make-locus path i 0))))))

(define (insert-char tree locus ch)
  (if (char=? ch #\space)
      (insert-space tree locus)
      (insert-char* tree locus ch)))

(define (insert-char* tree locus ch)
  (let ((path (locus-path locus))
        (i (locus-index locus))
        (off (locus-offset locus)))
    (let ((cont (container-at tree path))
          (c (string ch)))
      (if (< i (length cont))
          (let ((el (list-ref cont i)))
            (if (sym? el)
                ;; extend the symbol at the locus
                (values (with-container tree path
                                        (list-replace cont i
                                                      (string-append (substring el 0 off)
                                                                     c
                                                                     (substring el off))))
                        (make-locus path i (+ off 1)))
                ;; the locus is on a node: a new symbol starts in front of it
                (values (with-container tree path (splice cont i c))
                        (make-locus path i 1))))
          ;; the locus is the empty position at the end of this node
          (values (with-container tree path (append! cont (list c)))
                  (make-locus path i 1))))))

;;; Backspace: delete the character to the left; at the start of a symbol,
;;; join with the symbol to the left (the inverse of the future SPC split).
;;;
;;; There is no "(" to delete -- the tree has no paren characters, only forms --
;;; so backspace just inside a form kills the form itself.  That is what lets
;;; you walk a line back out: typing "l" gives (run (l)), and backspace takes it
;;; to (run ()), then to (run), then to nothing at all.  Each step leaves a
;;; well-formed tree, which is the whole point of editing structure.
;;;
;;; Two positions must not be dead keys, though, because there is something to
;;; the left of them and the user means it to go:
;;;
;;;   * between two elements, (run |(ls)) -- the character to the left is the
;;;     "n" of run, so it goes, and the locus comes to rest where it was;
;;;   * on an empty word, which is a placeholder rather than text -- typing "("
;;;     leaves one (a form with nowhere to put the cursor yet), and until it can
;;;     be deleted the line can never be emptied.
;;;
;;; The order is the order of what the user sees: a character first, then the
;;; word boundary, then the form's own parens, then the placeholder.
(define (delete-left tree locus)
  (let ((path (locus-path locus))
        (i (locus-index locus))
        (off (locus-offset locus)))
    (let ((cont (container-at tree path)))
      (cond
        ;; a character in a word
        ((and (< i (length cont)) (sym? (list-ref cont i)) (> off 0))
         (let ((el (list-ref cont i)))
           (values (with-container tree path
                                   (list-replace cont i
                                                 (string-append (substring el 0 (- off 1))
                                                                (substring el off))))
                   (make-locus path i (- off 1)))))
        ;; at the start of a word with a word before it: join the two
        ((and (< i (length cont)) (sym? (list-ref cont i)) (= off 0) (> i 0)
              (sym? (list-ref cont (- i 1))))
         (let* ((prev (list-ref cont (- i 1)))
                (el (list-ref cont i))
                (joined (string-append prev el))
                (cont* (list-replace (remove-at cont i) (- i 1) joined)))
           (values (with-container tree path cont*)
                   (make-locus path (- i 1) (string-length prev)))))
        ;; just inside a form -- right after its "(" -- or at the start of its
        ;; first element: the form itself goes
        ((and (= i 0) (= off 0) (not (null? path)))
         (let ((ppath (butlast path))
               (ci    (last path)))
           (values (with-container tree ppath (remove-at (container-at tree ppath) ci))
                   (make-locus ppath ci 0))))
        ;; at the end of a node: its last element goes, and the locus comes to
        ;; rest at the end of what is now the last one -- so backspace keeps
        ;; eating leftwards, as it does in a text editor
        ((and (= i (length cont)) (> i 0))
         (let* ((cont* (remove-at cont (- i 1)))
                (k     (- (length cont*) 1)))
           (values (with-container tree path cont*)
                   (make-locus path (max k 0)
                               (if (and (>= k 0) (sym? (list-ref cont* k)))
                                   (string-length (list-ref cont* k))
                                   0)))))
        ;; between two elements, with a word on the left: that word's last
        ;; character goes, and the locus joins the word where the character was
        ;; (the same deletion the join above performs, without the join)
        ((and (> i 0) (= off 0) (< i (length cont)) (not (sym? (list-ref cont i)))
              (sym? (list-ref cont (- i 1))))
         (let* ((j    (- i 1))
                (prev (list-ref cont j))
                (n    (string-length prev)))
           (values (with-container tree path
                                   (list-replace cont j (substring prev 0 (- n 1))))
                   (make-locus path j (- n 1)))))
        ;; at a line start: the break to the left goes -- deleting a newline
        ;; joins the lines (the words stay separate, as they were left)
        ((and (= off 0) (> i 0) (break? (list-ref cont (- i 1))))
         (values (with-container tree path (remove-at cont (- i 1)))
                 (make-locus path (- i 1) 0)))
        ;; an empty word: a placeholder the cursor is sitting in, not text --
        ;; it goes, so that a line can always be emptied
        ((and (< i (length cont)) (sym? (list-ref cont i)) (= off 0)
              (string=? (list-ref cont i) ""))
         (values (with-container tree path (remove-at cont i))
                 (make-locus path i 0)))
        (else (values tree locus))))))

;;; ---- STRUCT edit: nodes ---------------------------------------------------

;;; "(" -- open a new form at the locus and step inside it.  Inside a word the
;;; word is split at the cursor first, so the form lands exactly where the
;;; cursor is: typing  ' (  must not push the quote past the new form.
(define (insert-form tree locus)
  (let* ((path (locus-path locus))
         (i    (locus-index locus))
         (off  (locus-offset locus))
         (cont (container-at tree path)))
    (if (and (< i (length cont)) (sym? (list-ref cont i)) (> off 0))
        (let* ((el (list-ref cont i))
               (left  (substring el 0 off))
               (right (substring el off))
               ;; the word to the left stays, the new form follows, and the
               ;; word's remainder (if any) follows that
               (inserted (if (string=? right "") (list left '()) (list left '() right))))
          (let ((tail (list-tail cont (+ i 1))))
            (values (with-container tree path
                                    (append! (list-head! cont i) inserted tail))
                    (make-locus (append path (list (+ i 1))) 0 0))))
        (if (and (< i (length cont)) (sym? (list-ref cont i))
                 (string=? (list-ref cont i) ""))
            ;; an empty word is only where the cursor was sitting: the new form
            ;; takes its place (otherwise "& ( wc )" leaves a stray gap)
            (values (with-container tree path (list-replace cont i '()))
                    (make-locus (append path (list i)) 0 0))
            (values (with-container tree path (splice cont i '()))
                    (make-locus (append path (list i)) 0 0))))))

;;; ")" -- leave the current form; the locus comes to rest after it
(define (leave-form tree locus)
  (let ((path (locus-path locus)))
    (if (null? path)
        (values tree locus)
        (values tree (make-locus (butlast path) (+ (last path) 1) 0)))))

;;; delete the element at the locus, whole
(define (delete-node tree locus)
  (let ((path (locus-path locus))
        (i (locus-index locus)))
    (let ((cont (container-at tree path)))
      (if (< i (length cont))
          (values (with-container tree path (remove-at cont i))
                  (make-locus path i 0))
          (values tree locus)))))

;;; movement
(define (focus-child locus j)
  (make-locus (append (locus-path locus) (list j)) 0 0))

(define (focus-after locus)
  (make-locus (locus-path locus) (+ (locus-index locus) 1) 0))

;;; Tab -- regroup.  The form containing the locus either takes in its next
;;; sibling (slurp) or gives up its last child to stand after it (barf).  The
;;; two alternate, so Tab cycles between groupings; and nothing is ever moved
;;; into or out of a string, so no state it can reach is malformed.
;;;
;;; THE CURSOR DOES NOT MOVE.  Everything Tab does happens to the RIGHT of it,
;;; so the locus keeps its index and its offset and stays exactly where it was --
;;; which is what lets Tab be pressed again to cycle back to the other grouping.
;;; A cursor that wandered would be regrouping a different form on the next Tab,
;;; and you would never see the same two options twice.
;;;
;;; THE ONE ADJUSTMENT is at the right edge, where the slot means "just before
;;; the )": when the form GROWS (slurp), that slot follows the ")" to the new
;;; end -- staying at the old index would land it on the "(" of the element just
;;; slurped in, and the next Tab would then target that element instead of the
;;; form, breaking the cycle.  When the form SHRINKS past the cursor (barf), it
;;; is clamped to the new end.  Anything strictly left of the edge is unmoved.
(define (regroup-locus path old-n new-n locus)
  (let ((i (locus-index locus)))
    (cond ((= i old-n)   (make-locus path new-n 0))   ; the ) moved right
          ((>= i new-n)  (make-locus path new-n 0))   ; clamped at the new edge
          (else locus))))

;;; The form an action at LOCUS targets.  The cursor sits ON a "(" exactly when
;;; the element at its index is a form -- the rendered column is that "(" -- and
;;; then THAT form is the target: "if I'm on a (, that is the form".  Otherwise
;;; -- inside a word, after one, at a form's end slot -- the target is the form
;;; containing the locus: "after a ( but before the next (, the one before is
;;; the form".  Bold and Tab both go by this; nothing else needs to.
(define (target-form-path tree locus)
  (and locus
       (let* ((path (locus-path locus))
              (i    (locus-index locus))
              (cont (container-at tree path)))
         (if (and (< i (length cont)) (node? (list-ref cont i)))
             (append path (list i))
             path))))

;;; The two moves separately, so that the loop can choose between them: SLURP
;;; takes the next sibling in, BARF sends the last child out.  Each takes the
;;; TARGET form (see TARGET-FORM-PATH) and is a no-op when it does not apply.
(define (slurp-node tree locus)
  (let* ((fpath  (target-form-path tree locus))
         (ppath  (butlast fpath))
         (ci     (last fpath))
         (parent (container-at tree ppath))
         (me     (list-ref parent ci))
         (next   (list-ref parent (+ ci 1)))
         ;; the OLD length must be read before the append!: me* IS me, mutated
         (old-n  (length me))
         (me*    (append! me (list next)))    ; the element moves, its cons comes along
         (parent* (list-replace (remove-at parent (+ ci 1)) ci me*)))
    (values (with-container tree ppath parent*)
            (kept-locus fpath old-n (length me*) locus))))

(define (barf-node tree locus)
  (let* ((fpath  (target-form-path tree locus))
         (ppath  (butlast fpath))
         (ci     (last fpath))
         (parent (container-at tree ppath))
         (me     (list-ref parent ci))
         ;; likewise read before the cut: me* IS me, cut one child shorter
         (old-n  (length me))
         (child  (last me))
         (me*    (list-head! me (- old-n 1)))    ; destructive: the form loses its last child
         (parent* (list-replace (splice parent (+ ci 1) child) ci me*)))
    (values (with-container tree ppath parent*)
            (kept-locus fpath old-n (length me*) locus))))

;;; Can the target form do it?  Nothing at the root: the line has no sibling to
;;; take in and no parent to give a child to.
(define (can-slurp? tree locus)
  (let ((fpath (target-form-path tree locus)))
    (and fpath (not (null? fpath))
         (let* ((ppath  (butlast fpath))
                (ci     (last fpath))
                (parent (container-at tree ppath)))
           (< (+ ci 1) (length parent))))))

(define (can-barf? tree locus)
  (let ((fpath (target-form-path tree locus)))
    (and fpath (not (null? fpath))
         (pair? (list-ref (container-at tree (butlast fpath)) (last fpath))))))

;;; TAB MOVES THE BOUNDARY OF THE FORM THE CURSOR IS IN, one way or the other,
;;; and keeps going that way until it runs out of room -- then it turns round.
;;; Pressing it repeatedly therefore walks through every grouping of that form
;;; and comes back round to the one it started in.
;;;
;;; It has to be told which way it went last, because SLURP and BARF are exact
;;; inverses: choosing by looking at the tree alone can only ever toggle the
;;; last two groupings, which is what "stuck going back and forth" was.
(define (regroup tree locus direction)
  (let ((first  (if (eq? direction 'barf) barf-node slurp-node))
        (first? (if (eq? direction 'barf) can-barf? can-slurp?))
        (other  (if (eq? direction 'barf) slurp-node barf-node))
        (other? (if (eq? direction 'barf) can-slurp? can-barf?)))
    (cond ((first? tree locus)
           (receive (t l) (first tree locus) (values t l direction)))
          ((other? tree locus)                  ; the end of the road: turn round
           (receive (t l) (other tree locus)
             (values t l (if (eq? direction 'barf) 'slurp 'barf))))
          (else (values tree locus direction)))))

;;; Where the cursor belongs after the move.  Inside the form it stays on its
;;; character, clamped at the form's edge (REGROUP-LOCUS); ON the form's "(" it
;;; does not move at all: both moves leave the form where it was in its parent,
;;; so the locus -- which is a place in the parent -- is still on that "(".
(define (kept-locus fpath old-n new-n locus)
  (if (equal? (locus-path locus) fpath)
      (regroup-locus fpath old-n new-n locus)
      locus))

;;; the plain either-way move, for callers that do not need to cycle
(define (transpose-node tree locus)
  (cond ((can-slurp? tree locus) (slurp-node tree locus))
        ((can-barf? tree locus)  (barf-node tree locus))
        (else (values tree locus))))            ; the root: nothing to regroup

;;; ; -- wrap the line's form in (begin ...), the way a Scheme toplevel groups
;;; expressions.  The begin body is a second toplevel: whatever works at the
;;; prompt works inside it.  At the very beginning of the line the cursor stays
;;; BEFORE the old form (on its paren); anywhere else it comes to rest at the
;;; end of the old form, at the begin's toplevel, ready to type the next
;;; expression.  A second ; wraps again, as it must -- the tree is the truth.
(define (wrap-begin tree locus)
  (if (null? tree)
      (values tree locus)                   ; an empty line: nothing to wrap
      (let ((start? (and (null? (locus-path locus))
                         (zero? (locus-index locus))
                         (zero? (locus-offset locus)))))
        (values (list "begin" tree)
                (if start?
                    (make-locus '() 1 0)    ; before the old form
                    (make-locus '() 2 0)))))) ; the begin's toplevel, after it

;;; ---- movement ---------------------------------------------------------------
;;; LEFT/RIGHT walk character by character through symbols and element by
;;; element through nodes, stepping into forms and popping back out of them.
;;; HOME/END go to the ends of the current element, UP to the containing form,
;;; DOWN into the focused form.

;;; Moving left steps onto the character before the cursor; when there is none
;;; -- at the start of a word or a form -- it steps into whatever is to the
;;; left: the end of the word there, or the END of the form there, which is the
;;; only place leftwards of the form's ")" can mean.  (Stepping to the form's
;;; start would jump the cursor over the whole form, which is what it looked
;;; like it was doing.)  Left and right are then exact opposites: entering a
;;; form goes in at its start going right, and at its end going left.
(define (move-left tree locus)
  (let ((path (locus-path locus)) (i (locus-index locus)) (off (locus-offset locus)))
    (let ((cont (container-at tree path)))
      (cond
        ((> off 0) (make-locus path i (- off 1)))
        ((= i 0)
         (if (null? path)
             locus
             (make-locus (butlast path) (last path) 0)))
        (else
         (let ((prev (list-ref cont (- i 1))))
           (cond
             ((break? prev)
              ;; the cursor was at a line start: it goes to the END of the
              ;; previous line, at the end of the element before the break
              (let lp ((j (- i 2)))
                (cond
                  ((and (>= j 0) (break? (list-ref cont j))) (lp (- j 1)))
                  ((>= j 0)
                   (let ((e (list-ref cont j)))
                     (if (sym? e)
                         (make-locus path j (string-length e))
                         (make-locus (append path (list j)) (length e) 0))))
                  (else
                   (if (null? path)
                       locus
                       (make-locus (butlast path) (last path) 0))))))
             ((sym? prev) (make-locus path (- i 1) (string-length prev)))
             ((null? prev) (make-locus path (- i 1) 0))
             (else (make-locus (append path (list (- i 1))) (length prev) 0)))))))))


(define (move-right tree locus)
  (let* ((path (locus-path locus)) (i (locus-index locus)) (off (locus-offset locus))
         (cont (container-at tree path))
         (n (length cont)))
    (cond ((and (< i n) (sym? (list-ref cont i))
                (< off (string-length (list-ref cont i))))
           (make-locus path i (+ off 1)))
          ;; a form is entered at its start going right -- an empty one too,
          ;; since "just after its (" is a place like any other, and it is where
          ;; a fresh command form begins
          ((and (< i n) (node? (list-ref cont i)))
           (make-locus (append path (list i)) 0 0))
          ;; the cursor is ON a break: it steps past it, to the start of the
          ;; next line -- or to the end slot, if the break is the last thing
          ((and (< i n) (break? (list-ref cont i)))
           (let lp ((j (+ i 1)))
             (if (and (< j n) (break? (list-ref cont j))) (lp (+ j 1))
                 (make-locus path j 0))))
          ((< (+ i 1) n)
           ;; the next element may itself be a break: step over those too
           (let lp ((j (+ i 1)))
             (if (and (< j n) (break? (list-ref cont j))) (lp (+ j 1))
                 (make-locus path j 0))))
          ;; past the last character of the last element, the only place to go
          ;; is the slot before the ")" -- from where RIGHT leaves the form
          ((= i (- n 1)) (make-locus path n 0))
          ((null? path) locus)
          (else (make-locus (butlast path) (+ (last path) 1) 0)))))

(define (move-home tree locus)
  (make-locus (locus-path locus) (locus-index locus) 0))

(define (move-end tree locus)
  (let ((path (locus-path locus)) (i (locus-index locus)))
    (let ((cont (container-at tree path)))
      (if (and (< i (length cont)) (sym? (list-ref cont i)))
          (make-locus path i (string-length (list-ref cont i)))
          (make-locus path (+ i 1) 0)))))

(define (move-up tree locus)
  (let ((path (locus-path locus)))
    (if (null? path)
        locus
        (make-locus (butlast path) (last path) 0))))

(define (move-down tree locus)
  (let* ((path (locus-path locus)) (i (locus-index locus))
         (cont (container-at tree path)))
    (if (and (< i (length cont)) (node? (list-ref cont i)))
        (make-locus (append path (list i)) 0 0)
        locus)))

;;; delete the character to the right, or join with the next symbol
(define (delete-right tree locus)
  (let ((path (locus-path locus)) (i (locus-index locus)) (off (locus-offset locus)))
    (let ((cont (container-at tree path)))
      (cond
        ((and (< i (length cont)) (sym? (list-ref cont i))
              (< off (string-length (list-ref cont i))))
         (let ((el (list-ref cont i)))
           (values (with-container tree path
                                   (list-replace cont i
                                                 (string-append (substring el 0 off)
                                                                (substring el (+ off 1)))))
                   (make-locus path i off))))
        ((and (< i (length cont)) (sym? (list-ref cont i))
              (= off (string-length (list-ref cont i)))
              (< (+ i 1) (length cont)) (sym? (list-ref cont (+ i 1))))
         (let* ((el (list-ref cont i))
                (nx (list-ref cont (+ i 1)))
                (joined (string-append el nx)))
           (values (with-container tree path
                                   (list-replace (remove-at cont (+ i 1)) i joined))
                   (make-locus path i off))))
        ;; a break ahead: it goes, and the cursor is where it was
        ((and (< i (length cont)) (break? (list-ref cont i)))
         (values (with-container tree path (remove-at cont i))
                 (make-locus path i 0)))
        (else (values tree locus))))))

;;; ---- the boundary with the outside world ---------------------------------
;;; Text enters the editor in exactly two places: a file/paste import, and the
;;; Enter-line fallback.  Both use Guile's own reader; these convert between
;;; what it returns and our tree.  No parser lives here.

;;; A leaf becomes Scheme data here, and Guile's reader does the reading --
;;; there is no parser of our own:
;;;
;;;   * a leaf that reads as a NUMBER, STRING or BOOLEAN becomes that literal
;;;     ("5" -> 5, "\"hi\"" -> "hi", "#t" -> #t).  Anything else stays a symbol,
;;;     including other literal kinds (characters, vectors) for now -- which
;;;     also keeps shell arguments -- ordinary words and integers -- safe.
;;;   * a leaf that is a quote prefix ("'", "`", ",", ",@") applies to the
;;;     element after it, so a quote typed in front of a form means what it
;;;     looks like it means.
(define *prefix-readers*
  '(("'" . quote) ("`" . quasiquote) ("," . unquote) (",@" . unquote-splicing)))

;;; Writing ",x" in one go leaves ONE word -- there is no space to split it, and
;;; nothing structural to break it -- so a word has to be able to carry its
;;; prefix too, and read as the same thing as the comma and the name typed
;;; apart.  This matters beyond the prompt: scsh interpolates such a reference
;;; inside a process form, so (run (echo ,x)) has to hand scsh (unquote x).
(define (word-prefix s)
  (let ((n (string-length s)))
    (cond ((and (> n 1) (char=? #\, (string-ref s 0)) (char=? #\@ (string-ref s 1)))
           (cons 'unquote-splicing (substring s 2)))
          ((and (> n 1) (char=? #\, (string-ref s 0)))
           (cons 'unquote (substring s 1)))
          (else #f))))

(define (leaf->datum s)
  (let ((p (word-prefix s)))
    (if p
        (list (car p) (leaf->datum (cdr p)))
        (leaf-plain-datum s))))

(define (leaf-plain-datum s)
  (let ((d (catch #t
                  (lambda ()
                    (let ((p (open-input-string s)))
                      (let ((x (read p)))
                        (and (eof-object? (peek-char p)) x))))
                  (lambda args #f))))
    (cond ((or (number? d) (string? d) (boolean? d)) d)
          (else (string->symbol s)))))

(define (element->sexp e)
  (cond ((string? e) (leaf->datum e))
        ;; a marker-headed form ("," x) nested inside another form IS the
        ;; marker expression -- ,x / ,@x -- its datum is the fused form with
        ;; no line wrapper (the line's own tree->sexp adds that wrapper,
        ;; which is what line-datum unwraps)
        ((and (pair? e) (string? (car e)) (assoc (car e) *prefix-readers*)
              (pair? (cdr e)) (null? (cddr e)))
         (list (cdr (assoc (car e) *prefix-readers*))
               (element->sexp (cadr e))))
        (else (tree->sexp e))))

(define (sexp->tree x)
  (cond ((null? x) '())
        ((pair? x) (map sexp->tree x))
        ((symbol? x) (symbol->string x))
        ;; a string datum spells itself WITH its quotes: the tree's word is
        ;; what the reader reads back, and a bare word reads as a symbol --
        ;; dropping the quotes turned (display "hi") into (display hi).  The
        ;; one exception is the empty string, which IS the tree's empty-word
        ;; placeholder -- the dangling word the cursor sits in.
        ((string? x) (if (string-null? x) x (object->string x)))
        ((number? x) (number->string x))
        (else (object->string x))))

(define (tree->sexp t)
  ;; breaks are whitespace to the reader: they do not reach Scheme at all
  (let lp ((els (filter (lambda (e)
                          (and (not (break? e))
                               (not (and (string? e) (string=? e "")))))
                        t))
           (out '()))
    (cond ((null? els) (reverse out))
          ((and (assoc (car els) *prefix-readers*) (pair? (cdr els)))
           (lp (cddr els)
               (cons (list (cdr (assoc (car els) *prefix-readers*))
                           (element->sexp (cadr els)))
                     out)))
          (else (lp (cdr els) (cons (element->sexp (car els)) out))))))
