;;; editor/init.scm -- the shell's init file.
;;;
;;; Loaded once on startup, before the first prompt.  Where it lives:
;;;
;;;     $XDG_CONFIG_HOME/scsh/init.scm   when the variable is set
;;;     $HOME/.config/scsh/init.scm      when the variable is not
;;;     $HOME/.scsh                      the old spelling, when the one above
;;;                                      is not there
;;;
;;; (With the variable set but its file missing, ~/.scsh is still consulted --
;;; the variable relocates the config, it does not delete the old one.)  The
;;; file is plain Scheme, loaded the way guile loads any Scheme file -- with
;;; load, so it is compiled and cached, and define-module inside it behaves
;;; as it would anywhere.  An error stops the init where it happened and is
;;; reported; the shell starts anyway.

(define-module (structured-scsh init)
  #:declarative? #f            ; load-init loads user files at run time
  #:export (init-path load-init))

(define (first-existing paths)
  (cond ((null? paths) #f)
        ((not (car paths)) (first-existing (cdr paths)))
        ((file-exists? (car paths)) (car paths))
        (else (first-existing (cdr paths)))))

(define (init-path)
  (let ((xdg (getenv "XDG_CONFIG_HOME"))
        (home (getenv "HOME")))
    (if xdg
        (first-existing (list (string-append xdg "/scsh/init.scm")
                              (and home (string-append home "/.scsh"))))
        (first-existing (list (and home
                                   (string-append home "/.config/scsh/init.scm"))
                              (and home (string-append home "/.scsh")))))))

(define (load-init)
  (let ((path (init-path)))
    (when path
      (catch #t
        (lambda () (load path))
        (lambda (key . args)
          (display "error: init file ") (display path)
          (display ": ") (display key) (display " ") (display args) (newline))))))
