#!/usr/bin/guile -L .
!#
;;; editor/run.scm -- the structure editor, run as an scsh REPL.
;;;
;;;   ./bin/scsh                  (the usual way -- see bin/scsh)
;;;   ./editor/run.scm            (or:  guile -L . editor/run.scm)
;;;
;;; Every keystroke is structural: the tree is the truth, the line you see is
;;; its rendering, and Enter evaluates the tree.  A line starts EMPTY; the
;;; first word typed opens (run ()) for you, so "ls -l" becomes (run (ls -l)).
;;; That seeding is the shell's policy, not the editor's -- the editor has no
;;; notion of "run" at all.

(use-modules (ice-9 receive))
(use-modules (editor engine) (editor render) (editor repl) (editor scsh)
             (editor job) (editor term) (editor history) (editor properties)
             (editor textline))
(use-modules (scsh syntax) (scsh scsh) (scsh procobj) (scsh run-extras) (scsh glob))

;;; the prompt is the 'prompt property, re-read before every line -- a string
;;; as it stands, a lambda called fresh each time with #:TEXT saying which
;;; editor is asking, "scsh$ " structured and "scsh> " in text mode when unset
;;; (scsh-prompt lives in editor/properties.scm)

;;; THE KEY TABLE -- one dispatch mechanism for the whole shell: escape first
;;; (it switches to the unstructured editor, whatever is on the line), then
;;; the shell's policy rows (|, >, & -- each declines off a shell line or away
;;; from a form's end), then the editor's structural and control rows, then
;;; the printer, which always handles.  It is passed through the whole
;;; machinery, so a program using the editor can supply its own instead.
(define escape-rule
  (rule (lambda (k) (eq? k 'escape))
        (lambda (t l k) (values t l 'text #t))))
(define key-table (cons escape-rule (append shell-rules core-rules)))

;;; which editor the next line opens in.  ESC switches, for the line being
;;; typed and every line after, until it is pressed again: the structured
;;; tree editor (the default) and the unstructured text editor
;;; (editor/textline.scm) take turns, and the half-typed line crosses over.
(define *text-editing?* #f)

;;; a fresh line is EMPTY.  The first word typed opens (run ()) with the locus
;;; inside the command form -- a shell line begins with a command, so that is
;;; what the shell seeds; the editor itself knows nothing of (run ...).
(define (fresh)
  (values '() (make-locus '() 0 0)))

;;; one line, in whichever editor is current, ESC switching mid-line: the
;;; line crosses over half-typed, a tree into text (its rendering) and text
;;; back into a tree (the guesser).  Returns (values tree action) with action
;;; one of evaluate / continue / exit / interrupt.
(define (edit-one tree locus)
  (if *text-editing?*
      (receive (text action)
          (text-line #:prompt (scsh-prompt #:text #t)
                     #:initial (render-tree tree))
        (cond ((eq? action 'structured)
               (set! *text-editing?* #f)
               (let ((t (text-carry-tree text)))
                 (edit-one t (make-locus '() (length t) 0))))
              ((eq? action 'evaluate)
               (values (text-commit-tree text) 'evaluate))
              ((eq? action 'interrupt) (values '() 'interrupt))
              (else (values '() 'exit))))
      (receive (t l action)
          (edit-line tree locus #:prompt (scsh-prompt)
                     #:seed seed #:rules key-table)
        (cond ((eq? action 'text)
               (set! *text-editing?* #t)
               (edit-one t l))
              (else (values t action))))))

;;; Enter: the tree is the truth, so committing it is just running it -- and
;;; because the line is a shell line, job control has its say here.  `run` is a
;;; foreground job: the terminal is pointed at it while the job is still parked,
;;; then it is released on a sane terminal, and the editor takes the terminal
;;; back afterwards.  `&` is a background job: released without the terminal, so
;;; a job that reads it is stopped by the kernel (SIGTTIN) -- bash's behaviour.
;;; With job control off, both go through scsh's own run/& as before.
(define (commit tree)
  (let ((x (line-datum (tree->sexp tree))))
    (if (and (job-control?) (pair? x) (memv (car x) '(run &)))
        (let ((job (job-start (lambda ()
                                (eval (cons 'exec-epf (cdr x))
                                      (interaction-environment)))
                              (render-tree tree))))
          (if (eq? (car x) 'run)
              (let ((status (call-with-cooked-terminal
                             (lambda () (job-foreground! job)))))
                (when (job-stopped-status? status)      ; ^Z, or SIGTTIN at start
                  (jobs-add! job)
                  (job-announce! job))
                ;; as in bash, a foreground command that finishes says nothing:
                ;; printing its status would trail a "0" after every command
                *unspecified*)
              (begin (jobs-add! job)
                     (job-background! job)
                     (job-launched! job)                ; bash-style "[1] 12345"
                     (if #f #f))))
        (eval x (interaction-environment)))))

(define *unspecified* (if #f #f))

;;; a result prints the REPL way: numbered, like the plain guile REPL's
;;; $1 = value -- a procedure named car shows as $1 = #<procedure car ...>
(define *value-n* 0)
(define (print-value v)
  (set! *value-n* (+ *value-n* 1))
  (display "$") (display *value-n*) (display " = ")
  (write v)
  (newline))

;;; Before each prompt, see how the jobs are doing: that is where a background
;;; job's "Done" or "Stopped" is noticed and reported.
(define (main)
  (history-load!)                     ; the previous session's lines come back
  (ignore-terminal-stop!)             ; we point the terminal at jobs and back
  (call-with-restored-terminal        ; and we never leave it raw, however we go
   (lambda ()
     (let loop ()
       (job-poll-all!)
       (history-reset!)               ; a fresh line: recall starts at the newest
       (receive (tree locus) (fresh)
         (receive (done action) (edit-one tree locus)
           (cond
             ((eq? action 'interrupt) (loop))     ; ^C in text mode: a fresh line
             ((not (eq? action 'evaluate)) (display "bye") (newline)) ; EOF, ^C
             ((null? done) (loop))                    ; a blank line: nothing to run
             (else
              (catch #t
                     (lambda ()
                       (let ((v (commit done)))
                         (unless (eq? v *unspecified*) (print-value v))))
                     (lambda (key . args)
                       (if (eq? key 'quit)                ; (quit) ends the shell
                           (begin (display "bye") (newline) (exit 0))
                           (begin (display "error: ") (display key) (display " ")
                                  (display args) (newline)))))
              (history-add! done)     ; after each execution, the line is history
              (loop)))))))))

(main)