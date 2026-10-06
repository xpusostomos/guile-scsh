;;; structured-scsh/properties.scm -- the shell's user-settable properties.
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

(define-module (structured-scsh properties)
  #:export (scsh-properties scsh-property scsh-property-set! scsh-prompt
            bourne-shell))

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

;;; (scsh-prompt #:text) -- the REPL prompt, from the 'prompt property.  A
;;; lambda is CALLED, fresh each line, with #:TEXT saying which structured-scsh is
;;; asking: #f structured, #t the unstructured line editor.  A string is the
;;; prompt in both modes.  Unset (or any other type) defaults to "scsh$ " in
;;; structured mode and "scsh> " in text mode.  A lambda that does not take
;;; the keyword (an older (lambda () ...)) is called without it.
(define* (scsh-prompt #:key text)
  (let ((p (scsh-property 'prompt)))
    (cond ((procedure? p)
           (catch 'wrong-number-of-args
             (lambda () (p #:text text))
             (lambda args (p))))
          ((string? p) p)
          (else (if text "scsh> " "scsh$ ")))))

;;; (bourne-shell) -- the shell a ! line goes to: the 'bourne-shell property
;;; when it is a string, else /bin/bash when it exists, else /bin/sh (which
;;; presumably always exists).
(define (bourne-shell)
  (let ((p (scsh-property 'bourne-shell)))
    (cond ((string? p) p)
          ((file-exists? "/bin/bash") "/bin/bash")
          (else "/bin/sh"))))
