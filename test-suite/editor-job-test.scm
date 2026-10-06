;;; editor-job-test.scm -- tests for structured-scsh/job.scm (the job lifecycle).
;;;
;;; No terminal is needed: every tty operation in (structured-scsh term) is a no-op when
;;; there is no terminal, so the lifecycle can be exercised from a pipe.  What
;;; these pin down is the handshake: that a child is parked before it runs,
;;; that it is in its own process group by the time job-start returns, and that
;;; both a byte and an EOF release it.
;;;
;;;   make -C test-suite engine

(use-modules (ice-9 receive))
(use-modules (srfi srfi-9))
(use-modules (scsh scsh) (scsh procobj) (scsh syscalls) (scsh sighandlers))
(use-modules (srfi srfi-13))
(use-modules (ice-9 rdelim))
(use-modules (structured-scsh job) (structured-scsh term))

(define failures '())
(define (check label expect got)
  (if (equal? expect got)
      (display (string-append "ok   " label "\n"))
      (begin (set! failures (cons label failures))
             (display (string-append "FAIL " label "\n  expect "))
             (write expect) (newline)
             (display "  got    ") (write got) (newline))))

(define base (string-append "/tmp/editor-job-test-" (number->string (getpid))))

;;; scsh's sleep wants exact integer seconds, so wait in microseconds instead.
(define (pause secs) (usleep (inexact->exact (round (* secs 1000000)))))

;;; ---- the handshake: parked, then released ------------------------------------

(define f1 (string-append base ".1"))
(when (file-exists? f1) (delete-file f1))
(let ((ours (process-group)))
  (let ((job (job-start (lambda ()
                          (call-with-output-file f1
                            (lambda (p) (write (list (getpid) (process-group)) p)))))))
    (check "a job is parked before it is released" #f (file-exists? f1))

    (job-release! job)
    (define status (wait (job:proc job) wait/stopped-children))
    (check "the job runs once released"            #t (file-exists? f1))
    (check "it exits cleanly"                      #t (integer? status))

    (define info (call-with-input-file f1 read))
    (check "the child leads its own process group" (car info) (cadr info))
    (check "and it is not the shell's group"       #f (= ours (cadr info)))
    (check "job:pgid is that group"                (cadr info) (job:pgid job))
    (check "job:pid is the same number"            (car info) (job:pid job))))

;;; ---- the shell knows the group before releasing (job-start blocks on it) -----

(check "job-start returns only after the group is set"
       #t (let ((job (job-start (lambda () #t))))
            (job-release! job)
            (wait (job:proc job) wait/stopped-children)
            (integer? (job:pgid job))))

;;; ---- EOF releases a parked child too ------------------------------------------

(define f2 (string-append base ".2"))
(when (file-exists? f2) (delete-file f2))
(let ((job (job-start (lambda ()
                        (call-with-output-file f2 (lambda (p) (display "ran" p)))))))
  (check "nothing has run yet" #f (file-exists? f2))
  (job-abandon! job)                      ; close the pipe: the child sees EOF
  (wait (job:proc job) wait/stopped-children)
  (check "EOF releases the parked child" #t (file-exists? f2)))

;;; ---- foreground without a terminal: no handoff, but it still runs -------------

(define f3 (string-append base ".3"))
(when (file-exists? f3) (delete-file f3))
(let ((job (job-start (lambda ()
                        (call-with-output-file f3 (lambda (p) (display "fg" p)))))))
  (check "job-foreground! returns a status with no tty"
         #t (integer? (job-foreground! job)))
  (check "and the job did run" #t (file-exists? f3)))

;;; ---- the table: numbering, states, and the commands ---------------------------

(define (contains? text s) (if (string-contains text s) #t #f))

(define (poll-until job pred)
  (let lp ((n 0))
    (job-poll! job)
    (if (or (pred job) (> n 300)) job (begin (pause 0.01) (lp (+ n 1))))))

;;; numbering: the lowest free number, and freed numbers come back
(let ((a (job-start (lambda () #t) "a")) (b (job-start (lambda () #t) "b")))
  (check "a job has no number until it is in the table" #f (job:number a))
  (jobs-add! a) (jobs-add! b)
  (check "jobs are numbered from one" (list 1 2) (list (job:number a) (job:number b)))
  (jobs-drop! a)
  (let ((c (job-start (lambda () #t) "c")))
    (jobs-add! c)
    (check "a freed number is reused" 1 (job:number c))
    (jobs-drop! c))
  (job-abandon! a) (job-abandon! b)
  (wait (job:proc a) wait/stopped-children)
  (wait (job:proc b) wait/stopped-children))

;;; a job that finishes polls to Done
(let ((job (job-start (lambda () #t) "quick")))
  (jobs-add! job) (job-background! job)
  (poll-until job job-done?)
  (check "a finished job polls to Done" 'done (car (job:state job)))
  (jobs-drop! job))

;;; a stopped job polls to Stopped, and (bg N) resumes it
(let ((job (job-start (lambda () (pause 0.4)) "sleeper")))
  (jobs-add! job) (job-background! job)
  (signal-process-group (job:pgid job) SIGSTOP)
  (poll-until job (lambda (j) (eq? (car (job:state j)) 'stopped)))
  (check "a stopped job polls to Stopped" 'stopped (car (job:state job)))
  (check "and it is still in the table"   #t (eq? job (job-by-number (job:number job))))
  (bg (job:number job))
  (poll-until job job-done?)
  (check "(bg N) resumes it, and it finishes" 'done (car (job:state job)))
  (jobs-drop! job))

;;; (jobs) prints the table
(let ((job (job-start (lambda () (pause 0.3)) "a | b")))
  (jobs-add! job) (job-background! job)
  (let ((text (call-with-output-string
               (lambda (p) (parameterize ((current-output-port p)) (jobs))))))
    (check "(jobs) prints the number"  #t (contains? text "[1]"))
    (check "(jobs) prints the state"   #t (contains? text "Running"))
    (check "(jobs) prints the command" #t (contains? text "a | b")))
  (kill-job (job:number job))
  (poll-until job job-done?)
  (jobs-drop! job))

;;; (kill-job N) signals the whole group, and the job ends
(let ((job (job-start (lambda () (pause 5)) "long")))
  (jobs-add! job) (job-background! job)
  (kill-job (job:number job))
  (poll-until job job-done?)
  (check "(kill-job N) ends the job" 'done (car (job:state job)))
  (jobs-drop! job))

;;; (job-poll-all!) reports a change and forgets the finished job
(let ((job (job-start (lambda () #t) "bye")))
  (jobs-add! job) (job-background! job)
  (poll-until job job-done?)
  (let ((text (call-with-output-string
               (lambda (p) (parameterize ((current-output-port p)) (job-poll-all!))))))
    (check "job-poll-all! reports the change" #t (contains? text "Done"))
    (check "and forgets the finished job" 0 (length (job-list)))))

;;; ---- (fg N): silent when the job completes, as bash is ------------------------

(let ((job (job-start (lambda () #t) "quiet")))
  (jobs-add! job) (job-background! job)
  (poll-until job job-done?)
  (let ((text (call-with-output-string
               (lambda (p) (parameterize ((current-output-port p)) (fg (job:number job)))))))
    (check "(fg N) says nothing when the job finishes" "" text))
  (check "and the finished job is forgotten" #f (job-by-number (job:number job))))

;;; a job that stops, is resumed, and stops again: (fg N) must say so
(let ((job (job-start (lambda ()
                        (signal-process (pid) SIGSTOP)   ; stop...
                        (signal-process (pid) SIGSTOP))  ; ...and stop again
                      "selfstop")))
  (jobs-add! job) (job-background! job)
  (poll-until job (lambda (j) (eq? (car (job:state j)) 'stopped)))
  (let ((text (call-with-output-string
               (lambda (p) (parameterize ((current-output-port p)) (fg (job:number job)))))))
    (check "(fg N) reports a job that stops again" 'stopped (car (job:state job)))
    (check "and says so" #t (contains? text "Stopped")))
  (kill-job (job:number job) SIGKILL)          ; SIGKILL reaches a stopped job
  (poll-until job job-done?)
  (jobs-drop! job))

;;; ---- how a job ended, in bash's words (bash's siglist.c, not our invention) ---

;;; a wait status is plain arithmetic: exit code in the high byte, or the
;;; signal that killed it in the low one.
(check "a clean exit says Done"   "Done" (job-status-word 0))
(check "a non-zero exit says so"  "Exit 1" (job-status-word (ash 1 8)))
(check "a killed job names the signal" "Killed" (job-status-word SIGKILL))
(check "and so does SIGTERM"      "Terminated" (job-status-word SIGTERM))
(check "a stopped job says Stopped" "Stopped" (job-status-word (logior (ash SIGTSTP 8) #x7f)))
(check "a job stopped reading the tty says which"
       "Stopped (tty input)" (job-status-word (logior (ash SIGTTIN 8) #x7f)))

;;; and the same through a real job: kill it, and the table says how it died
(let ((job (job-start (lambda () (pause 5)) "long")))
  (jobs-add! job) (job-background! job)
  (kill-job (job:number job))                   ; SIGTERM
  (poll-until job job-done?)
  (let ((text (call-with-output-string
               (lambda (p) (parameterize ((current-output-port p)) (job-announce! job))))))
    (check "a terminated job is announced as Terminated" #t (contains? text "Terminated")))
  (jobs-drop! job))

(let ((job (job-start (lambda () (pause 5)) "long")))
  (jobs-add! job) (job-background! job)
  (kill-job (job:number job) SIGKILL)
  (poll-until job job-done?)
  (let ((text (call-with-output-string
               (lambda (p) (parameterize ((current-output-port p)) (job-announce! job))))))
    (check "a killed job is announced as Killed" #t (contains? text "Killed")))
  (jobs-drop! job))

(let ((job (job-start (lambda () (primitive-exit 3)) "three")))
  (jobs-add! job) (job-background! job)
  (poll-until job job-done?)
  (let ((text (call-with-output-string
               (lambda (p) (parameterize ((current-output-port p)) (job-announce! job))))))
    (check "a job that exits 3 is announced as Exit 3" #t (contains? text "Exit 3")))
  (jobs-drop! job))

;;; ---- the shell must not stop itself when it takes the terminal back --------
;;; Pointing the terminal at a job and taking it back means calling tcsetpgrp
;;; while we are not the foreground process group, which raises SIGTTOU -- whose
;;; default action is to stop us.  Hence: SIGTTOU ignored, SIGTTIN left alone.

(define (signal-ignored? n)
  (let ((mask (call-with-input-file "/proc/self/status"
                (lambda (p)
                  (let lp ()
                    (let ((l (read-line p)))
                      (cond ((eof-object? l) #f)
                            ((string-prefix? "SigIgn:" l)
                             (string->number (string-trim-both (substring l 7)) 16))
                            (else (lp)))))))))
    (and mask (not (zero? (logand mask (ash 1 (- n 1))))))))

;; a caller's inherited dispositions are not ours to assume: bash ignores
;; SIGTTIN/SIGTTOU in a command substitution and the child inherits them, so
;; start from a known state before checking what ignore-terminal-stop! does
(sigaction SIGTTIN SIG_DFL)
(sigaction SIGTTOU SIG_DFL)

(check "SigIgn does not yet include SIGTTOU" #f (signal-ignored? SIGTTOU))
(ignore-terminal-stop!)
(check "ignore-terminal-stop! ignores SIGTTOU" #t (signal-ignored? SIGTTOU))
(check "and leaves SIGTTIN alone"               #f (signal-ignored? SIGTTIN))

;;; ---- the terminal is always handed back ---------------------------------------
;;; A shell that exits with the terminal in raw mode takes your echo and your
;;; line editing with it.  There is no terminal here, so what is checked is the
;;; machinery: that restoring is safe to do at any time, and that the guard runs
;;; its cleanup on every way out -- including (exit), which Guile unwinds for.
;;; The modes themselves were verified on a pty: raw while editing, cooked after
;;; C-d, after a command, after a background job, and on SIGTERM/SIGHUP/SIGINT/
;;; SIGQUIT.

(check "restoring the terminal is safe with no terminal at all"
       #t (restore-terminal!))
(check "and safe to do twice" #t (restore-terminal!))

(check "the guard runs its body"
       'inside (call-with-restored-terminal (lambda () 'inside)))

;; an error inside it still unwinds (the guard must not swallow the escape, or
;; the editor could never report an error again)
(define cleaned? #f)
(catch #t
       (lambda ()
         (call-with-restored-terminal
          (lambda () (dynamic-wind (lambda () #t)
                                   (lambda () (error "boom"))
                                   (lambda () (set! cleaned? #t))))))
       (lambda args #f))
(check "an escape still unwinds through the guard" #t cleaned?)

;; The shell's (quit) is an (exit) from inside this guard, so the guard's
;; cleanup has to run for (exit) too.  That is Guile's behaviour, not ours, but
;; the whole guarantee rests on it -- so it is pinned here, in a subprocess.
(define marker (string-append base ".exit"))
(when (file-exists? marker) (delete-file marker))
(system (string-append
         "guile -q -L . -c '(use-modules (structured-scsh term))"
         " (call-with-restored-terminal"
         "  (lambda () (dynamic-wind (lambda () #t)"
         "                           (lambda () (exit 0))"
         "                           (lambda () (call-with-output-file \""
         marker "\" (lambda (p) (display \"ran\" p)))))))' >/dev/null 2>&1"))
(check "(exit) does not skip the cleanup" #t (file-exists? marker))

;;; ---- verdict ------------------------------------------------------------------

(for-each (lambda (f) (when (file-exists? f) (delete-file f)))
          (list f1 f2 f3))
(newline)
(if (null? failures)
    (begin (display "ALL CHECKS PASSED") (newline) (exit 0))
    (begin (display "FAILURES: ") (write failures) (newline) (exit 1)))