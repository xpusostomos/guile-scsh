;;; script/prelude.scm -- what a scsh USER has: the modules a shell line, or a
;;; script, may refer to without importing anything.
;;;
;;;   a script     guile -l script/prelude.scm ... FILE      (bin/scsh does this)
;;;   the shell    bin/scsh loads it before calling (main)
;;;
;;; It must be a SCRIPT FRAGMENT and not a module.  Both of those loads happen
;;; in (guile-user) -- which is the module a line is EVALUATED in and the module
;;; a script RUNS in -- so the use-modules below have to land in (guile-user).
;;; Wrapped in a define-module they would land in a module of their own and the
;;; user would see none of them.
;;;
;;; NOTHING from (structured-scsh ...) belongs here.  The interactive machinery is not
;;; part of running a script, and importing it would drag the whole editor into
;;; every script's startup.

(use-modules (scsh syntax))        ; run, &, ||, &&, exec-epf, run/string, ...
(use-modules (scsh scsh))          ; with-cwd, call/fdes, fork, ...
(use-modules (scsh procobj))       ; wait, proc:pid, ...
(use-modules (scsh run-extras))    ; run/collecting*
(use-modules (scsh glob))          ; glob
(use-modules (scsh glob1))       ; glob1 -- the shell's glob
