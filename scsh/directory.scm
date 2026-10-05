;;; Copyright (c) 1994 by Olin Shivers. See file COPYING.
;;;
;;; Directory stuff: reading a directory's entries.
;;;
;;; This module exists because of a CYCLE.  directory-files needs fname's
;;; ensure-file-name-is-nondirectory, and fname needs syscalls for the user-info
;;; procedures its "~user" expansion calls.  Upstream scsh keeps directory-files
;;; in a module of its own (scheme/directory.scm), which is one-way: directory
;;; uses fname, and fname uses nothing from here.  This port had merged it into
;;; syscalls, which made syscalls use fname -- and so made the two modules
;;; import each other.  In a cycle one side's bindings never arrive, and the
;;; compiler said so:
;;;
;;;   scsh/syscalls.scm:842:32: warning: possibly unbound variable
;;;                            `ensure-file-name-is-nondirectory'
;;;
;;; It was right: (directory-files "/tmp") raised Unbound variable at run time,
;;; because *every* fname name was unbound inside syscalls, not just that one.
;;; Restoring upstream's split removes the cycle.

(define-module (scsh directory)
  :use-module (ice-9 receive)
  :use-module (ice-9 optargs)
  :use-module (scsh utilities)            ; check-arg
  :use-module (scsh let-optionals-aster)  ; let-optionals*
  :use-module (scsh fname)                ; ensure-file-name-is-nondirectory
  :export (directory-files))

;;; (directory-files [dir dotfiles?]) -> list of strings
;;;
;;; The entries of DIR, sorted in Unix filename order, with "." and ".." always
;;; dropped and other dot files dropped unless DOTFILES? is true.
(define (directory-files . args)
  (let-optionals* args ((dir ".")
		       (dotfiles? #f))
		 (check-arg string? dir directory-files)
		 (let ((dport (opendir
			       (ensure-file-name-is-nondirectory dir))))
		   (let loop ((result '()))
		     (let ((entry (readdir dport)))
		       (cond ((eof-object? entry)
			      (closedir dport)
			      (sort! result string<?))
			     ((or (and (not dotfiles?)
				       (char=? #\. (string-ref entry 0)))
				  (string=? "." entry)
				  (string=? ".." entry))
			      (loop result))
			     (else
			      (loop (cons entry result)))))))))