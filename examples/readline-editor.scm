#!/usr/bin/guile --no-auto-compile
!#
;;; The auto-wrapping scsh editor: the next step past readline-spike.scm.
;;;
;;; Every printable key is bound to a smart-insert rule:
;;;   g            -> (run (g))        first character wraps
;;;   s -l         -> (run (gs -l))    ...typing lands inside the slot
;;;   |            -> transforms to (run (| (ls -l) ())) ONLY when typed at
;;;                   the end of an exact (run (CMD)); otherwise the literal |
;;;   >            -> same deal, opens a (>) slot; otherwise the literal >
;;;   (            -> opens a new command slot at end of (run (CMD));
;;;                   otherwise the literal (    [so you can build
;;;                   |  by hand: arrow in and type]
;;;   )            inserted while balance allows; refused otherwise
;;;   Backspace    deletes any character (imbalance is repaired on Enter)
;;; Every key's fallback is LITERAL INSERTION: records assist, never block.
;;;
;;; Repaint rules learned from the spike:
;;;   * never write to the terminal from inside a callback -- readline owns
;;;     the screen; debug goes to /tmp/scsh-editor.log
;;;   * incremental rl_redisplay only -- rl_forced_update_display calls
;;;     rl_on_new_line() first, which makes readline reprint the PROMPT, so
;;;     every rewritten line doubled up the "scsh> " (and the next keystroke
;;;     painted at the wrong column).  Plain rl_redisplay repaints in place.
;;;   * Scheme strings -> bytevector-backed char* (call-with-cstr), alive
;;;     across the C call
;;;   * rl_replace_line does NOT move the point; set rl_point explicitly

(use-modules (system foreign)
             (ice-9 regex)
             (ice-9 textual-ports)
             (srfi srfi-13) (srfi srfi-14)
             (rnrs bytevectors)
             (scsh syntax) (scsh scsh) (scsh procobj) (scsh run-extras))

(define lib (dynamic-link "libreadline"))

(define C-readline      (pointer->procedure '* (dynamic-func "readline" lib) (list '*)))
(define C-add-history   (pointer->procedure void (dynamic-func "add_history" lib) (list '*)))
(define rl-bind-key     (pointer->procedure int  (dynamic-func "rl_bind_key" lib) (list int '*)))
(define rl-insert-text  (pointer->procedure int  (dynamic-func "rl_insert_text" lib) (list '*)))
(define rl-replace-line (pointer->procedure void (dynamic-func "rl_replace_line" lib) (list '* int)))
(define rl-redisplay     (pointer->procedure void (dynamic-func "rl_redisplay" lib) '()))
(define rl-ding         (pointer->procedure void (dynamic-func "rl_ding" lib) '()))
(define rl-line-buffer-ptr (dynamic-pointer "rl_line_buffer" lib))
(define rl-point-bv     (pointer->bytevector (dynamic-pointer "rl_point" lib) 4 0))

;;; ---------- logging (NEVER the terminal: readline is painting on it) ------

;;; NEVER do file I/O inside a key callback: writing a file from within
;;; readline's dispatch segfaults Guile's JIT (bisected with gdb: log!
;;; present -> crash, absent -> clean).  The keystroke journal is therefore
;;; opt-in (SCSH_TRACE=1), buffers in memory only, and is flushed to disk by
;;; the main loop AFTER readline returns.  Default build: zero I/O.
(define *trace-on* (getenv "SCSH_TRACE"))
(define *log-queue* '())
(define (log! . stuff)
  (when *trace-on*
    (set! *log-queue*
          (cons (call-with-output-string
                 (lambda (p)
                   (for-each (lambda (x) (display x p)) stuff)
                   (newline p)))
                *log-queue*))))

(define (flush-log!)
  (when (pair? *log-queue*)
    (let ((p (open-file "/tmp/scsh-editor.log" "al")))
      (for-each (lambda (line) (display line p)) (reverse *log-queue*))
      (close-port p)
      (set! *log-queue* '()))))

;;; ---------- buffer + cursor helpers ---------------------------------------

(define (buffer-text)
  ;; readline may hand us a NULL/empty buffer at odd moments (EOF, early
  ;; exit) -- never let the deref blow straight through to pointer->string.
  (let ((p (dereference-pointer rl-line-buffer-ptr)))
    (if (null-pointer? p) "" (pointer->string p))))

(define (set-point! where) (bytevector-u32-native-set! rl-point-bv 0 where))

(define (point) (bytevector-u32-native-ref rl-point-bv 0))

;;; Pin whatever we hand to C: string->utf8 may be a VIEW of the source
;;; string's own storage, so we must keep the string alive, not just the
;;; bytevector.  Unreferenced memory gets reused by other allocations and
;;; readline then reads regex text / status numbers as if they were the
;;; char we typed.  (Trim the tail so we don't grow without bound.)
(define *cstrs* '())
(define (call-with-cstr s thunk)
  ;; string->pointer is Guile's canonical "here is a C string" -- the pointer
  ;; is valid while the string lives, so pin the STRING (a fresh 1-char
  ;; string each keypress would otherwise be GC'd and its storage reused).
  (set! *cstrs* (cons s *cstrs*))
  (when (> (length *cstrs*) 512) (set! *cstrs* (list-head *cstrs* 256)))
  (thunk (string->pointer s)))

(define (replace-line! text where)
  (call-with-cstr text (lambda (p) (rl-replace-line p 1)))
  (set-point! where)
  (rl-redisplay))

;;; ---------- structural regexes --------------------------------------------

(define single-cmd-rx  (make-regexp "^\\(run \\(([^()]+)\\)\\)$"))
(define single-cmd-rx2 (make-regexp "^\\(run \\(([^()]+)\\)\\)$"))
(define (wrapped-single-cmd? buf)
  ;; returns the CMD string if buf is a complete (run (CMD)) form, else #f
  (let ((m (regexp-exec single-cmd-rx buf)))
    (and m (match:substring m 1))))

;;; ---------- rules ----------------------------------------------------------
;;; every rule: (state) -> success / refuse(ding).  Never touch stdout.

;;; "at the end": only closing brackets or spaces to the right of the
;;; cursor -- the template's own close-parens lie beyond the point while we
;;; type inside a slot, so point == length is the wrong test.
(define (at-end?)
  (not (string-any (lambda (c)
                      (and (not (char=? c #\)))
                           (not (char=? c #\space))))
                    (substring (buffer-text) (point)))))

;;; | : wrap the single command in a pipeline, open an empty slot
(define (pipe-cb count key)
  (catch #t
    (lambda ()
      (let ((cmd (wrapped-single-cmd? (buffer-text))))
        (if (and cmd (at-end?) (not (string-index (buffer-text) #\|)))
            (let* ((buf (buffer-text))
                   (new (string-append "(run (| (" cmd ") ()))")))
              (log! "| " buf " -> " new)
              (replace-line! new (- (string-length new) 3)))
            (begin
              (log! "| literal insert")
              (do-insert "|")))))
    (lambda (k . a) (log! "| ERR " k a)))
  0)

;;; > : append a redirection form with an empty filename slot
(define (redir-cb count key)
  (catch #t
    (lambda ()
      (let ((cmd (wrapped-single-cmd? (buffer-text))))
        (if (and cmd (at-end?) (not (string-index (buffer-text) #\>))
                 (not (string-index (buffer-text) #\<)))
            (let* ((buf (buffer-text))
                   (new (string-append "(run (" cmd ") (> ))")))
              (log! "> " buf " -> " new)
              (replace-line! new (- (string-length new) 2)))
            (begin
              (log! "> literal insert")
              (do-insert ">")))))
    (lambda (k . a) (log! "> ERR " k a)))
  0)

;;; ) : only accept while it keeps the buffer balanced; the template owns
;;;      the closing brackets, a spare one is refused with a ding
(define (paren-balance s)
  (- (string-count s #\() (string-count s #\))))

(define (do-insert s)
  (call-with-cstr s (lambda (p) (rl-insert-text p)))
  (rl-redisplay))

(define (rpare-cb count key)
  (catch #t
    (lambda ()
      (if (positive? (paren-balance (buffer-text)))
          (do-insert ")")
          (begin (log! ") refuse " (buffer-text)) (rl-ding))))
    (lambda (k . a) (log! ") ERR " k a)))
  0)

;;; Backspace : delete one char left of point, never a structural bracket
(define (bspace-cb count key)
  (catch #t
    (lambda ()
      (let* ((buf (buffer-text))
             (p   (point)))
        (if (or (zero? p) (string-null? buf))
            (begin (log! "bs refuse (nothing left)") (rl-ding))
            ; any character may be deleted; imbalance is repaired at Enter
            (let ((new-buf (string-replace buf "" (1- p) p)))
              (replace-line! new-buf (1- p))
              (log! "bs " buf " -> " new-buf)))))
    (lambda (k . a) (log! "bs ERR " k a)))
  0)

;;; smart-insert : the shell typing rule
;;;   empty buffer   ->  wrap:  X  ->  (run (X))  with point after X
;;;   otherwise      ->  plain insertion at the point
(define (smart-insert-cb count key)
  (catch #t
    (lambda ()
      (let* ((ch  (string (integer->char key)))
             (buf (buffer-text)))
        (cond ((and (string-null? buf) (char=? (integer->char key) #\space))
               (log! "si refuse (leading space)")
               (rl-ding))
              ((string-null? buf)
               (let ((new (string-append "(run (" ch "))")))
                 (log! "si wrap '" ch "' -> " new)
                 (replace-line! new 7)))
              (else
               (call-with-cstr ch (lambda (p) (rl-insert-text p)))
               (log! "si insert key=" key " '" ch "' len=" (string-length (buffer-text))
                     " -> " (buffer-text))))))
    (lambda (k . a) (log! "si ERR " k a)))
  0)

;;; ---------- install --------------------------------------------------------

;;; ( : ALWAYS inserts a matching ( ) pair with the cursor between -- an
;;; unbalanced buffer can never be produced by open-paren typing.  At the end
;;; of a form a space is added first, so  ls -l ( wc )  shapes up as a proper
;;; sibling form; anywhere else the pair is inserted bare.
(define (loparen-cb count key)
  (catch #t
    (lambda ()
      (let* ((b2   (buffer-text))
             (p    (point))
             (ipe  (if (at-end?)
                       (+ p (if (and (< p (string-length b2))
                                     (char=? (string-ref b2 p) #\)))
                                 1 0))
                       p))
             (pair (if (at-end?) " ()" "()")))
        (set-point! ipe)
        (call-with-cstr pair (lambda (x) (rl-insert-text x)))
        (set-point! (+ ipe (1- (string-length pair))))
        (rl-redisplay)
        (log! "( pair at " ipe " -> " (buffer-text))))
    (lambda (k . a) (log! "( ERR " k a)))
  0)

;;; ---------------------- TAB: rebalance machinery --------------------------
(define (scan-left-paren buf from)
  (let lp ((i (1- from)))
    (if (< i 0)
        #f
        (if (char=? (string-ref buf i) #\()
            i
            (lp (1- i))))))

(define (match-close buf open limit)
  (let lp ((i (1+ open)) (d 1))
    (cond ((>= i limit) #f)
          ((char=? (string-ref buf i) #\() (lp (1+ i) (1+ d)))
          ((char=? (string-ref buf i) #\)) (if (= d 1) (1+ i) (lp (1+ i) (1- d))))
          (else (lp (1+ i) d)))))

(define (match-open-back buf close)
  (let lp ((i (1- close)) (d 1))
    (cond ((< i 0) #f)
          ((char=? (string-ref buf i) #\)) (lp (1- i) (1+ d)))
          ((char=? (string-ref buf i) #\() (if (= d 1) i (lp (1- i) (1- d))))
          (else (lp (1- i) d)))))

(define (element-end buf i limit)
  (let ((i (skip-ws buf i limit)))
    (if (>= i limit)
        #f
        (if (char=? (string-ref buf i) #\()
            (match-close buf i limit)
            (let lp ((j (1+ i)))
              (cond ((>= j limit) j)
                    ((or (char=? (string-ref buf j) #\space)
                         (char=? (string-ref buf j) #\()
                         (char=? (string-ref buf j) #\))) j)
                    (else (lp (1+ j)))))))))

(define (skip-ws buf i limit)
  (let lp ((i i))
    (if (and (< i limit) (char=? (string-ref buf i) #\space))
        (lp (1+ i))
        i)))

(define (repair-line buf)
  (let ((opens (string-count buf #\())
        (closes (string-count buf #\))))
    (if (> opens closes)
        (string-append buf (make-string (- opens closes) #\)))
        (let lp ((i (string-length buf)))
          (if (or (= i 0)
                  (<= (string-count (substring buf 0 i) #\))
                      (string-count (substring buf 0 i) #\()))
              (substring buf 0 i)
              (lp (1- i)))))))

(define (move-close buf open close newclose)
  (replace-line! (string-append (substring buf 0 close)
                                (substring buf (1+ close) newclose)
                                ")"
                                (substring buf newclose))
                 (point)))

(define (scan-last-element buf start end)
  (let lp ((i start) (prev #f))
    (cond ((>= i end) prev)
          ((char=? (string-ref buf i) #\space) (lp (1+ i) prev))
          (else (let ((j (or (element-end buf i end) end)))
                  (lp j i))))))

(define (slurp-or-barf buf o c)
  (let* ((eo (scan-left-paren buf o))
         (limit (if eo
                    (or (match-close buf eo (string-length buf)) (string-length buf))
                    (string-length buf)))
         (tail (element-end buf (1+ c) limit)))
    (if tail
        (move-close buf o c tail)
        (let ((last (scan-last-element buf (1+ o) c)))
          (if (and last (< last c))
              (move-close buf o c last)
              (rl-ding))))))

(define (tab-rebalance-cb count key)
  (catch #t
    (lambda ()
      (let* ((buf (buffer-text))
             (p (point))
             (filled (- (string-count buf #\() (string-count buf #\)))))
        (if (not (zero? filled))
            (replace-line! (repair-line buf) (point))
            (let ((pair (if (and (> p 0) (char=? (string-ref buf (1- p)) #\)))
                            (let ((o (match-open-back buf (1- p))))
                              (and o (cons o (1- p))))
                            (let ((o (scan-left-paren buf p)))
                              (and o (cons o (match-close buf o (string-length buf))))))))
              (if pair
                  (slurp-or-barf buf (car pair) (cdr pair))
                  (rl-ding))))))
    (lambda (k . a) (log! "TAB ERR" k a)))
  0)



; PIN every trampoline handed to readline -- GC'd trampolines crash
(define *tramps* '())
(define (install! key proc)
  (let ((p (procedure->pointer int proc (list int int))))
    (set! *tramps* (cons p *tramps*))
    (rl-bind-key key p)))

;; structural keys first, then everything printable, so the loop below
;; does not clobber them.
(unless (getenv "SCSH_EDITOR_NO_LOOP")
  (install! 40  loparen-cb)         ; (
(install! 9   tab-rebalance-cb)    ; TAB
(install! 41  rpare-cb)          ; )
(install! 124 pipe-cb)           ; |
(install! 62  redir-cb)          ; >
(install! 127 bspace-cb)         ; DEL

(for-each (lambda (c)
            (if (not (memv c (list 40 41 62 124)))
                (install! c smart-insert-cb)))
          (iota 95 32)))         ; ASCII 32..126

;;; ---------- main loop ------------------------------------------------------

(display "scsh: type  ls -l  then  |  then  wc  then ENTER   (Ctrl-D quits)")
(newline)
(display "log:  tail -f /tmp/scsh-editor.log")
(newline)

;;; The line you see can drift from a template: readline's native navigation
;;; (arrow keys, C-a/C-e, ...) moves the point without telling us, so Enter
;;; NEVER evaluates the raw text blindly.  It is repaired to canonical scsh
;;; by GUESS-LINE first; a line that had to be rebuilt is echoed, then run.

;;; ------------------------------ the guesser -------------------------------

(define (strip-parens-to-spaces s)
  (string-map (lambda (c)
                (if (memv (char->integer c)
                          (list (char->integer #\() (char->integer #\))))
                    #\space
                    c))
              s))

(define (words s)
  (string-tokenize s (char-set-complement (string->char-set " \t"))))

(define (trailing-amp? s)
  (and (> (string-length s) 0)
       (char=? (string-ref s (1- (string-length s))) #\&)))

(define (redir-token? w)
  (or (string=? w ">") (string=? w ">>") (string=? w "2>")
      (string=? w "<") (string=? w "<<")))

(define (redir-form tok operand)
  (cond ((string=? tok ">")  (list (quote >) operand))
        ((string=? tok ">>") (list (quote >>) operand))
        ((string=? tok "2>") (list (quote >) 2 operand))
        ((string=? tok "<")  (list (quote <) operand))
        (else                (list (quote <<) operand))))

;; split a segment's words into (redir-forms . command-words)
(define (segment->parts ws)
  (let lp ((in ws) (cmd (quote ())) (redirs (quote ())))
    (cond ((null? in) (cons (reverse redirs) (reverse cmd)))
          ((redir-token? (car in))
           (if (null? (cdr in))
               (cons (reverse redirs) (reverse cmd))
               (lp (cddr in) cmd
                   (cons (redir-form (car in) (cadr in)) redirs))))
          (else (lp (cdr in) (cons (car in) cmd) redirs)))))

;; split a word list into ""|""-separated segments
(define (split-on-pipe ws)
  (let lp ((in ws) (cur (quote ())) (out (quote ())))
    (cond ((null? in) (reverse (cons (reverse cur) out)))
          ((string=? (car in) "|")
           (lp (cdr in) (quote ()) (cons (reverse cur) out)))
          (else (lp (cdr in) (cons (car in) cur) out)))))

(define (build-run s)
  ;; s is shell-ish, parens already stripped.  returns #f or (repaired? datum)
  (let* ((bg (trailing-amp? s))
         (s2 (if bg (string-drop-right s 1) s))
         (ws (words s2)))
    (let ((ws (if (and (pair? ws) (string=? (car ws) "run")) (cdr ws) ws)))
      (if (null? ws)
          #f
          (let* ((segs (split-on-pipe ws))
                 (all (map segment->parts segs))
                 (redirs (apply append (map car all)))
                 (cmds (filter (lambda (c) (pair? c)) (map cdr all))))
            (if (null? cmds)
                #f
                (let* ((pipe (if (null? (cdr cmds))
                                 (car cmds)
                                 (cons (quote |) cmds))))
                  (cons #t (cons (if bg (quote &) (quote run))
                                 (append (list pipe) redirs))))))))))

;; raw line -> #f (nothing to do) or (REPAIRED? . datum)
(define (guess-line raw)
  (let ((s (string-trim raw)))
    (cond ((or (string-null? s) (string-prefix? ";" s)) #f)
          ((string-prefix? "(" s)
           (let ((port (open-input-string s)))
             (let ((d (catch #t
                            (lambda () (read port))
                            (lambda (k . a) (quote unreadable)))))
               (cond ((eq? d (quote unreadable))
                      (or (try-close-read s)
                          (build-run (strip-parens-to-spaces s))))
                     ((eof-object? d)
                      (or (try-close-read s)
                          (build-run (strip-parens-to-spaces s))))
                     ((not (eof-object? (peek-char port)))
                      (let ((tail (get-string-all port)))
                        (if (only-closer-tail? tail)
                            ;; stray closes after a valid form: drop + echo
                            (cons #t d)
                            ;; real junk -> conservative single command
                            (build-run (strip-parens-to-spaces s)))))
                     (else (cons #f d))))))
          (else (build-run (strip-parens-to-spaces s))))))

;;; ---------- structural validation / smart rebalancing ------------------
;;; A datum can READ fine yet be structurally invalid scsh -- e.g. a redirection
;;; form with no operand -- and scsh's transcriber then raises its internal
;;; "(oops)" marker, which escapes as "Unbound variable: oops".  Enter therefore
;;; also checks that run/&-headed datums TRANSCRIBE; if not, they are repaired.
(define (transcribe-fine? d)
  (if (and d (pair? d) (memv (car d) (list (quote run) (quote &))))
      (catch #t
        (lambda () (macroexpand d (current-module)) #t)
        (lambda (k . a) #f))
      #t))

(define (only-closer-tail? s)
  (let ((n (string-length s)))
    (let lp ((i 0))
      (or (= i n)
          (and (let ((c (string-ref s i)))
                 (or (char=? c #\))
                     (char=? c #\space)
                     (char=? c #\tab)))
               (lp (1+ i)))))))

;;; If parens don't balance, prefer CLOSING them (preserving the structure the
;;; user built) over the strip-to-words fallback -- but only when the closed-up
;;; text reads AND transcribes.
(define (try-close-read s)
  (let ((missing (- (string-count s #\() (string-count s #\)))))
    (if (> missing 0)
        (let* ((cand (string-append s (make-string missing #\))))
               (port (open-input-string cand))
               (d (catch #t
                        (lambda () (read port))
                        (lambda (k . a) (quote unreadable)))))
          (if (and (not (eq? d (quote unreadable)))
                   (not (eof-object? d))
                   (eof-object? (peek-char port))
                   (transcribe-fine? d))
              (cons #t d)
              #f))
        #f)))

;;; ------------------------------ the loop ----------------------------------

(unless (getenv "SCSH_EDITOR_NO_LOOP")
  (let loop ()
    (let ((line (C-readline (string->pointer "scsh> "))))
    (flush-log!)
    (cond ((null-pointer? line) (newline) (quit))
          (else
           (let* ((raw (pointer->string line))
                  (g   (guess-line raw))
                  (g   (if (transcribe-fine? (and g (cdr g)))
                           g
                           (let ((ng (build-run (strip-parens-to-spaces raw))))
                             (if ng (cons #t (cdr ng)) ng)))))
             (if g
                 (begin
                   (C-add-history line)
                   (if (car g)
                       (begin (display "repair: ") (write (cdr g)) (newline)))
                   (catch #t
                     (lambda ()
                       (write (eval (cdr g) (interaction-environment)))
                       (newline)
                       (loop))
                     (lambda (k . args)
                       (display "error evaluating ") (write (cdr g))
                       (display ": ") (display k) (display " " ) (display args)
                       (newline)
                       (loop))))
                 (loop))))))))
