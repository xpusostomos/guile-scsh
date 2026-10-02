;;; editor/history.scm -- the line history, in memory and in ~/.scsh_history.
;;;
;;; The FILE format is the user's: each entry is one READABLE datum beginning
;;; in the first column, either "(" (ending with its own closing ")") or ","
;;; -- so the Scheme reader is the parser, and a multi-line entry (one with a
;;; break) simply spans lines, since breaks are only whitespace to the reader.
;;; Entries are written after each execution, oldest first; loading replaces
;;; the in-memory list at startup.
;;;
;;; Recall: UP walks to the previous item, DOWN to the next.  Leaving the line
;;; for the first time saves it as the DRAFT; DOWN past the newest item comes
;;; back to the draft, as in bash.  An index points into the items, one past
;;; the last meaning "at the draft".

(define-module (editor history)
  #:use-module (ice-9 receive)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)   ; string-contains
  #:use-module (editor engine)
  #:use-module (editor render)
  #:use-module (editor properties)
  #:export (history-load! history-add! history-file history-previous history-next
            history-reset! history-items history-clear! history-search datum->tree
            match-span))

;;; the newest index <= FROM whose rendered line contains QUERY -- the backward
;;; search C-r walks; #f when nothing matches.  Inclusive of FROM, so narrowing
;;; keeps the current match while it still matches.
(define (history-search query from)
  (let ((i (min from (- (length *items*) 1)))
        ;; 'completion-ignore-case #t in the property list makes the match
        ;; case-insensitive, readline's variable of the same name
        (contains (if (scsh-property 'completion-ignore-case)
                      string-contains-ci
                      string-contains)))
    (let lp ((i i))
      (cond ((< i 0) #f)
            ((contains (render-tree (list-ref *items* i)) query) i)
            (else (lp (- i 1)))))))

;;; where QUERY sits in MATCH -- the span C-r's frame highlights, under the
;;; same case rule the search itself follows; #f when the query is empty or
;;; the match is not a line.  Both editors' search frames use this, so the
;;; highlight and the search can never disagree.
(define (match-span query match)
  (if (and (string? match) (positive? (string-length query)))
      (let ((find (if (scsh-property 'completion-ignore-case)
                      string-contains-ci
                      string-contains)))
        (let ((i (find match query)))
          (and i (cons i (+ i (string-length query))))))
      #f))

(define *items* '())          ; trees, oldest first
(define *pos* 0)              ; an index into *items*; the length = the draft
(define *draft* #f)           ; (tree . locus), saved on the first UP

(define *file* 'unset)        ; a test can point this elsewhere -- or #f, for none

;;; the history file: $HOME/.scsh_history by default; a set #f means the
;;; history stays in memory ONLY (no load, no save).  The sentinel keeps an
;;; explicit #f from falling through to the default: (history-file #f) must
;;; really mean "no file", or a test's add! would write the user's own file.
(define (history-file . maybe-new)
  (if (null? maybe-new)
      (if (eq? *file* 'unset)
          (let ((home (getenv "HOME")))
            (and home (string-append home "/.scsh_history")))
          *file*)
      (begin (set! *file* (car maybe-new)) *file*)))

;;; a loaded datum becomes a tree.  The comma cases are special: ",x" reads as
;;; (unquote x), and the tree wants the comma WORD in front of the item --
;;; ("," "x") and ("," (+ ...)) render as ",x" and ",(+ 1 2)" exactly as typed.
(define (datum->tree d)
  (cond ((and (pair? d) (assq (car d) '((unquote . ",") (unquote-splicing . ",@"))))
         (list (cdr (assq (car d) '((unquote . ",") (unquote-splicing . ",@"))))
               (sexp->tree (cadr d))))
        ;; a ! line: the value is the verbatim command string, spelled bare --
        ;; (! "ls -l") is the tree ("!" "ls -l"), rendering "!ls -l"
        ((and (pair? d) (eq? (car d) '!) (pair? (cdr d)) (null? (cddr d))
              (string? (cadr d)))
         (list "!" (cadr d)))
        (else (sexp->tree d))))

;;; read the file, one datum per entry.  A read ERROR (hand-edited junk) stops
;;; the load there: whatever parsed is kept, and nothing is ever overwritten --
;;; saving only ever appends.
(define (history-load!)
  (let ((path (history-file)))
    (when (and path (file-exists? path))
      (call-with-input-file path
        (lambda (p)
          (let lp ((acc (quote ())))
            (let ((d (catch #t
                       (lambda () (read p))
                       (lambda args (quote junk)))))
              (cond ((eq? d (quote junk)) (lp acc))
                    ((eof-object? d) (set! *items* (reverse acc)))
                    (else
                     ;; a READABLE datum can still be an unusable TREE: a bare
                     ;; "." word reads as dotted-pair syntax.  Such entries are
                     ;; skipped, never fatal -- the shell must always start.
                     (let ((t (catch #t
                                (lambda () (datum->tree d))
                                (lambda args (quote junk)))))
                       (if (eq? t (quote junk))
                           (lp acc)
                           (lp (cons t acc)))))))))))
    (history-reset!)))
(define (history-add! tree)
  (set! *items* (append *items* (list tree)))
  (history-reset!)
  (let ((path (history-file)))
    (when path
      (let ((p (open-file path "a")))
        ;; the entry is the READABLE datum, not the screen text: the screen
        ;; shows the word "." as a bare dot, which the reader would take for
        ;; dotted-pair syntax; guile's write renders the symbol as #{.}#,
        ;; which reads back as the same symbol.  Breaks never reach the
        ;; datum, so they were lost on the round trip anyway.
        ;; A value line spells itself WITH its marker -- ,car -- which is
        ;; how the file format defines it: writing the datum gave
        ;; ((unquote car)) (guile's write does not sugar unquote), which
        ;; loaded back as the wrong tree.
        (cond ((and (pair? tree) (pair? (cdr tree)) (null? (cddr tree))
                    (string? (car tree))
                    (or (string=? (car tree) ",") (string=? (car tree) ",@")))
               (display (car tree) p)
               (write (cadr (car (tree->sexp tree))) p)
               (newline p))
              ;; a ! line: the readable datum (! "ls -l") -- never Scheme
              ((and (pair? tree) (pair? (cdr tree)) (null? (cddr tree))
                    (string? (car tree)) (string=? (car tree) "!"))
               (write (list '! (cadr tree)) p)
               (newline p))
              (else
               (write (tree->sexp tree) p)
               (newline p)))
        (close-port p))))
  tree)

;;; a fresh line: recall starts at the newest, and the draft is gone
(define (history-reset!)
  (set! *pos* (length *items*))
  (set! *draft* #f))

(define (history-items) *items*)

;;; forget everything, in memory only -- a test's clean table
(define (history-clear!)
  (set! *items* '())
  (history-reset!))

;;; UP: the previous item.  At the oldest, nothing moves.
(define (history-previous tree locus)
  (if (zero? *pos*)
      (values tree locus)
      (begin
        (when (= *pos* (length *items*))
          (set! *draft* (cons tree locus)))
        (set! *pos* (- *pos* 1))
        (let ((t (list-ref *items* *pos*)))
          (values t (make-locus '() (length t) 0))))))

;;; DOWN: the next item; past the newest, the draft comes back.
(define (history-next tree locus)
  (if (= *pos* (length *items*))
      (values tree locus)                  ; already at the draft
      (begin
        (set! *pos* (+ *pos* 1))
        (cond ((= *pos* (length *items*))
               (if *draft*
                   (values (car *draft*) (cdr *draft*))
                   (values '() (make-locus '() 0 0))))
              (else
               (let ((t (list-ref *items* *pos*)))
                 (values t (make-locus '() (length t) 0))))))))
