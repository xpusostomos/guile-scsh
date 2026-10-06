;;; structured-scsh/render.scm -- tree -> text, and where the cursor lands.
;;;
;;; This is the ONLY place text is produced.  The canonical form is:
;;;
;;;     a node prints as "(" elements separated by single spaces ")"
;;;     an empty node prints as "()"
;;;     a symbol prints as its characters
;;;     a break element prints as a newline plus indentation
;;;     a line that begins with a comma word prints bare (it names a value)
;;;
;;; so the text is tidy by construction -- there is no such thing as a
;;; mis-spaced or unbalanced line to repair.  The locus is marked during the
;;; walk and turned into a row and 0-based column for the terminal.
;;;
;;; The renderer is written as two PURE passes -- build a list of pieces, then
;;; fold them into text -- because the previous version's nested defines
;;; mutating shared let* bindings segfaulted Guile 3.0.11 (both compiled and
;;; interpreted, on a form whose first element is a form).  No closures over
;;; mutable state anywhere now; note the fold is O(n^2) in string building,
;;; which is fine at line lengths.

(define-module (structured-scsh render)
  #:use-module (ice-9 receive)
  #:use-module (srfi srfi-13)
  #:use-module (structured-scsh engine)
  #:export (render render-tree pieces))

;; A bare quote prefix hugs what follows it: '(1 2), not ' (1 2).
(define prefix-strings (list "'" "`" "," ",@" "!"))

(define (prefix-element? e)
  (and (string? e) (member e prefix-strings)))

;; A word may carry its prefix -- ",x" is written in one go -- and such a word
;; standing at the head of a line is not a form: the line names a value, so it
;; is drawn bare, ",x" rather than "(,x)".  A line headed by ! is the same
;; bargain in reverse: it names a shell command, so it is drawn bare too.
(define (prefixed-word? e)
  (and (string? e) (> (string-length e) 0)
       (or (char=? #\, (string-ref e 0))
           (char=? #\! (string-ref e 0)))))

;; the form's first word, if any -- its name decides the indentation rule
(define (first-word node)
  (let find ((els node))
    (cond ((null? els) #f)
          ((or (break? (car els)) (equal? (car els) "")) (find (cdr els)))
          ((string? (car els)) (car els))
          (else #f))))

;;; ---- pass 1: the tree as a flat list of pieces -----------------------------
;;; A piece is one of
;;;   (word S)                     a word's text (a word may be split by the cursor)
;;;   (space)                      the space between elements
;;;   (open PATH) / (close PATH)   the parens of the form at PATH
;;;   (break HEAD WORDS BARE?)     a line break; HEAD/WORDS/BARE? of its form
;;;   (cursor)                     where the locus is (no width)

(define (pieces tree locus)
  (define (here? path i)
    (and locus (equal? path (locus-path locus)) (= i (locus-index locus))))
  (let walk ((node tree) (path '()))
    ;; the root's index-0 slot renders ON the line's "(": there is no locus
    ;; outside the line, so that one position is "on the (" as well as "before
    ;; the first element" -- the same edit either way.  A just-opened EMPTY
    ;; form is the exception: between its parens is the whole point.
    (define (edge-cursor?)
      (and locus (null? path) (pair? node)
           (zero? (locus-index locus)) (zero? (locus-offset locus))
           (not (equal? (car node) ""))))
    (define (skip-root-cursor? i)
      (and (zero? i) (edge-cursor?)))
    ;; a form whose first word carries a marker prefix is the marker
    ;; expression itself -- the comma value line, a nested ,@ splice -- and
    ;; is drawn bare: its datum is what the marker fuses to
    (let* ((bare? (and (pair? node) (prefixed-word? (car node))))
           (head (first-word node))
           (n (length node)))
      (let lp ((i 0) (words 0)
               (acc (cond (bare? '())
                          ((edge-cursor?) (list (list 'open path) '(cursor)))   ; acc is reverse-final
                          (else (list (list 'open path))))))
        (if (= i n)
            (append (reverse acc)
                    ;; the end position of this node, just before its ")"
                    (if (here? path n) '((cursor)) '())
                    (if bare? '() (list (list 'close path))))
            (let* ((el (list-ref node i))
                   (prev (if (zero? i) #f (list-ref node (- i 1))))
                   (sp (if (and (> i 0)
                                (not (break? el))         ; a line needs no space
                                (not (break? prev))
                                (not (prefix-element? prev)))
                           '((space)) '()))
                   (els
                     (cond ((break? el) (list (list 'break head words bare?)))
                           ((string? el)
                            (if (and (here? path i) (not (skip-root-cursor? i)))
                                (list (list 'word (substring el 0 (locus-offset locus)))
                                      '(cursor)
                                      (list 'word (substring el (locus-offset locus))))
                                (list (list 'word el))))
                           (else
                            (append (if (and (here? path i) (not (skip-root-cursor? i)))
                                        '((cursor))
                                        '())
                                    (walk el (append path (list i))))))))
              (lp (+ i 1)
                  (if (break? el) words (+ words 1))
                  (append (reverse (append sp els)) acc))))))))

;;; ---- indentation -----------------------------------------------------------
;;; Derived per break, never stored: a SPECIAL form's body hangs two past the
;;; form's "("; anything else aligns to the form's first argument.  These are
;;; Scheme's usuals; ENCLOSE is the visible column of the "(" they hang from.
(define %scheme-specials%
  ;; words, not symbols: the head of a form is a string
  '("define" "define*" "define-record-type" "define-syntax" "lambda"
    "let" "let*" "letrec" "letrec*" "if" "when" "unless" "begin" "do" "do*"
    "cond" "case" "and" "or" "set!" "receive" "delay"))

(define (indent-for enclose head words bare?)
  (cond ((or bare? (not head)) (+ enclose 2))
        ((and (member head %scheme-specials%) (>= words 1))
         (+ enclose 2))                                 ; the body hangs
        (else (+ enclose 1 (string-length head) 1))))   ; under the args

;;; ---- pass 2: fold the pieces into text -------------------------------------
;;; Tracks, along the way: TEXT, the cursor's row and visible column, and the
;;; bold spans (the parens of the form the locus is on or in).  The cursor
;;; marker itself is remembered, not written.  Newlines and indent spaces count
;;; in the text offsets (bold spans index into the final text) but only indent
;;; spaces count as columns.
(define (fold-pieces tree locus ps)
  (let ((bpath (target-form-path tree locus)))
    (let lp ((ps ps) (text "") (col 0) (row 0) (tpos 0) (bold '())
             (stack '())                     ; visible cols of the open parens
             (cur-col 0) (cur-row 0))
      (if (null? ps)
          (values text cur-col cur-row (reverse bold))
          (let ((p (car ps)))
            (cond
              ((eq? (car p) 'word)
               (lp (cdr ps)
                   (string-append text (cadr p))
                   (+ col (string-length (cadr p)))
                   row
                   (+ tpos (string-length (cadr p)))
                   bold stack cur-col cur-row))
              ((eq? (car p) 'space)
               (lp (cdr ps) (string-append text " ") (+ col 1) row (+ tpos 1)
                   bold stack cur-col cur-row))
              ((eq? (car p) 'open)
               (lp (cdr ps)
                   (string-append text "(")
                   (+ col 1) row (+ tpos 1)
                   (if (equal? (cadr p) bpath)
                       (cons (cons tpos (+ tpos 1)) bold)
                       bold)
                   (cons col stack) cur-col cur-row))
              ((eq? (car p) 'close)
               (lp (cdr ps)
                   (string-append text ")")
                   (+ col 1) row (+ tpos 1)
                   (if (equal? (cadr p) bpath)
                       (cons (cons tpos (+ tpos 1)) bold)
                       bold)
                   (cdr stack) cur-col cur-row))
              ((eq? (car p) 'break)
               (let* ((enclose (if (null? stack) 0 (car stack)))
                      (n (indent-for enclose (cadr p) (caddr p) (cadddr p))))
                 (lp (cdr ps)
                     (string-append text "\n" (make-string n #\space))
                     n (+ row 1) (+ tpos 1 n)
                     bold stack cur-col cur-row)))
              ((eq? (car p) 'cursor)
               (lp (cdr ps) text col row tpos bold stack col row))
              (else (lp (cdr ps) text col row tpos bold stack cur-col cur-row))))))))

;;; (render TREE LOCUS) -> (values TEXT COL ROW BOLD);  LOCUS may be #f for none.
;;; BOLD is a list of (START . END) offsets into TEXT: the parens of the form
;;; the locus is on or in -- exactly two characters, so that the form you are in
;;; is always obvious.  Style is derived here exactly as the text is -- the
;;; tree stays the truth, and the terminal layer is the only thing that knows
;;; how to draw it.
(define (render tree locus)
  (if (null? tree)
      (values "" 0 0 '())
      (fold-pieces tree locus (pieces tree locus))))

;;; just the text
(define (render-tree tree)
  (call-with-values (lambda () (render tree #f))
    (lambda (text col row bold) text)))
