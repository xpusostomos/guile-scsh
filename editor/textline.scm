;;; editor/textline.scm -- the unstructured line editor.
;;;
;;; ESC toggles between the structure editor and this one.  Here the line is
;;; plain text, edited the readline way: characters insert at the point,
;;; backspace/delete, left/right/home/end, UP/DOWN recall the same history the
;;; structure editor recalls, enter commits, C-c aborts the line, C-d ends the
;;; shell on an empty line and deletes forward otherwise.  It is NOT GNU
;;; readline -- the FFI readline gets no input in this environment (see the
;;; editor architecture notes) -- it is the same raw terminal the structure
;;; editor drives, with a text buffer instead of a tree.
;;;
;;; A committed line is PURE SCHEME: it is read as Scheme and committed, and
;;; the shell's own commit does the rest -- a leading , is the marker for a
;;; value line (,car shows the procedure), and run/& forms get job control.
;;; The datum becomes a tree with history's datum->tree, so committed lines
;;; enter the same history either editor recalls.

(define-module (editor textline)
  #:use-module (ice-9 receive)
  #:use-module (ice-9 textual-ports)  ; get-string-all
  #:use-module (editor term)
  #:use-module (editor render)
  #:use-module (editor history)
  #:export (text-loop text-line text-commit-tree text-carry-tree))

;;; ---- the pure loop ----------------------------------------------------------
;;; TEXT-LOOP drives the buffer with any key source and any display, so the
;;; whole thing is testable with no terminal at all; TEXT-LINE is the same
;;; loop on the tty.  The state is (BUFFER POINT RECALL-INDEX DRAFT): POINT is
;;; the cursor in the buffer; the RECALL-INDEX is an index into the history
;;; items, one past the last meaning "showing the draft"; the DRAFT is the
;;; buffer as it was when recall began.

(define (text-loop key-reader draw initial-text . maybe-sdraw)
  (let ((search-draw (if (pair? maybe-sdraw) (car maybe-sdraw) #f)))
    (let lp ((buf initial-text)
             (pt  (string-length initial-text))
             (idx (length (history-items)))
             (draft "")
             (pending #f))            ; a key the search accepted and left over
      (draw buf pt)
      (let ((key (or pending (key-reader))))
        (cond
          ((eq? key 'enter)    (values buf 'evaluate))
          ((eq? key 'escape)   (values buf 'structured))
          ((eq? key 'interrupt) (values buf 'interrupt))
          ;; C-z at the prompt is inert, as bash's is: the line stays
          ;; C-d is bash's: forward-delete, or end the shell on an empty line
          ((eq? key 'eof)
           (if (string-null? buf)
               (values buf 'exit)
               (lp (string-append (substring buf 0 pt)
                                  (substring buf (+ pt 1)))
                   pt idx draft #f)))
          ((eq? key 'left)     (lp buf (max 0 (- pt 1)) idx draft #f))
          ((eq? key 'right)    (lp buf (min (string-length buf) (+ pt 1)) idx draft #f))
          ((eq? key 'home)     (lp buf 0 idx draft #f))
          ((eq? key 'end)      (lp buf (string-length buf) idx draft #f))
          ((eq? key 'delete)   ; the Del key: forward delete
           (if (< pt (string-length buf))
               (lp (string-append (substring buf 0 pt)
                                  (substring buf (+ pt 1)))
                   pt idx draft #f)
               (lp buf pt idx draft #f)))
          ((eq? key 'backspace)
           (if (positive? pt)
               (lp (string-append (substring buf 0 (- pt 1))
                                  (substring buf pt))
                   (- pt 1) idx draft #f)
               (lp buf pt idx draft #f)))
          ((eq? key 'up)       ; recall: the previous history item
           (if (zero? idx)
               (lp buf pt idx draft #f)            ; nothing older
               (lp (render-tree (list-ref (history-items) (- idx 1)))
                   (string-length (render-tree
                                   (list-ref (history-items) (- idx 1))))
                   (- idx 1)
                   (if (= idx (length (history-items))) buf draft)
                   #f)))
          ((eq? key 'down)     ; recall: the next item, or back to the draft
           (if (= idx (length (history-items)))
               (lp buf pt idx draft #f)            ; nothing newer
               (let ((n (+ idx 1)))
                 (if (= n (length (history-items)))
                     (lp draft (string-length draft) n draft #f)
                     (let ((s (render-tree (list-ref (history-items) n))))
                       (lp s (string-length s) n draft #f))))))
          ((equal? key C-r)    ; the backward search (text-search below)
           (receive (b a pk) (text-search key-reader search-draw buf)
             (if (eq? a 'abort)
                 (lp b pt idx draft #f)         ; the line as C-r found it
                 (lp b (string-length b) idx draft pk))))
          ;; a printable character inserts at the point; anything else the
          ;; terminal sent is ignored
          ((and (char? key) (char>=? key #\space))
           (lp (string-append (substring buf 0 pt)
                              (string key)
                              (substring buf pt))
               (+ pt 1) idx draft #f))
          (else (lp buf pt idx draft #f)))))))

(define C-r (integer->char 18))
(define C-g (integer->char 7))

;;; ---- C-r: the backward search in text mode ----------------------------------
;;; bash's C-r, with the same keys the structure editor's search takes: the
;;; frame is (reverse-i-search)`query: match` with only the matched span in
;;; reverse video, each letter narrows, C-r steps one match further back,
;;; backspace un-narrows, enter accepts the match as the line, escape accepts
;;; and keeps editing, C-g aborts to the line as C-r found it, and any other
;;; key accepts the match and is then processed as if just typed.  The match
;;; is the item's rendered line, so what lands in the buffer is what would
;;; have been on screen in the structure editor -- and it re-reads, since
;;; rendered trees are readable text.  Returns (values BUFFER ACTION KEY):
;;; action 'accept (buffer is the match, KEY still to process or #f) or
;;; 'abort (buffer unchanged).

(define (text-search key-reader frame-draw buf)
  (define (the-match pos failed)
    (if (and pos (not failed))
        (render-tree (list-ref (history-items) pos))
        buf))
  (let lp ((query "") (pos #f) (failed #f))
    (when frame-draw
      (frame-draw query
                  (and pos (not failed)
                       (render-tree (list-ref (history-items) pos)))
                  failed))
    (let ((key (key-reader)))
      (cond
        ((equal? key C-r)         ; one match further back
         (let ((i (history-search query
                                  (max 0 (- (or pos (length (history-items))) 1)))))
           (lp query i (not i))))
        ((eq? key 'backspace)     ; un-narrow
         (let* ((q (if (positive? (string-length query))
                       (substring query 0 (- (string-length query) 1))
                       query))
                (i (history-search q (or pos (length (history-items))))))
           (lp q i (not i))))
        ((and (char? key) (char>? key #\space))   ; narrow
         (let* ((q (string-append query (string key)))
                (i (history-search q (or pos (length (history-items))))))
           (lp q i (not i))))
        ((eq? key 'escape)        ; accept, keep editing
         (values (the-match pos failed) 'accept #f))
        ((eq? key 'enter)         ; accept, commit
         (values (the-match pos failed) 'accept #f))
        ((equal? key C-g)         ; abort: the line as C-r found it
         (values buf 'abort #f))
        (else                     ; accept, then the key runs as usual
         (values (the-match pos failed) 'accept key))))))

;;; the same loop on the terminal
(define* (text-line #:key (prompt "scsh$ ") (initial ""))
  (with-raw-term
   (lambda ()
     (receive (text action)
         (text-loop read-key
                    (lambda (buf pt) (draw prompt buf pt 0 '()))
                    initial
                    ;; bash's C-r frame: the query rides in the prompt, the
                    ;; match is the line, and only the matched span is in
                    ;; reverse video -- the same frame the structure editor's
                    ;; search draws, the span and its case rule the search's
                    ;; own (history's match-span).  The failed frame shows
                    ;; the query, unhighlighted.
                    (lambda (query match failed)
                      (let* ((text (if (and match (not failed)) match query))
                             (span (and match (not failed)
                                        (match-span query match))))
                        (draw (if failed
                                  "(failed reverse-i-search)`': "
                                  "(reverse-i-search)`': ")
                              text
                              (string-length text)
                              0
                              (if span (list span) '())
                              #t))))
       (leave-frame!)                   ; out from inside the frame, below it
       (values text action)))))

;;; ---- the ! escape: a line for the standard shell -----------------------------
;;; A text line starting with ! sends the rest of the line, verbatim, to the
;;; standard shell.  The tree is the marker word ! hugging the command string
;;; ("!" "ls -l", rendered "!ls -l", stored as the readable datum
;;; (! "ls -l")); its meaning -- (run (SH -c "...")) -- lives in the shell
;;; layer (editor/scsh.scm), and the structure editor's ! trigger opens the
;;; same tree.  The command is never read as Scheme at all.

;;; ---- a committed line is pure Scheme ----------------------------------------
;;; The text line is read as Scheme and committed, nothing more: the shell's
;;; own commit then does the rest (a leading , is the marker for a value
;;; line, and run/& forms get job control).  One datum per line, as the
;;; history format is; a line that does not read reports the error and
;;; commits nothing.  Shell commands are typed the scsh way: (run (ls -l)).

(define (text-commit-tree text)
  (let ((s (string-trim-both text)))
    (cond ((string-null? s) '())
          ((string-prefix? "!" s)
           ;; a bourne-shell line: the rest of the line, verbatim, hugs the
           ;; ! marker -- it never touches the Scheme reader at all
           (list "!" (substring s 1)))
          (else
           (let ((p (open-input-string s)))
             (let ((d (catch #t
                        (lambda () (read p))
                        (lambda (key . args)
                          (display "error: unreadable: ")
                          (write key)
                          (newline)
                          'read-error))))
               (cond ((eq? d 'read-error) '())
                     ((eof-object? d) '())   ; a comment line says nothing
                     ((string-null?
                       (string-trim-both (get-string-all p)))
                      ;; a bare word is a value line: the tree carries it as
                      ;; the comma marker (,car), which commits as the value
                      ;; it names -- the tree model only ever holds forms
                      (datum->tree (if (pair? d) d (list 'unquote d))))
                     (else
                      (display "error: one form per line")
                      (newline)
                      '()))))))))

;;; for the ESC handoff: the half-typed text becomes a tree to keep editing.
;;; An unclosed form is closed so the work survives the crossing -- this is
;;; editor plumbing, not what the line will mean.  A bare word crosses as the
;;; value line it is (,car): the tree model only ever holds forms.
(define (text-carry-tree text)
  (let ((s (string-trim-both text)))
    (cond ((string-prefix? "!" s) (list "!" (substring s 1)))
          ((string-null? s) '())
          (else
           (let ((p (open-input-string s)))
             (let ((d (catch #t
                        (lambda () (read p))
                        (lambda args 'unreadable))))
               (cond ((or (eq? d 'unreadable) (eof-object? d))
                      (let ((g (try-close-read s)))
                        (if g (datum->tree (cdr g)) '())))
                     (else (datum->tree (if (pair? d) d (list 'unquote d)))))))))))

;;; if parens don't balance, closing them is the one repair the crossing
;;; makes -- and only when the closed-up text reads
(define (try-close-read s)
  (let ((missing (- (string-count s #\() (string-count s #\)))))
    (if (> missing 0)
        (let* ((cand (string-append s (make-string missing #\))))
               (port (open-input-string cand))
               (d (catch #t
                    (lambda () (read port))
                    (lambda args 'unreadable))))
          (if (and (not (eq? d 'unreadable))
                   (not (eof-object? d))
                   (eof-object? (peek-char port)))
              (cons #t d)
              #f))
        #f)))
