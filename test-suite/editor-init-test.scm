;;; editor-init-test.scm -- the init file: where it lives, what it can do.
;;;
;;;   make -C test-suite init
;;;
;;; A temp HOME and a temp XDG_CONFIG_HOME stand in for the real ones: every
;;; candidate path the shell looks at is built under them.

(use-modules (editor init) (editor properties) (srfi srfi-1))

(define failures '())
(define (check label expect got)
  (if (equal? expect got)
      (display (string-append "ok   " label "\n"))
      (begin (set! failures (cons label failures))
             (display (string-append "FAIL " label "\n  expect "))
             (write expect) (newline)
             (display "  got    ") (write got) (newline))))

(define tmp (string-append "/tmp/scsh-init-test-" (number->string (getpid))))
(define xdg (string-append tmp "/xdg"))
(define home (string-append tmp "/home"))

;; a clean slate: no XDG, a HOME with nothing in it
(setenv "XDG_CONFIG_HOME" #f)
(setenv "HOME" home)

(check "no candidates: no init file"
       #f (init-path))

;; the old spelling alone
(mkdir tmp #o755)
(mkdir home #o755)
(let ((p (open-file (string-append home "/.scsh") "w")))
  (display "(scsh-property-set! 'from-old-spelling 1)" p)
  (close-port p))
(check "HOME/.scsh is the last candidate"
       (string-append home "/.scsh") (init-path))

;; the XDG spelling, var unset
(mkdir (string-append home "/.config") #o755)
(mkdir (string-append home "/.config/scsh") #o755)
(let ((p (open-file (string-append home "/.config/scsh/init.scm") "w")))
  (display "(scsh-property-set! 'from-xdg-default 2)" p)
  (close-port p))
(check "HOME/.config/scsh/init.scm comes before .scsh"
       (string-append home "/.config/scsh/init.scm") (init-path))

;; the variable set: its file, and only its file, comes first
(mkdir xdg #o755)
(mkdir (string-append xdg "/scsh") #o755)
(let ((p (open-file (string-append xdg "/scsh/init.scm") "w")))
  (display "(scsh-property-set! 'from-xdg-var 3)" p)
  (close-port p))
(setenv "XDG_CONFIG_HOME" xdg)
(check "XDG_CONFIG_HOME/scsh/init.scm wins when the variable is set"
       (string-append xdg "/scsh/init.scm") (init-path))

;; the variable set but its file missing: the old spelling still applies
(delete-file (string-append xdg "/scsh/init.scm"))
(check "the variable relocates the config; ~/.scsh still applies"
       (string-append home "/.scsh") (init-path))

;;; ---- what load-init does ------------------------------------------------------

;; a clean init: its forms load, as Scheme, with load's own semantics
(scsh-property-set! 'from-old-spelling #f)
(let ((p (open-file (string-append home "/.scsh") "w")))
  (display "(scsh-property-set! 'from-old-spelling 1)" p) (newline p)
  (display "(define init-define 7)" p) (newline p)
  (close-port p))
(load-init)
(check "load-init ran the properties"
       1 (scsh-property 'from-old-spelling))
(check "defines land in the environment lines evaluate in"
       7 (eval 'init-define (interaction-environment)))

;; an error stops the init where it happened -- reported, and the shell
;; starts anyway -- the semantics any Scheme file has
(scsh-property-set! 'from-old-spelling #f)
(let ((p (open-file (string-append home "/.scsh") "w")))
  (display "(no-such-form-in-init 1 2 3)" p) (newline p)
  (display "(scsh-property-set! 'from-old-spelling 1)" p) (newline p)
  (close-port p))
(check "an erroring init aborts at the error, shell unharmed"
       #f (begin (catch #t (lambda () (load-init)) (lambda args 'caught)) #f))
(check "  and nothing after the error loaded"
       #f (scsh-property 'from-old-spelling))

;;; ---- verdict ------------------------------------------------------------------

(unless (null? failures)
  (for-each (lambda (f) (display (string-append "FAILED: " f "\n"))) (reverse failures))
  (exit 1))
(display "all init checks pass\n")