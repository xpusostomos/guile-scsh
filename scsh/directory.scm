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
  #:use-module (ice-9 receive)
  #:use-module (ice-9 optargs)
  #:use-module (ice-9 ftw)                ; scandir
  #:use-module (scsh utilities)            ; check-arg
  #:use-module (scsh let-optionals-aster)  ; let-optionals*
  #:use-module (scsh fname)                ; ensure-file-name-is-nondirectory
  #:export (directory-files))

;;; (directory-files [dir dotfiles?]) -> list of strings
;;;
;;; scsh's procedure -- and SRFI-170's, which is the same one: that SRFI was
;;; written from scsh's system-call documentation by its original author.  Bare
;;; names, with no directory prefix; "." and ".." are never returned, whatever
;;; DOTFILES? says; other dot files come back only when it is true.
;;;
;;; The work is scandir's: it reads the directory, closes it, and sorts by the
;;; comparator it is handed.  What is left here is the policy -- which entries,
;;; and in what order.
(define (directory-files . args)
  (let-optionals* args ((dir ".") (dotfiles? #f))
    (check-arg string? dir directory-files)
    (or (scandir (ensure-file-name-is-nondirectory dir)
                 (lambda (f) (and (not (member f '("." "..")))
                                  (or dotfiles? (not (dotfile? f)))))
                 filename<?)
        ;; scandir answers #f for a name it cannot read; scsh raises, and the
        ;; documented result is a list of strings, never #f
        (error "directory-files: cannot read directory" dir))))

;;; A dot file is one whose name begins with a dot.  ("." and ".." are dot
;;; files too, but directory-files never returns them.)
(define (dotfile? f)
  (char=? #\. (string-ref f 0)))

;;; The Unix filename order: dot files first, then the rest, each group by
;;; string<?.  This is what makes DOTFILES? mean anything -- under plain
;;; string<? they would merely be interleaved by ASCII, "." falling after "-"
;;; and before "Z".
;;;
;;; Upstream calls this filename<= and compares with string<=, which suits
;;; sort-list!; scandir wants a strict ordering, hence string<? and the name.
(define (filename<? f1 f2)
  (cond ((dotfile? f1) (if (dotfile? f2) (string<? f1 f2) #t))
        ((dotfile? f2) #f)
        (else (string<? f1 f2))))