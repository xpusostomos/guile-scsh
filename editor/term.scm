;;; editor/term.scm -- the raw terminal front-end.
;;;
;;; The only part of the editor that touches the tty: put it into raw mode, read
;;; keys (decoding the escape sequences the arrow keys send), and redraw one
;;; line.  When stdin is not a terminal, raw mode is simply not entered, so the
;;; editor can still be driven from a pipe for testing.
;;;
;;; Known limits, for now: a line longer than the terminal width will wrap and
;;; confuse the column arithmetic, and there is no SIGWINCH handling (every
;;; keypress redraws anyway).  Both are later work.

(define-module (editor term)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:export (tty? with-raw-term read-key draw styled split-newlines leave-frame!
            tty-process-group set-tty-process-group call-with-cooked-terminal
            ignore-terminal-stop! restore-terminal! call-with-restored-terminal))

;;; ---- raw mode --------------------------------------------------------------
;;; libc termios by FFI.  We never look inside struct termios: we keep the
;;; caller's copy for restoring, and let cfmakeraw fill in the raw one.

(define libc (dynamic-link))

;;; A job-controlling shell points the terminal at a job and takes it back --
;;; tcsetpgrp calls it makes while it is NOT the terminal's foreground process
;;; group.  Those raise SIGTTOU, whose default action is to STOP the process,
;;; so without this the shell stops itself the moment a foregrounded job ends
;;; ("bg a job, fg it, end it with ^D, and scsh stops itself").  Every real
;;; shell ignores SIGTTOU for exactly this reason; SIGTTIN is left alone, so a
;;; shell that is itself backgrounded still stops when it tries to read.
(define (ignore-terminal-stop!)
  (sigaction SIGTTOU SIG_IGN)
  #t)

(define tcgetattr (pointer->procedure int  (dynamic-func "tcgetattr" libc) (list int '*)))
(define tcsetattr (pointer->procedure int  (dynamic-func "tcsetattr" libc) (list int int '*)))
(define cfmakeraw (pointer->procedure void (dynamic-func "cfmakeraw" libc) (list '*)))
(define isatty    (pointer->procedure int  (dynamic-func "isatty" libc)    (list int)))
(define tcgetpgrp  (pointer->procedure int  (dynamic-func "tcgetpgrp" libc) (list int)))
(define tcsetpgrp  (pointer->procedure int  (dynamic-func "tcsetpgrp" libc) (list int int)))

(define TCSANOW 0)
(define TERMIOS-SIZE 128)                 ; comfortably bigger than the struct

(define (tty? fd)
  (not (zero? (isatty fd))))

;;; The terminal's original modes, kept from the first time we go raw: they are
;;; what everything -- a job's terminal, the end of a line, the end of the
;;; session, a signal -- is restored to.  There is deliberately no record of the
;;; raw modes: raw is only ever a state we are in WHILE editing, never one we
;;; leave behind (see RESTORE-TERMINAL!).
(define original-modes #f)

(define (use-modes! modes)
  (tcsetattr 0 TCSANOW (bytevector->pointer modes)))

(define (with-raw-term thunk)
  (if (not (tty? 0))
      (thunk)                             ; a pipe: nothing to change
      (let ((saved (make-bytevector TERMIOS-SIZE 0))
            (raw   (make-bytevector TERMIOS-SIZE 0)))
        (tcgetattr 0 (bytevector->pointer saved))
        (bytevector-copy! saved 0 raw 0 TERMIOS-SIZE)
        (cfmakeraw (bytevector->pointer raw))
        (set! original-modes saved)
        (install-terminal-restore!)       ; before the first raw keystroke
        (dynamic-wind
            (lambda () (use-modes! raw))
            thunk
            (lambda () (use-modes! saved))))))

;;; ---- never leave the terminal raw ------------------------------------------
;;; A shell that dies with the terminal in raw mode takes your echo and your
;;; line editing with it, and you type `stty sane` blind to get them back.  We
;;; are the only thing that puts the terminal into raw mode, so we are the only
;;; thing that has to give it back, and it has to happen on every way out:
;;;
;;;   * the ordinary end of a line of editing     -- WITH-RAW-TERM's unwind
;;;   * the ordinary end of the session           -- CALL-WITH-RESTORED-TERMINAL
;;;   * an error, or (exit) -- which unwinds      -- the same two, since Guile
;;;                                                  runs those cleanups even
;;;                                                  for (exit)
;;;   * a signal that would kill us               -- the handlers below
;;;
;;; SIGKILL cannot be caught and a crash cannot be helped; nothing else gets
;;; to leave the terminal changed.

(define (restore-terminal!)
  (when (and original-modes (tty? 0))
    (tcsetattr 0 TCSANOW (bytevector->pointer original-modes))
    (display "\x1b[0m")                 ; and no styling left on, either
    (force-output))
  #t)                                   ; nothing to restore is not a failure

(define *restore-installed?* #f)

(define (install-terminal-restore!)
  (unless *restore-installed?*
    (set! *restore-installed?* #t)
    (for-each
     (lambda (sig)
       (sigaction sig (lambda (n)
                        (restore-terminal!)
                        ;; die of it, as we would have: the default action, and
                        ;; the signal raised again.  It is delivered when this
                        ;; handler returns, which is exactly what we want.
                        (sigaction n SIG_DFL)
                        (kill (getpid) n))))
     (list SIGTERM SIGHUP SIGINT SIGQUIT))))

;;; Run THUNK with the guarantee that the terminal is handed back, whatever
;;; happens -- including (exit), which Guile runs these cleanups for.
(define (call-with-restored-terminal thunk)
  (install-terminal-restore!)
  (dynamic-wind (lambda () #t) thunk (lambda () (restore-terminal!))))

;;; Hand the terminal over with its normal modes for the extent of THUNK -- a
;;; job needs a sane terminal -- and give it back COOKED afterwards, not raw.
;;; This is called between two lines of editing, never during one, and the next
;;; line goes raw again in WITH-RAW-TERM.  Handing back the raw modes here was a
;;; leak: the terminal stayed raw between lines, so the next WITH-RAW-TERM saved
;;; *raw* as the modes to restore and the shell exited with no echo and no line
;;; editing -- the `stty sane` bug.  A no-op when there is no terminal.
(define (call-with-cooked-terminal thunk)
  (if (and original-modes (tty? 0))
      (dynamic-wind
          (lambda () (use-modes! original-modes))
          thunk
          (lambda () (restore-terminal!)))
      (thunk)))

;;; ---- terminal ownership ----------------------------------------------------
;;; Which process group the terminal belongs to (scsh 0.6.7's names).  #f when
;;; there is no terminal to speak of, so callers can simply skip the handoff.

(define (tty-process-group fd)
  (if (not (tty? fd))
      #f
      (let ((pg (tcgetpgrp fd)))
        (if (< pg 0) #f pg))))

(define (set-tty-process-group fd pgrp)
  (if (not (tty? fd))
      #f
      (not (< (tcsetpgrp fd pgrp) 0))))

;;; ---- keys ------------------------------------------------------------------
;;; A key is a character to be typed, or one of:
;;;   left right up down home end delete backspace enter tab eof interrupt escape

(define (wait-char port)
  ;; the next character if it arrives promptly (as the rest of an escape
  ;; sequence will), else #f -- 20 polls of 2ms, sleeping through select
  ;; (guile's sleep wants an exact integer, and scsh's usleep is not ours)
  (let loop ((n 0))
    (cond ((char-ready? port) (read-char port))
          ((>= n 20) #f)
          (else (select '() '() '() 0.002) (loop (+ n 1))))))

(define (read-escape port)
  (let ((c1 (wait-char port)))
    (if (not c1)
        'escape
        (if (or (char=? c1 #\return) (char=? c1 #\newline))
            'm-return                         ; M-RET: a new line, not a commit
            (if (or (char=? c1 #\[) (char=? c1 #\O))
            (let ((c2 (wait-char port)))
              (cond ((not c2) 'escape)
                    ((char=? c2 #\A) 'up)
                    ((char=? c2 #\B) 'down)
                    ((char=? c2 #\C) 'right)
                    ((char=? c2 #\D) 'left)
                    ((char=? c2 #\H) 'home)
                    ((char=? c2 #\F) 'end)
                    ((memv c2 (list #\1 #\3 #\4 #\7 #\8))
                     (let ((c3 (wait-char port)))
                       (if (and c3 (char=? c3 #\~))
                           (cond ((char=? c2 #\3) 'delete)
                                 ((or (char=? c2 #\1) (char=? c2 #\7)) 'home)
                                 (else 'end))
                           'escape)))
                    (else 'escape)))
            'escape)))))

;;; Wait until there is something to read, in short steps rather than one
;;; blocking read.  Guile runs a Scheme signal handler only at a safe point, and
;;; a shell blocked in read-char never reaches one -- so a shell sitting at the
;;; prompt would ignore SIGTERM (or SIGHUP, when the window closes) until a key
;;; was pressed, which is exactly when we are least able to give the terminal
;;; back.  Waiting in short slices keeps the safe points coming, so the signal
;;; handlers in INSTALL-TERMINAL-RESTORE! run when they are sent.
(define (wait-for-input port)
  (let loop ()
    (if (char-ready? port)                    ; already buffered
        #t
        (if (pair? (car (select (list port) '() '() 0.1)))
            #t                                ; readable (an EOF counts) -- let
            (loop)))))                        ; READ-CHAR settle what it is

(define (read-key . maybe-port)
  (let ((port (if (null? maybe-port) (current-input-port) (car maybe-port))))
    (wait-for-input port)
    (let ((ch (read-char port)))
      (cond ((eof-object? ch) 'eof)
            ((char=? ch #\x1b) (read-escape port))
            ((or (char=? ch #\newline) (char=? ch #\return)) 'enter)
            ((char=? ch #\tab) 'tab)
            ((or (char=? ch (integer->char 127)) (char=? ch (integer->char 8))) 'backspace)
            ((char=? ch (integer->char 4)) 'eof)          ; C-d
            ((char=? ch (integer->char 3)) 'interrupt)    ; C-c
            (else ch)))))

;;; ---- drawing ---------------------------------------------------------------
;;; A BLOCK now, not a line: TEXT may contain newlines (a break element makes
;;; one).  The bold spans are folded into the text first (one string with
;;; escape sequences in it), that string is split at its newlines, and the
;;; lines are printed: prompt before the first, "\r\n" before the rest -- raw
;;; mode does not return the carriage on "\n" -- and "\x1b[K" clearing each
;;; line, "\x1b[J" clearing below, so a shorter frame erases a taller one.
;;; Then the cursor is walked to (row, col).  This is the only place in the
;;; editor that knows escape sequences or that \n is not enough in raw mode.

(define (split-newlines s)
  (if (string=? s "")
      (list "")
      (let lp ((i 0) (out '()))
        (if (>= i (string-length s))
            (reverse out)
            (let ((j (string-index s #\newline i)))
              (if j
                  (lp (+ j 1) (cons (substring s i j) out))
                  (lp (string-length s) (cons (substring s i) out))))))))

;; fold BOLD (sorted (start . end) offsets) into TEXT as escape sequences;
;; STANDOUT#t renders the spans in reverse video instead of bold -- bash's C-r
;; highlights the match that way
(define (styled text spans standout)
  (let ((on (if standout "\x1b[7m" "\x1b[1m")))
    (let lp ((i 0) (spans spans) (out (list "")))
      (if (null? spans)
          (apply string-append (reverse (cons (substring text i) out)))
          (let* ((span (car spans))
                 (a (car span)) (b (cdr span)))
            (lp b (cdr spans)
                (cons "\x1b[0m"
                      (cons (substring text a b)
                            (cons on
                                  (cons (substring text i a) out))))))))))

;;; Where the last frame was drawn, so the next one can return to its HOME --
;;; the prompt's line.  A multi-line frame leaves the cursor somewhere inside
;;; itself, and a draw that starts from there would print the prompt on a
;;; continuation line and push the whole frame down one line per redraw (the
;;; "scrolls off with many prompts" bug).  Both are reset by LEAVE-FRAME!, so
;;; anything printed between frames starts clean below the frame.
(define *drawn-row* 0)
(define *drawn-lines* 1)

;;; From wherever the cursor sits inside the drawn frame, down past its last
;;; line -- where output and the next prompt belong.
(define (leave-frame!)
  (let ((down (- *drawn-lines* *drawn-row*)))
    (display "\r")
    (let lp ((n down)) (when (positive? n) (display "\r\n") (lp (- n 1))))
    (set! *drawn-row* 0)
    (set! *drawn-lines* 1)
    (force-output)))

(define (draw prompt text col row . opts)
  ;; OPTS: (bold standout) -- bold spans (as before) and, when STANDOUT is
  ;; #t, those spans render in reverse video (C-r's highlight) rather than
  ;; bold.  Existing callers pass just BOLD and get the old behaviour.
  (let* ((bold (if (pair? opts) (car opts) '()))
         (standout (and (pair? (cdr opts)) (cadr opts))))
    (when (> *drawn-row* 0)                ; back up to the frame's home line
      (display (string-append "\x1b[" (number->string *drawn-row*) "A")))
    (let ((lines (split-newlines (styled text bold standout))))
      (set! *drawn-row* row)
      (set! *drawn-lines* (length lines))
      (display "\r")
      (display "\x1b[K")
      (display prompt)
      (display (car lines))
      (for-each (lambda (l) (display "\r\n\x1b[K") (display l)) (cdr lines))
      (display "\x1b[J")                    ; a shorter frame erases a taller one
      (let ((up (- (length lines) 1 row)))
        (when (> up 0)
          (display (string-append "\x1b[" (number->string up) "A"))))
      (display "\r")
      ;; row 0 carries the prompt, so its columns start after it; the other
      ;; lines start where the text does (its indentation is in the text)
      (let ((c (+ col (if (zero? row) (string-length prompt) 0))))
        (when (> c 0)
          (display (string-append "\x1b[" (number->string c) "C"))))
      (force-output))))
