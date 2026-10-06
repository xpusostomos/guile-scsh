;;; editor/job.scm -- job control: the shell's jobs, and how they are run.
;;;
;;; The lifecycle follows scsh 0.6's jcontrol.scm -- the design Olin Shivers
;;; left for scsh, which this port never carried:
;;;
;;;   * the child puts itself in its own process group BEFORE it does anything;
;;;   * it then PARKS, and the shell releases it -- having first pointed the
;;;     terminal at it, in the foreground case;
;;;   * a background job is released WITHOUT the terminal, so a job that reads
;;;     it is stopped by the kernel (SIGTTIN) rather than eating your keys.
;;;
;;; One deliberate departure: the handshake is a pipe, not the sketch's
;;; stop-and-re-check loop, which its own comment calls non-atomic.  The child
;;; reports its group up one pipe and awaits the go-ahead on another, so the
;;; shell knows the group exists before it hands over the terminal.
;;;
;;; Everything about jobs lives in this file: the lifecycle, the table, the
;;; commands.  The commands are ordinary procedures -- (jobs), (fg 1), (bg 2),
;;; (kill-job 1) -- which is all the shell needs now that a line can be Scheme.

(define-module (structured-scsh job)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-13)   ; string-map
  #:use-module (scsh scsh)        ; fork
  #:use-module (scsh procobj)     ; wait, wait/poll, wait/stopped-children, proc:pid
  #:use-module (scsh syscalls)    ; pid, set-process-group, signal-process-group
  #:use-module (scsh sighandlers) ; SIGCONT, SIGSTOP, SIGTERM
  #:use-module (structured-scsh term)      ; tty-process-group, set-tty-process-group
  #:export (job-start job-release! job-abandon!
            job-foreground! job-background!
            job? job:proc job:pid job:pgid job:command job:number job:state
            job-stopped-status? job-done? job-poll! job-poll-all! job-by-number
            job-list jobs-add! jobs-drop! job-announce! job-launched! job-state-name
            job-status-word
            jobs fg bg kill-job one-line))

(define-record-type <job>
  (make-job proc release-port command number state)
  job?
  (proc         job:proc)
  (release-port job:release-port set-job:release-port!)
  (command      job:command)
  (number       job:number set-job:number!)
  (state        job:state set-job:state!))

;;; A job's process group is its pid: the child made itself a group leader, so
;;; the group id and the pid are the same number.

(define *unspecified* (if #f #f))

;;; Every job's release pipe still open in the shell.  A child must not keep
;;; copies of them: closing one in the parent is only EOF for that job's child
;;; if no later fork still holds the write end.  The table is not enough for
;;; this, since a job can be dropped from it while its child is still parked.
(define *release-ports* '())

(define (register-release-port! p)
  (set! *release-ports* (cons p *release-ports*))
  p)

(define (forget-release-port! p)
  (set! *release-ports* (delq p *release-ports*)))

(define (job:pid job)  (proc:pid (job:proc job)))
(define (job:pgid job) (proc:pid (job:proc job)))

;;; ---- the lifecycle ---------------------------------------------------------
;;; (job-start THUNK [COMMAND]) -> a job, PARKED in its own process group.  The
;;; child has already put itself in its own group by the time this returns, so
;;; the shell may safely point the terminal at (job:pgid job) before releasing.

(define (job-start thunk . maybe-command)
  (let* ((up   (pipe))                  ; child -> parent: "my group is set"
         (down (pipe))                  ; parent -> child: "go"
         (upr  (car up))   (upw  (cdr up))
         (dnr  (car down)) (dnw  (cdr down)))
    (let ((proc (fork (lambda ()
                        ;; CHILD
                        (set-process-group (pid) 0)     ; own group, first thing
                        ;; Do not hold any OTHER job's release pipe: the parent
                        ;; closing one is only EOF for that job's child if no
                        ;; later fork kept a copy of the write end.
                        (for-each close-port *release-ports*)
                        (close-port upr)
                        (close-port dnw)
                        (write-char #\x01 upw)          ; tell the parent
                        (force-output upw)
                        (close-port upw)
                        (read-char dnr)                 ; park (EOF releases too)
                        (close-port dnr)
                        ;; an error inside the job -- glob1's "No match", a
                        ;; bad form -- is said the way the prompt says it,
                        ;; and fails the job; the shell itself continues
                        (catch #t
                          thunk
                          (lambda (key . args)
                            (display "error: ") (display key)
                            (display " ") (display args) (newline)
                            (exit 1)))))))
      ;; PARENT
      (close-port upw)
      (close-port dnr)
      (read-char upr)                                   ; wait for "group is set"
      (close-port upr)
      (register-release-port! dnw)
      (make-job proc dnw (if (pair? maybe-command) (car maybe-command) #f)
                #f                                  ; numbered when it is added
                (list 'parked #f)))))

;;; release the job so that it begins its work
(define (job-release! job)
  (let ((p (job:release-port job)))
    (when p
      (set-job:release-port! job #f)
      (forget-release-port! p)
      (write-char #\x01 p)
      (force-output p)
      (close-port p))
    job))

;;; let the job go without ever releasing it properly -- closes the pipe, which
;;; the parked child reads as EOF and takes as its cue.  This is also what
;;; happens if the shell dies: no child is left parked forever.
(define (job-abandon! job)
  (let ((p (job:release-port job)))
    (when p
      (set-job:release-port! job #f)
      (forget-release-port! p)
      (close-port p))
    job))

;;; ---- foreground and background ---------------------------------------------
;;; Foreground: give the job the terminal, release it, resume it if it was
;;; stopped, wait for it to stop or exit, then take the terminal back.  Reading
;;; the status with wait/stopped-children is what makes a stopped job visible.
(define (job-foreground! job)
  (let ((ours (tty-process-group 0))
        (pg   (job:pgid job)))
    (when (and ours pg) (set-tty-process-group 0 pg))
    (job-release! job)
    ;; a job that has already been reaped cannot be signalled
    (unless (job-done? job) (signal-process-group pg SIGCONT))
    (let ((status (wait (job:proc job) wait/stopped-children)))
      (when ours (set-tty-process-group 0 ours))
      (set-job:state! job (if (job-stopped-status? status)
                              (list 'stopped status)
                              (list 'done status)))
      status)))

;;; Background: release it and leave the terminal with the shell.  If it reads
;;; the terminal it will be stopped by SIGTTIN -- which is the point.
(define (job-background! job)
  (job-release! job)
  (unless (job-done? job) (signal-process-group (job:pgid job) SIGCONT))
  (set-job:state! job (list 'running #f))
  job)

;;; ---- state without blocking ------------------------------------------------

(define (job-stopped-status? status)
  (and (integer? status) (= (logand status #xff) #x7f)))

(define (job-done? job) (eq? (car (job:state job)) 'done))

;;; Ask the kernel how the job is doing, without waiting for anything.
(define (job-poll! job)
  (unless (job-done? job)
    (let ((status (wait (job:proc job) (logior wait/poll wait/stopped-children))))
      (when status
        (set-job:state! job (if (job-stopped-status? status)
                                (list 'stopped status)
                                (list 'done status))))))
  job)

;;; Poll every job and say what changed, then forget the ones that have
;;; finished (they have been reported).  The shell calls this before each
;;; prompt, which is how background jobs get noticed.
(define (job-poll-all!)
  (for-each (lambda (job)
              (let ((was (car (job:state job))))
                (job-poll! job)
                (let ((now (car (job:state job))))
                  (unless (eq? was now)
                    (job-announce! job)))))
            (job-list))
  (for-each (lambda (job) (when (job-done? job) (jobs-drop! job))) (job-list)))

;;; bash's markers: "+" on the job started most recently, "-" on the one before
(define (job-marker job)
  (let ((ls (job-list)))
    (cond ((and (pair? ls) (eq? job (car ls))) "+")
          ((and (pair? ls) (pair? (cdr ls)) (eq? job (cadr ls))) "-")
          (else " "))))

;;; a line in bash's shape:  [1]+  Stopped  wc.  A command's text may have
;;; been a multi-line expression, but a table line is one line: breaks flatten.
(define (one-line s)
  (string-map (lambda (c) (if (char=? c #\newline) #\space c)) s))

(define (job-announce! job)
  (display "[") (display (job:number job)) (display "]")
  (display (job-marker job))
  (display "  ") (display (job-state-name job))
  (display "  ") (display (one-line (or (job:command job) ""))) (newline))

;;; bash announces a launch by number and pid:  [1] 413981
(define (job-launched! job)
  (display "[") (display (job:number job)) (display "] ")
  (display (job:pid job)) (newline))

;;; ---- how a job ended ---------------------------------------------------------
;;; bash says which way a job went, not just that it went: "Done" for a clean
;;; exit, "Exit 1" for a non-zero one, and the signal's own description
;;; ("Terminated", "Killed", "Segmentation fault") when it was killed.  These
;;; are bash's words, from its siglist.c -- guile has no strsignal to borrow.

(define *signal-words*
  `((,SIGHUP . "Hangup")                     (,SIGINT . "Interrupt")
    (,SIGQUIT . "Quit")                      (,SIGILL . "Illegal instruction")
    (,SIGTRAP . "Trace/breakpoint trap")     (,SIGABRT . "Aborted")
    (,SIGBUS . "Bus error")                  (,SIGFPE . "Floating point exception")
    (,SIGKILL . "Killed")                    (,SIGUSR1 . "User defined signal 1")
    (,SIGSEGV . "Segmentation fault")        (,SIGUSR2 . "User defined signal 2")
    (,SIGPIPE . "Broken pipe")               (,SIGALRM . "Alarm clock")
    (,SIGTERM . "Terminated")                (,SIGSTKFLT . "Stack fault")
    (,SIGCHLD . "Child exited")              (,SIGCONT . "Continued")
    (,SIGSTOP . "Stopped (signal)")          (,SIGTSTP . "Stopped")
    (,SIGTTIN . "Stopped (tty input)")       (,SIGTTOU . "Stopped (tty output)")
    (,SIGURG . "Urgent I/O condition")       (,SIGXCPU . "CPU time limit exceeded")
    (,SIGXFSZ . "File size limit exceeded")  (,SIGVTALRM . "Virtual timer expired")
    (,SIGPROF . "Profiling timer expired")   (,SIGWINCH . "Window changed")
    (,SIGIO . "I/O possible")                (,SIGPWR . "Power failure")))

(define (signal-word sig)
  (let ((p (assv sig *signal-words*)))
    (if p (cdr p) (string-append "Signal " (number->string sig)))))

;;; A wait status carries both the reason and the detail: the low byte is how
;;; (0 = exited, 0x7f = stopped, anything else = killed by that signal) and the
;;; high byte is the exit code, or the signal that stopped it.
(define (job-status-word status)
  (let ((how (logand status #xff))
        (why (ash status -8)))
    (cond ((= how #x7f) (signal-word why))          ; stopped
          ((> how 0)    (signal-word how))          ; killed
          ((zero? why)  "Done")                     ; exited
          (else         (string-append "Exit " (number->string why))))))

(define (job-state-name job)
  (let ((st (job:state job)))
    (case (car st)
      ((parked)  "Parked")
      ((running) "Running")
      ((stopped) (if (integer? (cadr st)) (job-status-word (cadr st)) "Stopped"))
      ((done)    (if (integer? (cadr st)) (job-status-word (cadr st)) "Done"))
      (else      "?"))))

;;; ---- the table -------------------------------------------------------------

(define *jobs* '())

(define (job-list) *jobs*)

(define (next-job-number)
  (let lp ((n 1))
    (if (any (lambda (j) (= n (job:number j))) *jobs*) (lp (+ n 1)) n)))

(define (jobs-add! job)
  (set-job:number! job (next-job-number))
  (set! *jobs* (cons job *jobs*))
  job)
(define (jobs-drop! job) (set! *jobs* (delq job *jobs*)) job)

(define (job-by-number n)
  (any (lambda (j) (and (equal? n (job:number j)) j)) *jobs*))

(define (no-such-job n)
  (display "No such job: ") (display n) (newline))

;;; ---- the commands ----------------------------------------------------------
;;; Ordinary procedures, callable from a Scheme line or a script.

;;; (jobs) -- print the table, oldest number first
(define (jobs)
  (for-each job-announce!
            (sort (job-list) (lambda (a b) (< (job:number a) (job:number b)))))
  *unspecified*)

;; (fg N) -- bring job N to the foreground and wait for it.  As in bash, a job
;;; that COMPLETES in the foreground is not announced (its own output says what
;;; happened); one that stops again is.
(define (fg n)
  (let ((job (job-by-number n)))
    (if (not job)
        (no-such-job n)
        (begin
          (job-foreground! job)
          (if (job-done? job)
              (jobs-drop! job)
              (job-announce! job))
          *unspecified*))))

;;; (bg N) -- let job N run on in the background, without the terminal
(define (bg n)
  (let ((job (job-by-number n)))
    (if (not job)
        (no-such-job n)
        (begin (job-background! job)
               (job-announce! job)
               *unspecified*))))

;;; (kill-job N [SIGNAL]) -- signal the job's whole process group
(define (kill-job n . maybe-signal)
  (let ((job (job-by-number n)))
    (if (not job)
        (no-such-job n)
        (begin
          (signal-process-group (job:pgid job)
                                (if (pair? maybe-signal) (car maybe-signal) SIGTERM))
          (job-poll! job)
          *unspecified*))))
