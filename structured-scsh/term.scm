;;; structured-scsh/term.scm -- the raw terminal front-end.
;;;
;;; The only part of the editor that touches the tty: put it into raw mode, read
;;; keys (decoding the escape sequences the arrow keys send), and redraw one
;;; line.  When stdin is not a terminal, raw mode is simply not entered, so the
;;; editor can still be driven from a pipe for testing.
;;;
;;; Known limits, for now: a line longer than the terminal width will wrap and
;;; confuse the column arithmetic, and there is no SIGWINCH handling (every
;;; keypress redraws anyway).  Both are later work.

(define-module (structured-scsh term)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:export (tty? with-raw-term read-key draw styled split-newlines leave-frame!
            terminal-width terminal-height show-candidates candidate-rows
            page-rows completion-query?
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
;;;   c-left c-right c-m-left c-m-right   (Ctrl-, Ctrl+Alt- with the arrows)

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
    (cond
      ((not c1) 'escape)
      ;; M-RET is a new line, not a commit; M-TAB is the regroup key (Tab itself
      ;; is the completion key now -- see the completion note in repl.scm)
      ((or (char=? c1 #\return) (char=? c1 #\newline)) 'm-return)
      ((char=? c1 #\tab) 'm-tab)
      ((or (char=? c1 #\[) (char=? c1 #\O))
       (let ((cs (read-csi port)))
         (csi-key (car cs) (cdr cs))))
      (else 'escape))))

;;; ESC [ params final.  Read the parameter bytes -- digits, ";", and the "?"
;;; or ">" a terminal's own report may open with -- up to the FINAL byte, which
;;; is a letter, or "~" for the numbered keys.
;;;
;;; Everything up to the final byte is consumed even when nothing below
;;; recognises it.  That is the point: an unknown sequence must not be left in
;;; the input, or its tail is read as TYPING.  The old reader matched "1", then
;;; demanded "~", saw the ";" of ESC [ 1 ; 5 D, gave up and left "5D" behind --
;;; so Ctrl-Left typed a literal 5D into the command line.
;;;
;;; Returns (PARAMS . FINAL); FINAL is #f if the sequence stopped early.
(define (read-csi port)
  (let lp ((acc '()))
    (let ((c (wait-char port)))
      (cond ((not c) (cons (list->string (reverse acc)) #f))
            ((or (char-alphabetic? c) (char=? c #\~))
             (cons (list->string (reverse acc)) c))
            ((or (char-numeric? c) (char=? c #\;) (char=? c #\?) (char=? c #\>))
             (lp (cons c acc)))
            (else (cons (list->string (reverse acc)) #f))))))

;;; A key with a modifier spells it "1;N", where N is 1 + shift(1) + alt(2) +
;;; ctrl(4) -- so 5 is Ctrl and 7 is Ctrl+Alt.  That parameter is the ONLY
;;; reason the two chords below can be told apart: the plain arrows are the
;;; same letters with no parameter at all.
(define (csi-key params final)
  (cond
   ((not final) 'escape)                      ; truncated: nothing to report
   ((string=? params "")
    (case final
      ((#\A) 'up)    ((#\B) 'down)
      ((#\C) 'right) ((#\D) 'left)
      ((#\H) 'home)  ((#\F) 'end)
      (else 'escape)))
   ;; the numbered keys end in "~": Delete, and Home/End in their two spellings
   ((char=? final #\~)
    (case (string->number params)
      ((3) 'delete)
      ((1 7) 'home)
      ((4 8) 'end)
      (else 'escape)))
   (else
    (let ((n (last-semicolon params)))
      (if n
          (modified-key (string->number (substring params (+ n 1)
                                                   (string-length params)))
                        final)
          'escape)))))

;;; The index of the last ";" in PARAMS, or #f.  (Written out rather than
;;; taken from srfi-13: this module imports nothing it does not need.)
(define (last-semicolon params)
  (let lp ((i (- (string-length params) 1)))
    (cond ((< i 0) #f)
          ((char=? #\; (string-ref params i)) i)
          (else (lp (- i 1))))))

;;; Only the four chords are named.  Shift-arrow and Alt-arrow (2 and 3) and
;;; everything else are consumed and reported as a bare escape -- unbound,
;;; which is what every unbound key does anyway.
(define (modified-key mod final)
  (case mod
    ((5) (case final ((#\C) 'c-right) ((#\D) 'c-left)     (else 'escape)))
    ((7) (case final ((#\C) 'c-m-right) ((#\D) 'c-m-left) (else 'escape)))
    (else 'escape)))

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
            ((char=? ch (integer->char 26)) 'suspend)     ; C-z
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

;;; Where the cursor was left, as an offset from the frame's FIRST column --
;;; not from the terminal's column 0.  The frame does not always start at 0
;;; (it follows whatever the program printed), so "go back to the start of the
;;; frame and clear it" has to be a relative move, and this is how far back.
(define *cursor-offset* 0)

;;; Is there a frame on the screen for the next DRAW to clear?
;;;
;;; LEAVE-FRAME! gives the frame up when output is about to be written -- a
;;; job's, or the shell's own -- and the line below is then the PROGRAM's, not
;;; the editor's.  A draw that goes on clearing it erases what the program
;;; printed: output that does not end in a newline (the everyday (display 'a))
;;; leaves the cursor mid-line, and the frame's "\r" + "\x1b[K" wiped it --
;;; the "evaluation prints nothing" bug.  With no frame to clear the prompt
;;; simply follows the output, which is what a shell's prompt does.
(define *frame-drawn?* #f)

;;; From wherever the cursor sits inside the drawn frame, down past its last
;;; line -- where output and the next prompt belong.
(define (leave-frame!)
  (let ((down (- *drawn-lines* *drawn-row*)))
    (display "\r")
    (let lp ((n down)) (when (positive? n) (display "\r\n") (lp (- n 1))))
    (set! *drawn-row* 0)
    (set! *drawn-lines* 1)
    (set! *cursor-offset* 0)
    (set! *frame-drawn?* #f)
    (force-output)))

(define (draw prompt text col row . opts)
  ;; OPTS: (bold standout) -- bold spans (as before) and, when STANDOUT is
  ;; #t, those spans render in reverse video (C-r's highlight) rather than
  ;; bold.  Existing callers pass just BOLD and get the old behaviour.
  (let* ((bold (if (pair? opts) (car opts) '()))
         (standout (and (pair? (cdr opts)) (cadr opts))))
    ;; only a frame that is still on the screen is cleared: after LEAVE-FRAME!
    ;; the cursor is below the old frame and the line it is on is the program's
    (when *frame-drawn?*
      (when (> *drawn-row* 0)              ; back up to the frame's home line
        (display (string-append "\x1b[" (number->string *drawn-row*) "A")))
      ;; ... and back to the frame's OWN first column.  "\r" would go to the
      ;; terminal's column 0, where the program's output is, and the "\x1b[K"
      ;; after it would wipe that output the moment a key was typed: the frame
      ;; is cleared from where it starts, not from where the line does.
      (when (> *cursor-offset* 0)
        (display (string-append "\x1b[" (number->string *cursor-offset*) "D")))
      (display "\x1b[K"))
    ;; PLAIN is the same lines with no styling: the cursor arithmetic below
    ;; counts COLUMNS, and the styled text carries "\x1b[1m" and friends, which
    ;; take no column at all but are characters like any other to STRING-LENGTH
    (let ((plain (split-newlines text))
          (lines (split-newlines (styled text bold standout))))
      (set! *drawn-row* row)
      (set! *drawn-lines* (length lines))
      (set! *frame-drawn?* #t)
      (display prompt)
      (display (car lines))
      (for-each (lambda (l) (display "\r\n\x1b[K") (display l)) (cdr lines))
      (display "\x1b[J")                    ; a shorter frame erases a taller one
      ;; Walk the cursor to (row, col) RELATIVE to where the drawing ended,
      ;; never to an absolute column.  A frame does not always begin in column
      ;; 0: after output that did not end in a newline it begins wherever the
      ;; program stopped -- "(a b c)" and then the prompt -- and an absolute
      ;; "\r" + count then parks the cursor INSIDE that output instead of after
      ;; the prompt.  Both positions are offsets from the frame's first column,
      ;; so that column cancels out of the difference and never needs knowing.
      ;;
      ;; row 0 carries the prompt, so its columns start after it; the other
      ;; lines start where the text does (its indentation is in the text)
      (let* ((n      (length lines))
             (end    (+ (if (= n 1) (string-length prompt) 0)   ; where drawing stopped
                        (string-length (list-ref plain (- n 1)))))
             (target (+ col (if (zero? row) (string-length prompt) 0)))
             (up     (- n 1 row))
             (delta  (- end target)))       ; >0: step back, <0: step forward
        (set! *cursor-offset* target)       ; where the next draw must rewind to
        (when (> up 0)
          (display (string-append "\x1b[" (number->string up) "A")))
        (cond ((> delta 0)
               (display (string-append "\x1b[" (number->string delta) "D")))
              ((< delta 0)
               (display (string-append "\x1b[" (number->string (- delta)) "C")))))
      (force-output))))

;;; ---- the completion listing -------------------------------------------------
;;; Bash's frame, drawn the same way: the bell first (the completion was
;;; ambiguous), then -- on the second Tab, LIST? -- the matches UNDER the line,
;;; and the next DRAW prints the prompt and the line again below them.  The
;;; matches are already on screen above; nothing is said twice.

(define ioctl (pointer->procedure int (dynamic-func "ioctl" libc)
                                  (list int unsigned-long '*)))
(define TIOCGWINSZ #x5413)                ; Linux's, as the termios constants are

;;; The terminal's size, as (COLUMNS . ROWS); 80x24 when there is no answer to
;;; get (no terminal, or a size the kernel will not give up).
(define (terminal-size)
  (let ((ws (make-bytevector 8 0)))
    (if (or (not (tty? 0))
            (< (ioctl 0 TIOCGWINSZ (bytevector->pointer ws)) 0))
        (cons 80 24)
        ;; struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ... }
        (let ((rows (bytevector-u16-native-ref ws 0))
              (cols (bytevector-u16-native-ref ws 2)))
          (cons (if (zero? cols) 80 cols) (if (zero? rows) 24 rows))))))

(define (terminal-width) (car (terminal-size)))
(define (terminal-height) (cdr (terminal-size)))

;;; The matches laid out the way readline lays them out, which was measured on a
;;; real bash rather than guessed: filled DOWN the columns and then across, each
;;; entry padded to the longest name plus two, in as many columns as the width
;;; holds.
;;;
;;; The column count is readline's arithmetic, and the "- 1" is the part that
;;; has to be measured rather than reasoned about: the last column of the
;;; terminal is not usable for it.  24 six-character names (the column width is
;;; therefore 8) come out as these, and every one of them is what bash printed:
;;;
;;;   width   columns   rows   the first row of the listing
;;;     40       4        6    file01  file07  file13  file19
;;;     60       7        4    file01  file05  file09  file13  file17  file21
;;;     70       8        3    file01  file04  ...  file22
;;;     80       9        3    the same eight names, then two empty columns
;;;     96      11        3    the same again
;;;    100      12        2    file01  file03  ...  file23
;;;
;;; (A column with nothing in its last row prints nothing, which is why 9 and 10
;;; columns look alike.)
(define (pad-to s n)
  (string-append s (make-string (max 0 (- n (string-length s))) #\space)))

;;; One line of the listing: each entry padded to the column width so the
;;; columns line up -- EXCEPT the last, which is left as it is.  Padding the
;;; last one is what makes a line reach past the terminal's width and wrap, and
;;; a wrapped line is what a name too long for the columns looks like: bash
;;; gives such a name a line of its own, unpadded, and this does too (one
;;; column, one entry, nothing to pad for).
(define (join-columns entries cw)
  (let lp ((es entries) (out '()))
    (if (null? es)
        (string-concatenate (reverse out))
        (lp (cdr es)
            (cons (if (null? (cdr es)) (car es) (pad-to (car es) cw)) out)))))

(define (candidate-rows names width)
  (let* ((cw   (+ (apply max (map string-length names)) 2))
         (cols (max 1 (quotient (- width 1) cw)))
         (n    (length names))
         (rows (max 1 (quotient (+ n (- cols 1)) cols)))
         (v    (list->vector names)))
    (let row ((r 0) (acc '()))
      (if (= r rows)
          (reverse acc)
          (row (+ r 1)
               (cons (join-columns (let col ((c 0) (acc* '()))
                                     (if (= c cols)
                                         (reverse acc*)
                                         (let ((i (+ r (* c rows))))   ; down, then across
                                           (col (+ c 1)
                                                (if (< i n)
                                                    (cons (vector-ref v i) acc*)
                                                    acc*)))))
                                   cw)
                     acc))))))

;;; readline asks before printing a great many of them -- completion-query-items,
;;; whose default is 100, and the test is >= rather than > (measured on bash:
;;; 99 matches list straight away, 100 ask).  Answering no leaves the question on
;;; screen and the line is drawn again below it, which is bash's frame.
(define %completion-query-items% 100)

(define (completion-query? n)
  (>= n %completion-query-items%))

;;; readline's yes-or-no: y, Y and space are yes, n, N and rubout are no, and
;;; any other key is a ding with the question still up (bash's Tab rings and
;;; asks again).
(define (y-or-n-key?)
  (let lp ()
    (let ((k (read-key)))
      (cond ((or (eqv? k #\y) (eqv? k #\Y) (eqv? k #\space)) #t)
            ((or (eqv? k #\n) (eqv? k #\N) (eq? k 'backspace)) #f)
            (else (display "\a") (force-output) (lp))))))

;;; ---- paging a long listing ---------------------------------------------------
;;; Readline pages its own listing, and this is that pager, measured on bash: a
;;; screenful is printed and then "--More--" on the LAST line, SPACE brings the
;;; next screenful (the prompt line is reused, so each one shows another
;;; height-1 rows), RET brings ONE more line, `q` stops and leaves the line to
;;; be drawn again, and any other key is a ding with "--More--" still waiting.
;;; The last page simply ends -- there is no "--More--" after it.
;;;
;;; (Measured at 24 rows and again at 10: 23 rows then "--More--", 9 rows then
;;; "--More--".)
(define (page-rows rows height key-reader)
  (let* ((per (max 1 (- height 1)))       ; the last line is the --More-- line
         (v   (list->vector rows))
         (n   (length rows)))
    (define (print-from i count)          ; -> where it stopped
      (let lp ((j i) (left count))
        (if (or (>= j n) (<= left 0))
            j
            (begin
              (display "\r\x1b[K\r")      ; the --More-- line is printed over
              (display (vector-ref v j))
              (display "\r\n")
              (lp (+ j 1) (- left 1))))))
    (let lp ((i 0) (count #f))            ; #f: the first page fills the screen
      (let ((i* (print-from i (or count per))))
        (if (>= i* n)
            #t
            (begin
              (display "\r\x1b[K\r") (display "--More--") (force-output)
              (let ((k (key-reader)))
                (cond ((eqv? k #\space) (lp i* per))   ; a screenful more
                      ((eq? k 'enter)   (lp i* 1))     ; one line more
                      ((eqv? k #\q)     #t)            ; stop
                      (else (display "\a") (force-output) (lp i* 0))))))))))

(define (list-matches names)
  (page-rows (candidate-rows names (terminal-width))
             (terminal-height)
             (lambda () (read-key))))

;;; The bell, or the listing -- measured: bash rings it on a Tab that could not
;;; extend the word, and rings it again on the next Tab rather than listing when
;;; there is nothing to list.  The listing itself is silent: the bell is rung
;;; once, when the word first would not grow.
(define (show-candidates names list?)
  (cond
    ((not (and list? (pair? names))) (display "\a"))
    ((completion-query? (length names))
     (leave-frame!)
     (display "Display all ") (display (length names))
     (display " possibilities? (y or n)")
     (force-output)
     (when (y-or-n-key?)
       (display "\r\n")
       (list-matches names)))
    (else
     (leave-frame!)                     ; out from under the line, as bash does
     (list-matches names)))
  (force-output))
