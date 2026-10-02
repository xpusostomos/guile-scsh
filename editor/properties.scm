;;; editor/properties.scm -- the shell's user-settable properties.
;;;
;;; One global alist of (SYMBOL . VALUE) pairs, with a getter and a setter.
;;; This is a LEAF module: anything may import it, because it imports nothing
;;; -- putting the properties in (editor scsh) instead would make a cycle
;;; (scsh -> repl -> history -> scsh).  Case-insensitive history search, e.g.
;;; (scsh-property-set! 'completion-ignore-case #t), reads its switch here.
;;;
;;; THE ALIST VARIABLE IS PRIVATE, and (scsh-properties) is its getter --
;;; the same shape as job-control? in (editor scsh).  Guile's compiled
;;; modules fold reads of an IMPORTED rebindable variable to the value it had
;;; when the .go was loaded, so any consumer that read the bare alist would
;;; see it forever empty; through a procedure the read is live.

(define-module (editor properties)
  #:export (scsh-properties scsh-property scsh-property-set! scsh-prompt))

;;; the alist, most recent property first
(define *scsh-properties* '())

;;; (scsh-properties) -- the whole alist.
(define (scsh-properties) *scsh-properties*)

;;; (scsh-property 'SYM) -- the value, or #f when unset.  Unset reads as #f,
;;; which is what an unset boolean switch means anyway.
(define (scsh-property sym)
  (cond ((assq sym *scsh-properties*) => cdr)
        (else #f)))

;;; (scsh-property-set! 'SYM VALUE) -- set, or replace if already there.
(define (scsh-property-set! sym value)
  (let ((cell (assq sym *scsh-properties*)))
    (if cell
        (set-cdr! cell value)
        (set! *scsh-properties* (cons (cons sym value) *scsh-properties*))))
  value)

;;; (scsh-prompt) -- the REPL prompt, from the 'prompt property: a string is
;;; the prompt as it stands, a lambda is called for its string (fresh each
;;; line, so the prompt can show the time or the cwd), and anything else --
;;; the property unset -- is the default it has always been.
(define (scsh-prompt)
  (let ((p (scsh-property 'prompt)))
    (cond ((string? p) p)
          ((procedure? p) (p))
          (else "scsh> "))))
