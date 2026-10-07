;;; structured-scsh/repl.scm -- the structural REPL loop.
;;;
;;; Every key is handed to DISPATCH-KEY, a pure function from (tree locus key)
;;; to (tree' locus' action).  The action is 'continue to keep editing,
;;; 'evaluate when the user commits with Enter, or 'exit on EOF / C-c.
;;;
;;; RUN-LOOP drives that with any key source, any display and any KEY TABLE, so the whole loop
;;; is testable with no terminal at all; EDIT-LINE is the same loop wired to the
;;; tty.  Evaluating the committed tree is the caller's business -- the editor
;;; produces a well-formed tree and hands it over.

(define-module (structured-scsh repl)
  #:use-module (ice-9 receive)
  #:use-module (ice-9 optargs)
  #:use-module (srfi srfi-9)      ; define-record-type
  #:use-module (structured-scsh engine)
  #:use-module (structured-scsh render)
  #:use-module (structured-scsh term)
  #:use-module (structured-scsh history)
  #:use-module (structured-scsh properties)
  #:export (make-rule rule? rule-match rule-handle core-rules dispatch-key step run-loop edit-line
            search-enter search-rescan search-accept C-r C-g))

;;; ---- the key table ----------------------------------------------------------
;;; ONE dispatch mechanism instead of three: an ordered table of RULES.  A rule
;;; is (MATCH HANDLE):
;;;
;;;   MATCH:   key -> #f | anything          which keys the row is for
;;;   HANDLE:  tree locus key -> (values tree locus action handled?)
;;;
;;; HANDLED? #f DECLINES -- the walk moves on to the next row -- so "assist,
;;; never block" is the walker's shape rather than a convention.  The rows are
;;; ordered most-specific first: the shell's policy rows (from structured-scsh/scsh.scm,
;;; prepended by whoever runs the shell), then the editor's structural and
;;; control rows, then the printer, which always handles.  The table is passed
;;; through the whole machinery, so a user can supply a different one; a global
;;; default is composed at the top (structured-scsh/run.scm).
(define-record-type <rule>
  (make-rule match handle)
  rule?
  (match rule-match)
  (handle rule-handle))

(define (finish tree locus action)
  (values tree locus action #t))

(define (done tree locus)
  (finish tree locus 'continue))

;;; the EDITOR's rows.  ( and ) are structural at the editor level -- Scheme's
;;; brackets, nothing to do with shells; control keys likewise.
(define core-rules
  (list
   (make-rule (lambda (k) (eq? k 'enter))     (lambda (t l k) (finish t l 'evaluate)))
   (make-rule (lambda (k) (eq? k 'eof))       (lambda (t l k) (finish t l 'exit)))
   (make-rule (lambda (k) (eq? k 'interrupt)) (lambda (t l k) (finish t l 'exit)))
   (make-rule (lambda (k) (eq? k 'left))      (lambda (t l k) (done t (move-left t l))))
   (make-rule (lambda (k) (eq? k 'right))     (lambda (t l k) (done t (move-right t l))))
   ;; up/down recall the history (structured-scsh/history.scm): the structural move-up
   ;; and move-down keep their functions but no longer own these keys
   (make-rule (lambda (k) (eq? k 'up))
         (lambda (t l k) (receive (t2 l2) (history-previous t l) (done t2 l2))))
   (make-rule (lambda (k) (eq? k 'down))
         (lambda (t l k) (receive (t2 l2) (history-next t l) (done t2 l2))))
   (make-rule (lambda (k) (eq? k 'home))      (lambda (t l k) (done t (move-home t l))))
   (make-rule (lambda (k) (eq? k 'end))       (lambda (t l k) (done t (move-end t l))))
   (make-rule (lambda (k) (eq? k 'backspace))
         (lambda (t l k) (receive (t2 l2) (delete-left t l)  (done t2 l2))))
   (make-rule (lambda (k) (eq? k 'delete))
         (lambda (t l k) (receive (t2 l2) (delete-right t l) (done t2 l2))))
   (make-rule (lambda (k) (eq? k 'm-return))
         (lambda (t l k) (receive (t2 l2) (insert-break t l) (done t2 l2))))
   ;; M-TAB is intercepted by the loop, which remembers which way it is going;
   ;; the row is here so a direct dispatch still does the plain regroup.  Tab
   ;; itself completes now (the shell's hook, see RUN-LOOP) and so has no row:
   ;; a completion needs the filesystem and the two-Tab state, neither of which
   ;; a pure rule can hold.
   (make-rule (lambda (k) (eq? k 'm-tab))
         (lambda (t l k) (receive (t2 l2) (transpose-node t l) (done t2 l2))))
   (make-rule (lambda (k) (eq? k #\()) (lambda (t l k) (receive (t2 l2) (insert-form t l) (done t2 l2))))
   (make-rule (lambda (k) (eq? k #\))) (lambda (t l k) (receive (t2 l2) (leave-form t l) (done t2 l2))))
   (make-rule (lambda (k) (eq? k #\;)) (lambda (t l k) (receive (t2 l2) (wrap-begin t l)  (done t2 l2))))
   ;; the printer: the last row, and it always handles -- a printable character
   ;; is typed, anything that reached it (control characters, unknown keys) is
   ;; ignored.  This is the "ultimate fallback is print as-is" rule.
   (make-rule (lambda (k) #t)
         (lambda (t l k)
           (if (and (char? k) (char>=? k #\space))
               (receive (t2 l2) (insert-char t l k) (done t2 l2))
               (done t l))))))

;;; (dispatch-key TREE LOCUS KEY [#:rules TABLE]) -> (values TREE' LOCUS' ACTION)
;;; Walk the table; the first row that matches AND handles wins.  Declining)
;;; rows cost nothing but a skip.
(define* (dispatch-key tree locus key #:key (rules #f))
  (let lp ((rs (or rules core-rules)))
    (if (null? rs)
        (done tree locus)                       ; nothing handled: ignore
        (if ((rule-match (car rs)) key)
            (call-with-values (lambda () ((rule-handle (car rs)) tree locus key))
              (lambda (t l a handled?)
                (if handled? (values t l a) (lp (cdr rs)))))
            (lp (cdr rs))))))

;;; ---- C-r: the backward search ------------------------------------------------
;;; The state is (QUERY POS FAILED MATCH-TREE SAVED-TREE SAVED-LOCUS): POS is
;;; the index of the current match in the history (#f when the query matches
;;; nothing), MATCH-TREE that item's tree.  SAVED-* is the line as C-r found
;;; it -- what C-g gives back and what a FAILED search accepts.  Each letter
;;; narrows (the newest match for the longer query), C-r steps one match
;;; further back, backspace un-narrows, enter accepts and commits, escape
;;; accepts and keeps editing, C-g aborts; any other key accepts the match and
;;; then runs as it would have.
(define (search-enter tree locus)
  ;; bash's C-r starts EMPTY: the frame shows the query and nothing else, and
  ;; the first typed letter picks the newest match.  Nothing is selected yet,
  ;; so a bare C-r RET commits the line as C-r found it, exactly as bash's
  ;; empty query does.
  (list "" #f #f #f tree locus))

(define (search-rescan state query from)
  (let ((i (history-search query from)))
    (if i
        (list query i #f (list-ref (history-items) i)
              (list-ref state 4) (list-ref state 5))
        (list query #f #t #f
              (list-ref state 4) (list-ref state 5)))))

(define (search-accept state)
  ;; state: (QUERY POS FAILED MATCH-TREE SAVED-TREE SAVED-LOCUS)
  (if (and (list-ref state 1) (not (list-ref state 2)))
      (let ((t (list-ref state 3)))
        (values t (make-locus '() (length t) 0)))
      (values (list-ref state 4) (list-ref state 5))))

(define C-r (integer->char 18))
(define C-g (integer->char 7))

;;; One step: an empty line is where a line begins, so if the document is empty
;;; and a printable character arrives, the shell is asked what that first
;;; keystroke OPENS -- a shell command, a plain Scheme form, or nothing at all.
;;; It may take the keystroke as the thing it opened (a "(" is the form's own
;;; opening paren, not a character to type); otherwise the character is typed
;;; into whatever it opened.  Absent a seed, dispatch is all there is.
;;; the cursor is at a toplevel slot of a (begin ...) body -- not on the head
;;; word, and not inside a word: the begin body is a second prompt, and the
;;; shell is consulted there exactly as on an empty line
(define (begin-slot? tree locus)
  (and (pair? tree)
       (string? (car tree)) (string=? (car tree) "begin")
       (null? (locus-path locus))
       (> (locus-index locus) 0)
       (zero? (locus-offset locus))))

(define (step tree locus key seed rules)
  (cond ((and seed (null? tree) (char? key) (char>? key #\space))
         (receive (t l taken?) (seed key)
           (if taken?
               (values t l 'continue)
               (dispatch-key t l key #:rules rules))))
        ((and seed (begin-slot? tree locus) (char? key) (char>? key #\space))
         ;; the seed answers what the keystroke OPENS: its line is spliced at
         ;; the cursor and the keystroke is typed into it (or taken outright)
         (receive (t l taken?) (seed key)
           (if (null? t)
               (values tree locus 'continue)  ; opened nothing: swallow
               (let* ((i  (locus-index locus))
                      (t* (splice tree i t))
                      (l* (make-locus (append (list i) (locus-path l))
                                      (locus-index l) (locus-offset l))))
                 (if taken?
                     (values t* l* 'continue)
                     (dispatch-key t* l* key #:rules rules))))))
        (else (dispatch-key tree locus key #:rules rules))))

;;; (run-loop KEY-READER DRAW TREE LOCUS [#:seed SEED]) -> (values TREE LOCUS ACTION)
;;; KEY-READER: () -> key       DRAW: (text col row bold) -> unspecified
;;; BOLD is the rendering's styling (the form the cursor is in), which a
;;; terminal draws and a test can simply read; a key source without a terminal
;;; is free to ignore it.
;;; SEED: (key) -> (values tree locus taken?), what the first keystroke opens
;;;
;;; COMPLETE: (tree locus) -> (values tree locus candidates) -- what Tab does.
;;; The hook is the SHELL's (structured-scsh/complete.scm), because the editor
;;; has no more idea of a file name than it has of "run"; a loop without one
;;; simply ignores Tab.  #f for CANDIDATES means the word was completed; a LIST
;;; -- empty when nothing matched -- means there was nothing to complete with,
;;; which is the bell, and, on a second Tab, the listing:
;;; CANDIDATES-HOOK: (names list?) -> unspecified, where LIST? says whether this
;;; Tab could not extend the word either -- the second Tab in a row that made no
;;; progress, which is bash's rule for showing the matches (complete.scm has the
;;; measurements).
(define* (run-loop key-reader draw initial-tree initial-locus
                    #:key (seed #f) (rules #f) (search-draw #f)
                    (complete #f) (candidates #f))
  (let loop ((tree initial-tree) (locus initial-locus)
             (direction 'slurp) (stalled? #f))
    (receive (text col row bold) (render tree locus)
      (draw text col row bold))
    (let ((key (key-reader)))
      (cond
        ((eq? key 'm-tab)
         ;; M-TAB moves the boundary of the form the cursor is in, and keeps
         ;; going that way until it runs out of room, then turns round: pressing
         ;; it repeatedly walks through every grouping of that form.  Any other
         ;; key forgets the direction, so the next M-TAB starts by opening it
         ;; out.  (Tab used to do this; Tab completes now.)
         (receive (t l dir) (regroup tree locus direction)
           (loop t l dir #f)))
        ((eq? key 'tab)
         ;; Tab completes the word the cursor is in, through the shell's hook.
         ;; STALLED? is carried across the Tab the way the regroup direction is
         ;; carried across an M-TAB: a Tab that extended the word starts the
         ;; count over, and only a second Tab that could not starts the listing.
         (if complete
             (receive (t l names) (complete tree locus)
               (if names
                   (begin (when candidates (candidates names stalled?))
                          (loop t l direction #t))
                   (loop t l direction #f)))
             (loop tree locus direction #f)))
        ((equal? key C-r)
         ;; the backward search, driven as its own loop; it returns the line
         ;; it ended on and an action for this loop to honour: 'continue,
         ;; 'evaluate, or ('key K) -- accept the match and run K as usual
         (receive (t l a) (search-mode key-reader search-draw
                                       (search-enter tree locus))
           (cond ((eq? a 'continue) (loop t l 'slurp #f))
                 ((and (pair? a) (eq? (car a) 'key))
                  (receive (t2 l2 action) (step t l (cadr a) seed rules)
                    (if (eq? action 'continue)
                        (loop t2 l2 'slurp #f)
                        (values t2 l2 action))))
                 (else (values t l a)))))
        (else
         (receive (t l action) (step tree locus key seed rules)
           (if (eq? action 'continue)
               (loop t l 'slurp #f)
               (begin
                 (receive (text col row bold) (render t l)
                   (draw text col row bold))
                 (values t l action)))))))))

;;; C-r's own loop: the frame is the search prompt, the keys are its own.
;;; Returns (values TREE LOCUS ACTION): 'continue to keep editing the line it
;;; ended on, 'evaluate to commit it.
(define (search-mode key-reader search-draw state)
  (let lp ((state state))
    (when search-draw
      (search-draw (list-ref state 0)
                   (let ((m (list-ref state 3)))
                     (and m (not (list-ref state 2)) (render-tree m)))
                   (list-ref state 2)))
    (let ((key (key-reader)))
      (cond
        ((equal? key C-r)          ; one match further back
         (lp (search-rescan state (list-ref state 0)
                             (max 0 (- (or (list-ref state 1)
                                           (length (history-items)))
                                       1)))))
        ((eq? key 'backspace)      ; un-narrow
         (let ((query (list-ref state 0)))
           (lp (search-rescan state
                              (if (positive? (string-length query))
                                  (substring query 0 (- (string-length query) 1))
                                  query)
                              (or (list-ref state 1) (length (history-items)))))))
        ((and (char? key) (char>? key #\space))   ; narrow
         (lp (search-rescan state
                            (string-append (list-ref state 0) (string key))
                            (or (list-ref state 1) (length (history-items))))))
        ((eq? key 'escape)         ; accept, keep editing
         (call-with-values (lambda () (search-accept state))
           (lambda (t l) (values t l 'continue))))
        ((eq? key 'enter)          ; accept, commit
         (call-with-values (lambda () (search-accept state))
           (lambda (t l) (values t l 'evaluate))))
        ((equal? key C-g)          ; abort: the line as C-r found it
         (values (list-ref state 4) (list-ref state 5) 'continue))
        (else                      ; accept, then the key runs as usual
         (call-with-values (lambda () (search-accept state))
           (lambda (t l) (values t l (list 'key key)))))))))

;;; the same loop on a terminal
(define* (edit-line initial-tree initial-locus
                     #:key (prompt "scsh> ") (seed #f) (rules #f) (search-draw #f)
                     (complete #f) (candidates #f))
  (with-raw-term
   (lambda ()
     (receive (tree locus action)
         (run-loop (lambda () (read-key))
                   (lambda (text col row bold) (draw prompt text col row bold))
                   initial-tree initial-locus #:seed seed #:rules rules
                   #:complete complete #:candidates candidates
                   #:search-draw (lambda (query match failed)
                                   ;; only the MATCHED SPAN of the found line
                                   ;; renders in reverse video (bash highlights
                                   ;; just the query, not the whole line); the
                                   ;; span and its case rule are the search's
                                   ;; own (history's match-span).  The failed
                                   ;; frame shows the query, unhighlighted.
                                   (let* ((text (if (and match (not failed)) match query))
                                          (ls (split-newlines text))
                                          (span (and match (not failed)
                                                     (match-span query match)))
                                          (spans (if span (list span) '())))
                                     (draw (if failed
                                               "(failed reverse-i-search)`': "
                                               "(reverse-i-search)`': ")
                                           text
                                           (string-length (list-ref ls (- (length ls) 1)))
                                           (- (length ls) 1)
                                           spans
                                           #t))))
       (leave-frame!)                    ; out from inside the frame, below it
       (values tree locus action)))))
