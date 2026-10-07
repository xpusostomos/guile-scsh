;;; structured-scsh/main.scm -- the shell itself: the structure editor, run as
;;; an scsh REPL.
;;;
;;;   bin/scsh                    (the usual way -- see bin/scsh)
;;;
;;; Every keystroke is structural: the tree is the truth, the line you see is
;;; its rendering, and Enter evaluates the tree.  A line starts EMPTY; the
;;; first word typed opens (run ()) for you, so "ls -l" becomes (run (ls -l)).
;;; That seeding is the shell's policy, not the editor's -- the editor has no
;;; notion of "run" at all.
;;;
;;; This is a MODULE, not a script: bin/scsh imports it and calls (main).  It
;;; lives outside editor/ because it is the program the editor's modules are
;;; for, not one of them -- and being a module means it is compiled into the
;;; site ccache like everything else, instead of being compiled afresh into
;;; each user's cache the first time they run the shell.
;;;
;;; What a user's LINE may refer to is not set here: a line is evaluated in
;;; (guile-user), which bin/scsh fills from script/prelude.scm.  The scsh
;;; modules below are imported for THIS module's own sake -- exec-epf and what
;;; it expands into.

(define-module (structured-scsh main)
  #:use-module (ice-9 receive)
  #:use-module (structured-scsh engine)
  #:use-module (structured-scsh render)
  #:use-module (structured-scsh complete)
  #:use-module (structured-scsh repl)
  #:use-module (structured-scsh scsh)
  #:use-module (structured-scsh job)
  #:use-module (structured-scsh term)
  #:use-module (structured-scsh history)
  #:use-module (structured-scsh properties)
  #:use-module (structured-scsh textline)
  #:use-module (structured-scsh init)
  #:use-module (scsh syntax)
  #:use-module (scsh scsh)
  #:use-module (scsh procobj)
  #:use-module (scsh run-extras)
  #:use-module (scsh glob)
  #:export (main))

;;; THE KEY TABLE -- one dispatch mechanism for the whole shell: escape first
;;; (it switches to the unstructured editor whatever is on the line), then
;;; the shell's policy rows (|, >, & -- each declines off a shell line or away
;;; from a form's end), then the editor's structural and control rows, then
;;; the printer, which always handles.  It is passed through the whole
;;; machinery, so a program using the editor can supply its own instead.
;;;
;;; Tab is not a row: completing a word needs the FILESYSTEM and the memory of
;;; whether the previous Tab made progress, and a rule is a pure function of
;;; (tree locus key).  It is the COMPLETE hook both editors take instead --
;;; structured-scsh/complete.scm, which is the shell's policy exactly as these
;;; rows are -- and M-TAB is the regroup key now that Tab completes.
(define escape-rule
  (make-rule (lambda (k) (eq? k 'escape))
        (lambda (t l k) (values t l 'text #t))))
;;; the interactive shell's signal keys: C-c aborts the line (a fresh prompt),
;;; never the shell.  C-z at the prompt is inert, as bash's is: bash suspends
;;; a JOB, and ^Z at the prompt with no job does nothing -- the line stays,
;;; editing continues (our terminal is raw, so ^Z arrives as a character and
;;; the printer drops it; no rule is needed).
(define interrupt-rule
  (make-rule (lambda (k) (eq? k 'interrupt))
        (lambda (t l k) (values t l 'abort-line #t))))
(define key-table
  (cons escape-rule (cons interrupt-rule (append shell-rules core-rules))))

;;; SIGTSTP is ignored, plainly: the shell is what manages stopped jobs, and
;;; a shell that could itself become one would have no one left to manage it
;;; -- bash ignores the terminal-generated ^Z at the prompt and an external
;;; kill -TSTP alike.  Only the jobs stop.
(define (install-signal-handlers!)
  (sigaction SIGTSTP SIG_IGN))

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
;;; one line in text mode: C-z suspends the shell (with job control on), and
;;; is ignored with it off -- the line keeps being edited either way
(define (edit-text text)
  (receive (text* action)
      (text-line #:prompt (scsh-prompt #:text #t) #:initial text
                 #:complete text-complete #:candidates show-candidates)
    (cond ((eq? action 'structured)
           (set! *text-editing?* #f)
           (let ((t (text-carry-tree text*)))
             (edit-one t (make-locus '() (length t) 0))))
          ((eq? action 'evaluate)
           (values (text-commit-tree text*) 'evaluate))
          ((eq? action 'interrupt) (values '() 'interrupt))
          (else (values '() 'exit)))))

(define (edit-one tree locus)
  (if *text-editing?*
      (edit-text (render-tree tree))
      (receive (t l action)
          (edit-line tree locus #:prompt (scsh-prompt)
                     #:seed seed #:rules key-table
                     #:complete tree-complete #:candidates show-candidates)
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
  ;; a ! line (text mode's shell escape, or one carried over) commits as
  ;; (run (SH -c "...")): the verbatim string goes to the standard shell,
  ;; through the same foreground machinery any command gets
  (let ((x (if (bourne-tree? tree)
               (bourne-line-datum tree)
               (line-datum (tree->sexp tree)))))
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
  (load-init)                         ; the user's init: properties, defines
  (history-load!)                     ; the previous session's lines come back
  (install-signal-handlers!)
  (ignore-terminal-stop!)             ; we point the terminal at jobs and back
  (call-with-restored-terminal        ; and we never leave it raw, however we go
   (lambda ()
     (let loop ()
       (job-poll-all!)
       (history-reset!)               ; a fresh line: recall starts at the newest
       (receive (tree locus) (fresh)
         (receive (done action) (edit-one tree locus)
           (cond
             ;; ^C aborts the line, in either editor: a fresh prompt
             ((or (eq? action 'interrupt) (eq? action 'abort-line)) (loop))
             ((not (eq? action 'evaluate)) (display "bye") (newline)) ; EOF
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
