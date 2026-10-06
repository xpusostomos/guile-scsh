;;; script/glob1.scm -- glob, the shell's way, for scripts and for the editor.
;;;
;;; Everything in this directory is usable from a SCRIPT as well as from the
;;; interactive editor: nothing here may import the editor's machinery (engine,
;;; render, repl, term, job, history, textline).  The dependency runs one way --
;;; the editor may use these, these may not use the editor.

(define-module (scsh glob1)
  #:use-module (scsh glob)
  #:export (glob1))

;;; glob1 -- glob one or more patterns, and FAIL if nothing matched at all.
;;;
;;; Like glob, glob1 is a macro with an implicit quasiquote, so patterns can be
;;; written unquoted, shell-style: (glob1 *.c) -- glob* stringifies the symbols.
;;; There are no modifiers and no properties: the policy is the one a shell
;;; user expects, and there is only one of it.  A pattern that matches nothing
;;; simply contributes nothing; the error is raised only when EVERY pattern
;;; came back empty, so (glob1 *.c *.h) still succeeds with only the .c files
;;; present.
(define (glob1* patterns)
  (let loop ((ps patterns) (out '()))
    (cond ((null? ps)
           (if (null? out)
               (error "No match" patterns)
               out))
          (else (loop (cdr ps) (append out (glob* (car ps))))))))

(define-syntax glob1
  (syntax-rules ()
    ((_ rest ...) (glob1* `(rest ...)))))
