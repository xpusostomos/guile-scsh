#!/usr/bin/guile -L . --
!#
;;; A tiny tour of guile-scsh.
;;; Run it from the top of the source tree:  guile -L . examples/demo.scm

(use-modules (scsh syntax))        ; run, |, >, <<, & ...
(use-modules (scsh scsh))          ; with-cwd, fork, ...
(use-modules (scsh procobj))       ; wait
(use-modules (scsh run-extras))    ; run/collecting*
(use-modules (scsh glob))          ; glob
(use-modules (ice-9 receive))      ; receive
(use-modules (ice-9 textual-ports)) ; get-string-all

(define (section title)
  (newline)
  (display "== ") (display title) (newline))

;;; 1. Run a program. RUN returns the exit status, and the child inherits
;;;    our stdin/stdout/stderr, so its output appears inline.

(section "run: exit status")
(display "status = ") (display (run (true))) (newline)
(display "status = ") (display (run (false))) (newline)

;;; 2. Capture the output instead of letting it through.

(section "run/string and run/strings")
(display (run/string (echo hello from a subprocess)))
(display (run/strings (ls -1 scsh)))

;;; 3. Process forms nest, and | builds a pipeline. && and || are ordinary
;;;    Scheme forms that wrap RUN, so they sit *outside* the process form;
;;;    they return #t/#f rather than a status, and short-circuit.

(section "pipeline, && and ||")
(display (run/string (| (ls -1 scsh) (wc -l))))
(display (&& (true) (echo and-continues)))
(newline)
(display (&& (false) (echo never-runs)))
(newline)
(display (|| (false) (echo or-recovers)))
(newline)

;;; 4. Redirection uses the familiar shell syntax. (<  >  >>  <<  =).
;;;    (= 1 (current-output-port)) wires the child's stdout to a Scheme port.

(section "redirection")
(run (echo written to a file) (> /tmp/guile-scsh-demo.txt))
(display (call-with-input-file "/tmp/guile-scsh-demo.txt" get-string-all))
(run (cat) (<< "fed from a Scheme string\n"))
(run (echo captured into a Scheme port) (= 1 (current-output-port)))
(delete-file "/tmp/guile-scsh-demo.txt")

;;; 5. Arguments are implicitly backquoted, so unquote to splice in values
;;;    computed at run time.

(section "unquoting and globbing")
(let ((file "USAGE"))
  (display (run/string (head -1 ,file))))
(display (length (glob "scsh/*.scm")))
(display " .scm files in scsh/\n")

;;; 6. & forks in the background and hands back a process object; wait reaps it.

(section "background")
(let ((p (& (sleep 1))))
  (display "started ") (display p) (newline)
  (display "reaped, status = ") (display (wait p)) (newline))

;;; 7. with-cwd and friends temporarily change process state.

(section "with-cwd")
(display (run/string (pwd)))
(display (with-cwd "/tmp" (run/string (pwd))))

;;; 8. Feed several file descriptors into Scheme ports at once.

(section "run/collecting")
(receive (status out err)
         (run/collecting (1 2) (sh -c "echo to-stdout; echo to-stderr 1>&2"))
  (display "status = ") (display status) (newline)
  (display "out: ") (display (get-string-all out))
  (display "err: ") (display (get-string-all err)))
