;;; editor/scsh.scm -- the scsh layer: what shell things mean structurally.
;;;
;;; The editor proper (engine/render/repl) knows nothing about shells.  This
;;; module holds the scsh policy: what the first word of a line opens, and what
;;; the shell operators do.  Each operator is a pure restructuring of the tree,
;;; so none of them can produce a malformed line.

(define-module (editor scsh)
  #:use-module (ice-9 receive)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)    ; string-prefix?, string-contains
  #:use-module (editor engine)
  #:use-module (editor repl)     ; rule, the key-table row
  #:use-module (editor properties)  ; bourne-shell, the ! escape's shell
  #:use-module (scsh glob)       ; glob, under eglob
  #:export (seed line-datum shell-rules job-control?
            bourne-tree? bourne-line-datum eglob))

;;; ---- small list helpers ----------------------------------------------------

(define (butlast lst)
  (if (null? lst) '() (reverse (cdr (reverse lst)))))

(define (last lst)
  (if (null? lst) #f (car (reverse lst))))

(define (list-replace lst i v)
  (append (list-head lst i) (list v) (list-tail lst (+ i 1))))

(define (splice lst i v)
  (append (list-head lst i) (list v) (list-tail lst i)))

;;; ---- is this shell controlling jobs? ----------------------------------------
;;; With job control ON (the default), a background job keeps the terminal's
;;; stdin but is released into its own process group, so if it reads the
;;; terminal the kernel stops it (SIGTTIN) -- bash's behaviour.  With job
;;; control OFF there is nothing to stop it, so we fall back to the POSIX rule
;;; for an asynchronous list in that case: /dev/null on stdin.
(define *job-control?* #t)

(define (job-control? . maybe-new)
  (if (null? maybe-new)
      *job-control?*
      (begin (set! *job-control?* (car maybe-new)) *job-control?*)))

;;; ---- the ! escape: a line for the standard shell ----------------------------
;;; A line headed by ! is one verbatim command string for the standard shell
;;; (the 'bourne-shell property, defaulting to /bin/bash or /bin/sh): the
;;; tree is the marker word ! hugging the command -- ("!" "ls -l") renders
;;; "!ls -l" -- the history stores it as the readable datum (! "ls -l"), and
;;; committing turns it into (run (SH -c "...")), the same foreground
;;; machinery any command gets.

(define (bourne-tree? tree)
  (and (pair? tree) (pair? (cdr tree)) (null? (cddr tree))
       (string? (car tree)) (string=? (car tree) "!")))

(define (bourne-line-datum tree)
  (list 'run (list (bourne-shell) '-c (cadr tree))))

;;; ---- what a line starts as -------------------------------------------------
;;; A shell line begins with a command, so the first word opens (run ()) with
;;; the locus inside the command form.

;;; (seed KEY) -> (values tree locus taken?)
;;;   a letter or anything else -- a shell command: (run ()) with the locus in
;;;                                 the command form, and the key typed into it
;;;   "("                        -- a plain Scheme form: an empty form, the "("
;;;                                 being its own opening paren (taken, not typed)
;;;   ")"                        -- nothing at all (swallowed)
;;;   ","                        -- plain Scheme again, and the comma is typed:
;;;                                 the line is a Scheme expression, not a command
;;; so a line can be Scheme rather than a command whenever you start one.
(define (seed key)
  (cond ((char=? key #\() (values (list "") '(() 0 0) #t))
        ((char=? key #\)) (values '() '(() 0 0) #t))
        ;; ! opens the bourne-shell line: the cursor lands in the command
        ;; string, and the shell operators keep their hands off it
        ((char=? key #\!) (values (list "!" "") '(() 1 0) #t))
        ((char=? key #\,) (values '() '(() 0 0) #f))
        (else               (values (sexp->tree '(run ())) '((1) 0 0) #f))))

;;; ---- "," -- naming a value, not running a command ---------------------------
;;; A REPL has to be able to show you a variable, and (run (name)) is not that.
;;; So a comma at the head of a line is the shell's escape to plain Scheme, and
;;; what it marks is the line itself:
;;;
;;;     ,name        the variable name,   not (unquote name)
;;;     ,(+ 1 2)     the expression, evaluated
;;;
;;; Nothing at the top of a line is inside a quasiquote, so an unquote there
;;; could not have meant unquote anyway -- Scheme rejects it outright.  Inside a
;;; form the comma is still unquote, as it must be: `(1 ,x) is a quasiquote.
(define (line-datum sexp)
  (if (and (pair? sexp) (null? (cdr sexp))
           (pair? (car sexp)) (eq? 'unquote (car (car sexp))))
      (cadr (car sexp))
      sexp))

;;; ---- the shell operators ---------------------------------------------------

;;; The operators are assistance only at the END of a form: the cursor must be
;;; where that form's closing ")" is the very next thing -- nothing follows it
;;; inside the form.  Everywhere else the character is simply the atom, because
;;; you are building the form by hand.  (This is the whole rule: word boundaries,
;;; starts of forms, middles of words all fall out of it.)
(define (at-form-end? tree locus)
  (let ((cont (container-at tree (locus-path locus)))
        (i (locus-index locus))
        (off (locus-offset locus)))
    (cond ((= i (length cont)) #t)                  ; the empty position at the end
          ((string? (list-ref cont i))              ; a word: at its end, and last
           (and (= off (string-length (list-ref cont i)))
                (= i (- (length cont) 1))))
          (else #f))))                              ; a form follows the cursor

(define (nonempty? els)
  (any (lambda (e) (or (not (string? e)) (not (string=? e "")))) els))

;;; a form being restructured should not carry the empty word the user was
;;; about to type into ("ls " -> "ls"), so the rendering stays tidy
(define (drop-trailing-empties els)
  (reverse (drop-while (lambda (e) (and (string? e) (string=? e "")))
                        (reverse els))))

;;; ---- redirection plumbing ---------------------------------------------------
;;; A redirection form is (> FILE), (< FILE), ... -- the heads scsh's
;;; transcribe-redirection knows as file redirections.  A redirection belongs
;;; to the form it FOLLOWS: in (run (ls) (> f)) it takes ls's stdout, in
;;; (run (| (ls) (wc)) (> f)) it takes the pipeline's -- which scsh applies to
;;; the pipeline's last stage.  The operators below keep that attachment as
;;; the line is restructured; the epf form is how a stage carries its own:
;;;
;;;     (run (| (epf (ls) (> f)) (wc)))    ls's output goes to f, wc reads it
(define redir-heads '(">" "<" ">>" "<<"))

(define (redir-form? e)
  (and (pair? e) (string? (car e))
       (any (lambda (h) (string=? (car e) h)) redir-heads)))

(define (pipeline? e)
  (and (pair? e) (string? (car e)) (string=? (car e) "|")))

(define (epf-form? e)
  (and (pair? e) (string? (car e)) (string=? (car e) "epf")))

;;; the index just past the redirections stacked after element I of CONT --
;;; where a new redirection opens, after the ones already there (scsh lets
;;; redirections accumulate; the later one wins for that fd)
(define (after-redirs cont i)
  (let lp ((k (+ i 1)))
    (if (and (< k (length cont)) (redir-form? (list-ref cont k)))
        (lp (+ k 1))
        k)))

;;; the redirections stacked after element I of CONT -- the ones attached to it
(define (redirs-after cont i)
  (let lp ((k (+ i 1)) (out '()))
    (if (and (< k (length cont)) (redir-form? (list-ref cont k)))
        (lp (+ k 1) (cons (list-ref cont k) out))
        (reverse out))))

;;; the command a redirection at index I of CONT is attached to: what its run
;;; of stacked redirections follows.  #f when there is no command behind them.
(define (redir-command cont i)
  (let lp ((k (- i 1)))
    (cond ((< k 1) #f)
          ((redir-form? (list-ref cont k)) (lp (- k 1)))
          (else k))))

;;; ...and the same, at every depth: a dangling empty word can sit inside the
;;; command form ("wc " typed after "wc") rather than beside it.  A
;;; redirection form is left whole: its trailing empty FILENAME is a slot the
;;; user has not filled yet, not a dangling word.
(define (tidy els)
  (map (lambda (e) (cond ((redir-form? e) e)
                         ((pair? e) (tidy e))
                         (else e)))
       (drop-trailing-empties els)))

;;; what a form should not carry when it is restructured: the trailing empty
;;; WORD tidy already handles, and the empty FORM a fresh stage leaves behind
;;; (the () you were about to type into, in a pipe or an and/or list)
(define (drop-empty-tails els)
  (reverse (drop-while null? (reverse (tidy els)))))

;;; a pipeline absorbs the redirections that trail it: they aim at its end,
;;; which is its last stage, so that stage wraps in an epf carrying them --
;;; or they join an epf that is already there.  The caller drops the trailed
;;; redirections from the pipeline's parent.
(define (absorb-redirs pipe redirs)
  (let* ((last-i   (- (length pipe) 1))
         (last-st  (list-ref pipe last-i))
         (new-last (if (epf-form? last-st)
                       (append (tidy last-st) redirs)
                       (append (list "epf" (tidy last-st)) redirs))))
    (list-replace pipe last-i new-last)))

;;; the command at index I of CONT, with the redirections stacked after it,
;;; becomes (epf cmd redir...) -- the first stage of a fresh pipeline that
;;; replaces them in CONT.  Returns (values CONT* the fresh stage's index).
(define (epf-stage cont i)
  (let* ((redirs   (redirs-after cont i))
         (epf      (append (list "epf" (tidy (list-ref cont i))) redirs))
         (newpipe  (list "|" epf '()))
         (cont*    (append (list-head cont i)
                           (list newpipe)
                           (list-tail cont (+ i 1 (length redirs))))))
    (values cont* (- (length newpipe) 1))))

;;; |  : a stage joins the pipeline.  A redirection already in the line keeps
;;; aiming at the command it was aimed at:
;;;
;;;     (run (ls) (> f))           |  ->  (run (| (epf (ls) (> f)) ()))
;;;         the command and its redirect wrap in an epf as the first stage
;;;     (run (| (ls) (wc)) (> f))  |  ->  (run (| (ls) (epf (wc) (> f)) ()))
;;;         the redirect aims at the pipeline's end, so it moves down into
;;;         the last stage, and the fresh stage opens after it
;;;
;;; With no redirect in the way the stages chain in the one |, as before:
;;;
;;;      the cursor is at a pipeline's own end   -> the pipeline grows a stage
;;;      the form is a STAGE of a pipeline       -> a fresh stage splices in
;;;                                                 beside it, so piping a
;;;                                                 stage extends the pipe
;;;                                                 rather than nesting it:
;;;         (run (| (ls) (wc)))  |  ->  (run (| (ls) (wc) ()))
;;;      otherwise                               -> the form becomes the first
;;;                                                 stage of a fresh pipeline
;;;         (run (ls -l))        |  ->  (run (| (ls -l) ()))
;;; the cursor's own position is one the pipe cases address when it is at a
;;; form end at the pipeline itself, at a stage, at the command, or on a
;;; redirect -- anywhere deeper inside a command (a glob's pattern, between
;;; a marker and its form, mid-word) is not, and neither is the line's own
;;; root.  The pipe smarts walk up the tree to the stage the cursor is
;;; inside -- else the command itself -- and operate there.
(define (pipe-handled? tree locus)
  (let ((p (locus-path locus)))
    (and (pair? p)
         (at-form-end? tree locus)
         (let* ((parent (container-at tree (butlast p)))
                (head (and (pair? parent) (string? (car parent)) (car parent)))
                (me (list-ref parent (last p)))
                (me-head (and (pair? me) (string? (car me)) (car me))))
           (or (member head '("|" "||"))
               (member head '("run" "&" "&&"))
               (member me-head '("|" "||"))
               (redir-form? me))))))

(define (up-target tree locus)
  ;; the stage the cursor is inside (the shallowest form whose parent is the
  ;; pipeline), else the command itself (whose parent is the run) -- at its
  ;; end; #f when the line offers neither (a begin without a run in it).
  ;; The | and > smarts share it: pressed deep inside a command, both
  ;; operate at the stage/command the cursor is in
  (let ((p (locus-path locus)))
    (if (null? p)
        (let ((head (and (pair? tree) (string? (car tree)) (car tree))))
          (cond ((member head '("run" "&"))
                 (make-locus '(1) (length (container-at tree '(1))) 0))
                ;; a top-level &&/|| list: the line's end is its LAST stage
                ((member head '("&&" "||"))
                 (let ((n (- (length tree) 1)))
                   (and (> n 0)
                        (make-locus (list n) (length (container-at tree (list n))) 0))))
                (else #f)))
        (let lp ((k (length p)))
          (if (zero? k)
              #f
              (let* ((q (list-head p k))
                     (parent (container-at tree (butlast q)))
                     (head (and (pair? parent) (string? (car parent)) (car parent))))
                (if (member head '("|" "||" "run" "&" "&&"))
                    (make-locus q (length (container-at tree q)) 0)
                    (lp (- k 1)))))))))

;;; ---- the | key: opening stages, and cycling the operator --------------------
;;; | is a PROCESS-FORM operator: a pipe lives inside a run/& wrapper, as
;;; (run (| a b)).  || is a TOP-LEVEL line head, like && -- scsh's or-list
;;; (or (zero? (run pf)) ...).  So pressing | on a pipe's head word, or in one
;;; of its empty stages, advances the operator instead of opening a stage:
;;;
;;;   (run (| (ls) ()))   ->  (|| (ls) ())    ->  (run (ls))           [empty last]
;;;   (run (| (ls) (wc)))  ->  (|| (ls) (wc))  ->  (run (| (ls) (wc))) [non-empty]
;;;
;;; becoming an or drops the run wrapper (|| stands on its own); coming back
;;; restores it, since | has to sit inside a process form.

(define (or-form? e)
  (and (pair? e) (string? (car e)) (string=? (car e) "||")))

(define (pipe-or? e) (or (pipeline? e) (or-form? e)))

;;; the pipe/or form the cursor is positioned to advance: on its head word, or
;;; inside one of its empty stages.  returns the form's PATH, else #f
(define (advanceable-pipe tree locus)
  (let* ((p    (locus-path locus))
         (i    (locus-index locus))
         (cont (container-at tree p)))
    (cond
      ((and (pipe-or? cont) (= i 0)) p)                        ; on the head word
      ((and (pipe-or? cont) (< i (length cont))                ; on an empty stage
            (null? (list-ref cont i)))
       p)
      ((and (pair? p) (null? cont)                             ; inside one
            (pipe-or? (container-at tree (butlast p))))
       (butlast p))
      (else #f))))

;;; the locus, which sat at pipe form OP, moved to where OP now lives (NEWPATH)
(define (pipe-relocus locus op newpath)
  (if (equal? (locus-path locus) op)
      (make-locus newpath (locus-index locus) (locus-offset locus))
      (make-locus (append newpath (list-tail (locus-path locus) (length op)))
                  (locus-index locus) (locus-offset locus))))

(define (advance-pipe tree locus op)
  (let* ((form (container-at tree op))
         (head (car form))
         (n    (length form)))
    (if (string=? head "|")
        ;; | -> ||: the or-form is top level, so it leaves the run wrapper
        (let* ((form*  (list-replace form 0 "||"))
               (pp     (butlast op))
               (parent (container-at tree pp))
               (phead  (and (pair? parent) (string? (car parent)) (car parent)))
               (lift?  (and phead (string=? phead "run"))))
          (if lift?
              (if (null? pp)
                  ;; the run wrapper IS the line: the or-form replaces it
                  (values form* (pipe-relocus locus op pp) #t)
                  (let* ((gp  (butlast pp)) (gi (last pp))
                         (gpc (container-at tree gp)))
                    (values (with-container tree gp (list-replace gpc gi form*))
                            (pipe-relocus locus op pp)
                            #t)))
              (values (with-container tree op form*)
                      (pipe-relocus locus op op)
                      #t)))
        ;; || -> back.  An empty last stage collapses to the single command,
        ;; wrapped in run again; otherwise the | pipe comes back inside run
        (if (null? (list-ref form (- n 1)))
            (let* ((run* (list "run" (list-ref form 1)))
                   (tree* (with-container tree op run*)))
              (values tree*
                      (make-locus (append op (list 1))
                                  (length (container-at tree* (append op (list 1))))
                                  0)
                      #t))
            (let ((run* (list "run" (list-replace form 0 "|"))))
              (values (with-container tree op run*)
                      (make-locus (append op (list 1)) 0 0)
                      #t))))))

(define (pipe tree locus)
  (let ((op (advanceable-pipe tree locus)))
    (cond
      (op (advance-pipe tree locus op))
      ;; at the very end of a top-level || line there is no parent form for
      ;; pipe-at to splice into: the line itself grows a stage
      ((and (or-form? tree) (null? (locus-path locus))
            (= (locus-index locus) (length tree)))
       (let* ((ts (drop-empty-tails tree)) (n (length ts)))
         (values (append ts (list '())) (make-locus (list n) 0 0) #t)))
      ((pipe-handled? tree locus) (pipe-at tree locus))
      (else
       (let ((target (up-target tree locus)))
         (if target
             (pipe-at tree target)
             (values tree locus #f)))))))

(define (pipe-at tree locus)
  (let ((p (locus-path locus)))
    (if (or (null? p)
            (not (at-form-end? tree locus))
            (not (nonempty? (container-at tree p))))
        (values tree locus #f)
        (let* ((pp    (butlast p))
               (ci    (last p))
               (parent (container-at tree pp))
               (me     (list-ref parent ci))
               (me-head (and (pair? me) (string? (car me)) (car me)))
               (parent-head (and (pair? parent) (string? (car parent)) (car parent))))
          (cond
            ;; THE CURSOR'S FORM IS A REDIRECTION.  It keeps aiming at the
            ;; command it follows while the line grows around it.
            ((redir-form? me)
             (let ((cmd-idx (redir-command parent ci)))
               (cond
                 ;; already inside an epf: it is where it belongs, so the
                 ;; epf's stage is what pipes on -- a fresh stage opens beside
                 ((and parent-head (string=? parent-head "epf"))
                  (let* ((gp  (butlast pp))
                         (gi  (last pp))
                         (gpc (container-at tree gp)))
                    (values (with-container tree gp (splice gpc (+ gi 1) '()))
                            (make-locus (append gp (list (+ gi 1))) 0 0)
                            #t)))
                 ;; no command behind the redirect (hand-built tree): decline
                 ((not cmd-idx)
                  (values tree locus #f))
                 ;; attached to a PIPELINE: it aims at the pipeline's end, so
                 ;; it moves down into the last stage, and the fresh stage
                 ;; opens after it
                 ((pipeline? (list-ref parent cmd-idx))
                  (let* ((redirs   (redirs-after parent cmd-idx))
                         (absorbed (absorb-redirs (list-ref parent cmd-idx) redirs))
                         (pipe*    (append absorbed (list '())))
                         (parent*  (append (list-head parent cmd-idx)
                                           (list pipe*)
                                           (list-tail parent
                                                      (+ cmd-idx 1 (length redirs))))))
                    (values (with-container tree pp parent*)
                            (make-locus (append pp (list cmd-idx (- (length pipe*) 1))) 0 0)
                            #t)))
                 ;; attached to a plain command: the two wrap in an epf as the
                 ;; first stage of a fresh pipeline
                 (else
                  (receive (parent* stage-i) (epf-stage parent cmd-idx)
                    (values (with-container tree pp parent*)
                            (make-locus (append pp (list cmd-idx stage-i)) 0 0)
                            #t))))))
            ;; the pipeline itself is the form at the cursor: a stage joins it
            ;; -- unless redirections trail the pipeline, in which case they
            ;; aim at its end and move into the last stage first
            ((and me-head (member me-head '("|" "||")))
             (if (pair? (redirs-after parent ci))
                 (let* ((redirs   (redirs-after parent ci))
                        (absorbed (absorb-redirs me redirs))
                        (pipe*    (append absorbed (list '())))
                        (parent*  (append (list-head parent ci)
                                          (list pipe*)
                                          (list-tail parent
                                                     (+ ci 1 (length redirs))))))
                   (values (with-container tree pp parent*)
                           (make-locus (append pp (list ci (- (length pipe*) 1))) 0 0)
                           #t))
                 (let* ((me* (append (tidy me) (list '())))
                        (n   (- (length me*) 1)))
                   (values (with-container tree pp (list-replace parent ci me*))
                           (make-locus (append p (list n)) 0 0)
                           #t))))
            ;; a stage of a pipeline: the fresh stage stands beside it, so the
            ;; pipe grows in place -- never a pipe inside a pipe by accident.
            ;; On the LAST stage, redirections trailing the pipeline aim here:
            ;; they move into this stage before the fresh one opens beside it.
            ((and parent-head (member parent-head '("|" "||")))
             (let* ((gp  (butlast pp))
                    (gi  (last pp))
                    (gpc (container-at tree gp)))
               (if (and (pair? pp) (= ci (- (length parent) 1))
                        (pair? (redirs-after gpc gi)))
                   (let* ((redirs   (redirs-after gpc gi))
                          (absorbed (absorb-redirs parent redirs))
                          (pipe*    (append absorbed (list '())))
                          (gpc*     (append (list-head gpc gi)
                                            (list pipe*)
                                            (list-tail gpc
                                                       (+ gi 1 (length redirs))))))
                     (values (with-container tree gp gpc*)
                             (make-locus (append pp (list (length absorbed))) 0 0)
                             #t))
                   (values (with-container tree pp
                                           (splice (list-replace parent ci (tidy me))
                                                   (+ ci 1) '()))
                           (make-locus (append pp (list (+ ci 1))) 0 0)
                           #t))))
            ;; the form has redirections stacked after it: they are attached
            ;; to it, so they come along into the epf -- (run (ls) (> f)) with
            ;; the cursor on ls pipes the pair exactly as above
            ((pair? (redirs-after parent ci))
             (receive (parent* stage-i) (epf-stage parent ci)
               (values (with-container tree pp parent*)
                       (make-locus (append pp (list ci stage-i)) 0 0)
                       #t)))
            ;; a fresh pipeline, the form its first stage
            (else
             (values (with-container tree pp
                                     (list-replace parent ci (list "|" (tidy me) '())))
                     (make-locus (append p (list 2)) 0 0)
                     #t)))))))

;;; >  : a redirection opens for the command the cursor is on, and stays aimed
;;; at it wherever the tree has to bend to say so:
;;;
;;;      a plain command                     -> it opens beside the form
;;;         (run (ls))           ->  (run (ls) (> ))
;;;      the LAST stage of a pipeline (or the pipeline itself)
;;;                                          -> it opens after the pipeline,
;;;             where scsh applies it to that stage anyway
;;;         (run (| (ls) (wc)))  ->  (run (| (ls) (wc)) (> ))
;;;      a NON-last stage                    -> only an epf wrap keeps the
;;;             redirect aimed at THIS stage and not at the pipe's end
;;;         (run (| (ls) (wc)))  ->  (run (| (epf (ls) (> )) (wc)))
;;;
;;; A second > stacks after the ones already there: scsh lets redirections
;;; accumulate, the later one winning for that fd (so a future (> 2 f) can
;;; sit beside a (> g)).
(define (redirect-handled? tree locus)
  ;; the cursor's own position is one the redirect cases address: at a form
  ;; end at the pipeline, at a stage, at the command, on a redirect, or at a
  ;; begin body slot.  Deeper inside a command is not -- the smarts walk up
  (let ((p (locus-path locus)))
    (and (pair? p)
         (at-form-end? tree locus)
         (let* ((parent (container-at tree (butlast p)))
                (head (and (pair? parent) (string? (car parent)) (car parent)))
                (me (list-ref parent (last p)))
                (me-head (and (pair? me) (string? (car me)) (car me))))
           (or (member head '("|" "||"))
               (member head '("run" "&" "&&" "begin"))
               (member me-head '("|" "||"))
               (redir-form? me))))))

(define (redirect tree locus)
  (if (redirect-handled? tree locus)
      (redirect-at tree locus)
      (let ((target (up-target tree locus)))
        (if target
            (redirect-at tree target)
            (values tree locus #f)))))

(define (redirect-at tree locus)
  (let ((p (locus-path locus)))
    (if (or (null? p)
            (not (at-form-end? tree locus))
            (not (nonempty? (container-at tree p))))
        (values tree locus #f)
        (let* ((pp (butlast p))
               (ci (last p))
               (parent (container-at tree pp))
               (parent-head (and (pair? parent) (string? (car parent)) (car parent))))
          (cond
            ;; a stage of a pipeline (or of a top-level &&/|| list): the
            ;; redirect stays aimed at that stage
            ((and parent-head (member parent-head '("|" "||" "&&")))
             (if (and (pair? pp) (= ci (- (length parent) 1)))
                 ;; the LAST stage: the pipeline's own end speaks for it --
                 ;; the redirect opens after the pipeline (stacking after any
                 ;; already there)
                 (let* ((gp  (butlast pp))
                        (gi  (last pp))
                        (gpc (container-at tree gp))
                        (k   (after-redirs gpc gi)))
                   (values (with-container tree gp (splice gpc k (list ">" "")))
                           (make-locus (append gp (list k)) 1 0)
                           #t))
                 ;; a MID stage: an epf wraps the stage and carries the
                 ;; redirect; an epf already there takes it beside its own
                 (let ((me (list-ref parent ci)))
                   (if (epf-form? me)
                       (let* ((me* (append (tidy me) (list (list ">" ""))))
                              (r   (- (length me*) 1)))
                         (values (with-container tree pp (list-replace parent ci me*))
                                 (make-locus (append pp (list ci r)) 1 0)
                                 #t))
                       (values (with-container tree pp
                                               (list-replace
                                                parent ci
                                                (list "epf" (tidy me) (list ">" ""))))
                               (make-locus (append pp (list ci 2)) 1 0)
                               #t)))))
            (else
             ;; everything else: the redirect opens beside the form, after any
             ;; already stacked there
             (let ((k (after-redirs parent ci)))
               (values (with-container tree pp
                                       (list-replace (splice parent k (list ">" ""))
                                                     ci
                                                     (tidy (list-ref parent ci))))
                       (make-locus (append pp (list k)) 1 0)
                       #t))))))))

;;; &  : run the whole line in the background -- the top form becomes (& ...),
;;;      and pressing it again puts the "run" back.
;;;
;;;      A background job must not be able to eat your keystrokes.  With job
;;;      control on (the default) the job is released into its own process group
;;;      while the shell keeps the terminal, so the kernel stops it (SIGTTIN) if
;;;      it reads -- nothing to add.  With job control off nothing would stop
;;;      it, so it gets /dev/null on stdin, visibly, as POSIX prescribes for an
;;;      asynchronous list in that case; delete the form to keep stdin.
(define (input-redir? e)
  (and (pair? e) (string? (car e)) (string=? (car e) "<")))

(define (devnull) (list "<" "/dev/null"))

(define (has-input-redir? els)
  (any input-redir? els))

(define (background tree locus)
  (let ((head (and (pair? tree) (string? (car tree)) (car tree))))
    (cond ((not (at-form-end? tree locus)) (values tree locus #f))
          ((equal? head "run")
           (let* ((body (tidy (cdr tree)))
                  (els  (if (or (job-control?) (has-input-redir? body))
                            body
                            (append body (list (devnull))))))
             (values (cons "&" els) locus #t)))
          ;; the & family cycles run -> & -> && -> run (&& is scsh's and-list:
          ;; (and (zero? (run pf)) ...) -- a top-level line head like & and run)
          ((equal? head "&")
           ;; && is a LIST of commands, so it opens an empty slot for the
           ;; next one, with the cursor in it -- as | opens a fresh stage
           (let* ((body (drop-empty-tails (cdr tree)))
                  (new  (cons "&&" (append body (list '())))))
             (values new (make-locus (list (- (length new) 1)) 0 0) #t)))
          ((equal? head "&&")
           ;; back to run, which holds ONE command: drop the empty trailing
           ;; slot, and take the first command -- exactly the || -> run rule,
           ;; since there is no inner & form to carry the rest into
           (let* ((body (remove (lambda (e) (equal? e (devnull)))
                                (drop-empty-tails (cdr tree))))
                  (run* (if (null? body) (list "run") (list "run" (car body))))
                  (loc* (if (null? body) locus (make-locus '(1) (length (car body)) 0))))
             (values run* loc* #t)))
          (else (values tree locus #f)))))

;;; The shell's structural sugar is for shell lines only: in a plain Scheme form
;;; ("|" and friends are ordinary characters, and must be typed as such).
(define (shell-line? tree)
  (and (pair? tree) (string? (car tree))
       (member (car tree) (list "run" "&" "&&" "||"))))

;;; ---- the shell's rows of the key table --------------------------------------
;;; Each operator is a RULE (see editor/repl.scm): it matches one character and
;;; handles it only on a shell line at a form's end, DECLINING otherwise -- and
;;; a declined row lets the character fall through to the printer, which types
;;; it.  The guards live in the operators themselves (pipe/redirect/background
;;; answer HANDLED?).
(define (shell-op-rule char op)
  (make-rule (lambda (k) (eq? k char))
        (lambda (tree locus key)
          (if (not (shell-line? tree))
              (values tree locus 'continue #f)
              (call-with-values (lambda () (op tree locus))
                (lambda (t l handled?)
                  (values t l 'continue handled?)))))))

;;; eglob -- glob with the shell's no-match policy.  The default is strict:
;;; a pattern that matches nothing raises "No match".  nonomatch returns
;;; unmatched patterns literally; nullglob returns nothing for them, plain
;;; glob's behavior.  The modifiers are per-call symbol arguments and also
;;; scsh-properties ('nonomatch / 'nullglob #t) -- a per-call symbol wins
;;; over the property, and the last symbol on the call wins over an earlier
;;; one.  Several patterns expand in order, each on its own policy.
;;;
;;; Like glob, eglob is a macro with an implicit quasiquote, so patterns can
;;; be unquoted, shell-style: (eglob *.c) -- glob* stringifies the symbols.
;;; The modifiers are spelled QUOTED -- (eglob 'nonomatch "*.c") -- inside
;;; the quasiquote the quote arrives as the form (quote nonomatch), which is
;;; what the check below recognizes; an unquoted nonomatch is a file name,
;;; and quoting is what tells the two apart.

(define (eglob-modifier? arg)
  (and (pair? arg) (pair? (cdr arg)) (null? (cddr arg))
       (eq? (car arg) 'quote)
       (memq (cadr arg) '(nonomatch nullglob))))

(define (eglob-modifier arg)
  (cadr arg))

(define (eglob-mode args)
  (let lp ((args args) (mode #f))
    (cond ((null? args)
           (or mode
               (cond ((scsh-property 'nonomatch) 'nonomatch)
                     ((scsh-property 'nullglob) 'nullglob)
                     (else 'nomatch))))
          ((eglob-modifier? (car args)) (lp (cdr args) (eglob-modifier (car args))))
          (else (lp (cdr args) mode)))))

(define (eglob* args)
  (let ((mode (eglob-mode args)))
    (let loop ((args args) (out '()))
      (cond ((null? args) out)
            ;; a modifier: consumed by the mode, never a pattern
            ((eglob-modifier? (car args)) (loop (cdr args) out))
            (else
             ;; glob* -- the procedure: stringify makes unquoted symbol
             ;; patterns work
             (let ((matches (glob* (car args))))
               (cond ((pair? matches) (loop (cdr args) (append out matches)))
                     ((eq? mode 'nonomatch)
                      (loop (cdr args) (append out (list (car args)))))
                     ((eq? mode 'nullglob) (loop (cdr args) out))
                     (else (error "No match" (car args))))))))))


(define-syntax eglob
  (syntax-rules ()
    ((_ rest ...) (eglob* `(rest ...)))))

;;; *  : a glob in a command position.  The word at the cursor becomes the
;;;      pattern of ,@(glob "..."), the star landing inside it at the cursor,
;;;      so what you type after extends the pattern:
;;;
;;;      (run (ls))  +  * . c   ->  (run (ls ,@(glob "*.c")))
;;;
;;;      The word is taken whole (ls f*.c -> (run (ls ,@(glob "f*.c")))), a
;;;      second star inside the pattern is just a character (globs have
;;;      many), and so is a * inside a quoted word.
;;;
;;;      The splice is legal wherever the process notation's implicit
;;;      backquote applies (doc/process-notation.scribble): a command's
;;;      argument list, however deeply the command is nested -- in a run, a
;;;      &, an &&, an ||, a pipe, or an epf.  So it globs inside a command in
;;;      (|| (epf (ls) (> foo)) ...) just as at the prompt.  Everywhere else
;;;      the * self-inserts: outside a shell line, at a run/pipe/&&/|| form's
;;;      own level (not a command), inside a redirection (one file-name
;;;      slot, which a splice cannot fill), in a begin holding no run.

(define structural-heads '("|" "||" "&&" ">" ">>" "<" "<<" "epf" "begin" "run" "&"))

(define (command-form? tree path)
  ;; the form the cursor is in takes a plain word for its head, and is not
  ;; the glob form itself (the pattern is a string: a * there is a character)
  (let ((head (and (pair? (container-at tree path))
                   (car (container-at tree path)))))
    (and (string? head) (not (string=? head ""))
         (not (member head structural-heads))
         (not (string-prefix? "," head))
         (not (string=? head "eglob")))))

(define (glob-context? tree path)
  ;; the splice is legal where the cursor's form sits inside a run/& subtree
  ;; (the epf's implicit backquote), below a shell line
  (let lp ((k 0) (seen-process? #f))   ; k=0 is the root: the run itself
    (if (> k (length path))
        seen-process?
        (let* ((form (container-at tree (list-head path k)))
               (head (and (pair? form) (car form))))
          (cond ((not (string? head)) #f)
                ((member head '("run" "&" "&&" "||")) (lp (+ k 1) #t))
                ((member head '("begin" "|" "epf" "|+")) (lp (+ k 1) seen-process?))
                ((command-form? tree (list-head path k)) (lp (+ k 1) seen-process?))
                (else #f))))))

(define (glob tree locus key)
  (let ((p (locus-path locus)))
    (if (or (null? p)
            (not (glob-context? tree p))
            (not (command-form? tree p)))
        (values tree locus 'continue #f)
        (let* ((form (container-at tree p))
               (i (locus-index locus))
               (off (locus-offset locus)))
          (if (and (< i (length form))
                   (sym? (list-ref form i))
                   (not (string-contains (list-ref form i) "\"")))
              ;; the word at the cursor is the whole pattern, star inside it;
              ;; the pattern word spells itself with its quotes, so its datum
              ;; is the string glob takes
              (let* ((el (list-ref form i))
                     ;; the pattern is an UNQUOTED word -- eglob is a macro
                     ;; with glob's implicit quasiquote, and glob* stringifies
                     (pattern (string-append (substring el 0 off)
                                             "*"
                                             (substring el off)))
                     (g (list ",@" (list "eglob" pattern))))
                (values (with-container tree p (list-replace form i g))
                        (make-locus (append p (list 1 1)) 1 (+ off 1))
                        'continue #t))
              ;; between elements: a fresh glob, the cursor after its star
              (let ((g (list ",@" (list "eglob" "*"))))
                (values (with-container tree p (splice form i g))
                        (make-locus (append p (list 1 1)) 1 1)
                        'continue #t)))))))

(define shell-rules
  (list
   ;; on a ! line the operator keys are just characters: the command is one
   ;; verbatim string, so they insert like any other key -- the "insert the
   ;; char" table the ! trigger switches to, one row instead of a table swap
   (make-rule (lambda (k) (and (char? k) (memv k '(#\| #\> #\& #\; #\( #\) #\! #\space))))
              (lambda (tree locus key)
                (if (bourne-tree? tree)
                    ;; insert-char* -- the space stays INSIDE the command
                    ;; string; the word never splits
                    (receive (t2 l2) (insert-char* tree locus key)
                      (values t2 l2 'continue #t))
                    (values tree locus 'continue #f))))
   (make-rule (lambda (k) (and (char? k) (char=? k #\*))) glob)
   (shell-op-rule #\| pipe)
   (shell-op-rule #\> redirect)
   (shell-op-rule #\& background)))