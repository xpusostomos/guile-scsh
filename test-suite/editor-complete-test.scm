;;; editor-complete-test.scm -- Tab's completion: the word, and the listing.
;;;
;;;   guile -q -L . test-suite/editor-complete-test.scm   (from the repo root)
;;;
;;; No terminal and no keys: this is the POLICY (structured-scsh/complete.scm)
;;; and the listing's arithmetic (structured-scsh/term.scm), which are both
;;; plain functions.  The keys themselves -- extend, bell, list, on which Tab --
;;; are driven through the real loops in editor-repl-test.scm and
;;; editor-textline-test.scm.
;;;
;;; Every expectation here is bash 5.3's own answer, measured by driving it in a
;;; pty: the candidates, the order, the "~" that stays as typed, and the column
;;; layout of the matches.

(use-modules (ice-9 receive) (srfi srfi-1))
(use-modules (srfi srfi-13))
(use-modules (structured-scsh engine) (structured-scsh render)
             (structured-scsh complete) (structured-scsh term))

(define failures '())
(define (check label expect got)
  (if (equal? expect got)
      (display (string-append "ok   " label "\n"))
      (begin (set! failures (cons label failures))
             (display (string-append "FAIL " label "\n  expect "))
             (write expect) (newline)
             (display "  got    ") (write got) (newline))))

;;; ---- a directory to complete in ---------------------------------------------
;;; Two directories and three files, so that one file shares a prefix with a
;;; directory -- which is what makes an ambiguous completion ambiguous.

(define dir (string-append "/tmp/scsh-complete-test-" (number->string (getpid))))

(define (touch path)
  (let ((p (open-file path "w"))) (close-port p)))

(mkdir dir #o755)
(mkdir (string-append dir "/documents") #o755)
(mkdir (string-append dir "/deep") #o755)
(mkdir (string-append dir "/solo") #o755)
(touch (string-append dir "/data.txt"))
(touch (string-append dir "/docu.txt"))
(touch (string-append dir "/.hidden"))
(chdir dir)
(setenv "HOME" dir)                     ; for the "~" checks

;;; ---- as far as it can go -----------------------------------------------------

(check "no candidates have no common prefix" "" (longest-common-prefix '()))
(check "one candidate is its own prefix" "abc" (longest-common-prefix '("abc")))
(check "two candidates: what they agree on" "ab" (longest-common-prefix '("abc" "abd")))
(check "a shorter candidate ends it" "a" (longest-common-prefix '("ab" "a")))
(check "nothing shared" "" (longest-common-prefix (list "x" "y")))

;;; ---- the candidates ----------------------------------------------------------
;;; The names carry no directory part of their own: the shell's own file-name
;;; split is what puts what you typed back on the front (see the "~" checks).

(check "a partial name lists what it could be"
       (list "documents/" "docu.txt") (word-candidates "doc"))
(check "an empty word lists the directory"
       (list "data.txt" "deep/" "documents/" "docu.txt" "solo/") (word-candidates ""))
(check "a full name matches itself" (list "data.txt") (word-candidates "data"))
(check "a name with no match" '() (word-candidates "zzz"))
(check "a directory that cannot be read has none" '() (word-candidates "nodir/x"))
(check "a directory with nothing in it has none" '() (word-candidates "deep/x"))

;; bash's own two entries come with a dot word, and the dot files with them
(check "a dot word sees the dot files" (list "./" "../" ".hidden") (word-candidates "."))
(check "and a longer dot prefix narrows them" (list ".hidden") (word-candidates ".h"))

;; the directory is READ through the expansion; what comes back is what was
;; TYPED ("ls ~/Doc<TAB>" gives "~/Documents/", measured on bash)
(check "a ~ is kept as typed"
       (list "~/data.txt" "~/deep/" "~/documents/" "~/docu.txt" "~/solo/")
       (word-candidates "~/"))
(check "and so is what follows it" (list "~/documents/" "~/docu.txt") (word-candidates "~/doc"))

;;; ---- one word, completed -----------------------------------------------------

(receive (replacement cands separator?) (complete-word "doc")
  (check "ambiguous: extended to the common prefix" "docu" replacement)
  (check "with nothing to choose yet" #f cands)
  (check "and no separator" #f separator?))

(receive (replacement cands separator?) (complete-word "data")
  (check "one match completes the word" "data.txt" replacement)
  (check "and a file takes bash's separator" #t separator?))

(receive (replacement cands separator?) (complete-word "deep")
  (check "a directory completes to a slash" "deep/" replacement)
  (check "and takes no separator" #f separator?))

(receive (replacement cands separator?) (complete-word "zzz")
  (check "no match leaves the word" "zzz" replacement)
  (check "and answers an empty candidate list" '() cands))

;;; ---- the two adapters --------------------------------------------------------
;;; What the editor loops call: a tree and a text line are written differently
;;; and nothing else differs.

(receive (t l cands) (tree-complete (sexp->tree '(run (ls doc))) (make-locus '(1) 1 3))
  (check "the tree's word is completed in place" "(run (ls docu))" (render-tree t))
  (check "with the cursor at its end" '((1) 1 4) l)
  (check "and no candidates" #f cands))

(receive (t l cands) (tree-complete (sexp->tree '(run (ls data))) (make-locus '(1) 1 4))
  (check "a completed file opens the next word" "(run (ls data.txt ))" (render-tree t))
  (check "with the cursor in it" '((1) 2 0) l))

(receive (t l cands) (tree-complete (sexp->tree '(run (ls zzz))) (make-locus '(1) 1 3))
  (check "no match: the tree is untouched" "(run (ls zzz))" (render-tree t))
  (check "and the candidates come back empty" '() cands))

;; an empty word matches EVERYTHING, so nothing is completed and the whole
;; directory is what comes back to be listed (bash does the same)
(receive (t l cands) (tree-complete (sexp->tree '(run (ls))) (make-locus '(1) 1 0))
  (check "an empty word is left alone" "(run (ls))" (render-tree t))
  (check "and answers the whole directory as its candidates"
         (list "data.txt" "deep/" "documents/" "docu.txt" "solo/") cands))

;;; the LISTING shows the last segment of each candidate, not the path typed
(check "a listing shows the last segment, with a slash on a directory"
       (list "lib/" "local/" "x.txt" "./" "../")
       (listing-names (list "/usr/lib/" "/usr/local/" "x.txt" "./" "../")))
(check "a listing through a ~ shows the segment too"
       (list "documents/" "docu.txt")
       (listing-names (list "~/documents/" "~/docu.txt")))

(check "the text line's word breaks as readline's does"
       9 (text-word-start "(run (ls doc" (string-length "(run (ls doc")))
(check "a word after a space" 3 (text-word-start "ls -l" 3))

(receive (buf pt cands) (text-complete "ls doc" 6)
  (check "the text line is completed in place" "ls docu" buf)
  (check "with the point after it" 7 pt))

(receive (buf pt cands) (text-complete "ls data" 7)
  (check "and a file's separator is a space" "ls data.txt " buf)
  (check "with the point after that" 12 pt))

;;; ---- the listing ---------------------------------------------------------------
;;; The frames measured on bash: 24 six-character names in an 80-column
;;; terminal print as 8 columns of 3, filled DOWN and then across, and the last
;;; entry in a line is not padded (an invisible space in bash's, which is what
;;; makes a line reach past the width and wrap).

(define (fname i)
  (string-append "file" (if (< i 10) "0" "") (number->string i)))

(define files (map fname (iota 24 1)))

(check "24 short names: 8 columns of 3, down then across"
       (list "file01  file04  file07  file10  file13  file16  file19  file22"
             "file02  file05  file08  file11  file14  file17  file20  file23"
             "file03  file06  file09  file12  file15  file18  file21  file24")
       (candidate-rows files 80))

(check "a narrower terminal takes fewer columns"
       (list "file01  file07  file13  file19"
             "file02  file08  file14  file20")
       (take (candidate-rows files 40) 2))

;; a name too long for the columns gets a line of its own, and no padding: this
;; is the frame that made a listing of /tmp double-space itself
(define long-name (make-string 100 #\L))
(check "a name too long for the columns is a line of its own"
       (list long-name "short.txt")
       (candidate-rows (list long-name "short.txt") 80))

(check "99 matches are listed without asking" #f (completion-query? 99))
(check "100 are asked about" #t (completion-query? 100))

;;; ---- the order bash lists them in --------------------------------------------
;;; Not string<?: bash sorts with the LOCALE's collation, so case and
;;; punctuation only break ties.  The order below is bash 5.3's own answer for
;;; this directory, read off a pty -- digits before letters, "Café.txt" before
;;; "calib", "c-h" and "c_h" after "cB".  (The locale is pinned, so the check
;;; means the same wherever the suite runs; a machine without the locale gets a
;;; note and no check, rather than a failure that is about the machine.)

(define sort-dir (string-append "/tmp/scsh-complete-sort-" (number->string (getpid))))
(mkdir sort-dir #o755)
(for-each (lambda (n) (touch (string-append sort-dir "/" n)))
          (list "b" "B" "a" "A" "cb" "cB" "calib" "C952" "c9" "c_h" "c-h" "z1"
                "Café.txt" ".hidden"))
(chdir sort-dir)

(if (setlocale LC_ALL "en_US.UTF-8")
    (check "the locale's collation, as bash lists it"
           (list "a" "A" "b" "B" "c9" "C952" "Café.txt" "calib" "cb" "cB"
                 "c-h" "c_h" "z1")
           (word-candidates ""))
    (begin (display "note: no en_US.UTF-8 locale here, so the collation order\n")
           (display "      cannot be checked against bash's\n")))

;;; ---- paging a long listing ----------------------------------------------------
;;; Readline's pager, measured on bash: a screenful, then "--More--", SPACE for
;;; the next screenful, RET for one more line, q to stop, anything else a ding.
;;; What is printed is checked as the sequence of lines the pager left, with the
;;; escape sequences (it reuses the "--More--" line) taken back off.

;; A line as the pager left it.  The pager prints the next page OVER the
;; --More-- line, so a carriage return is a line break here as much as a newline
;; is, and every line arrives with a clear-to-end-of-line escape on its front.
(define (pager-line l)
  (if (string-prefix? "\x1b[K" l) (substring l 3) l))

(define (pager-lines rows height keys)
  (let ((o (with-output-to-string
             (lambda ()
               (page-rows rows height
                          (lambda ()
                            (if (pair? keys)
                                (let ((k (car keys))) (set! keys (cdr keys)) k)
                                'eof)))))))
    ;; each line as the pager left it, its escape sequences taken off: a line
    ;; arrives as CR, clear-to-end-of-line, CR, text -- because the pager prints
    ;; the next page over the --More-- line
    (string-join
     (filter (lambda (l) (not (string-null? l)))
             (map pager-line (string-split o (char-set #\newline #\return))))
     "|")))

(check "a listing that fits is not paged"
       "r1|r2" (pager-lines (list "r1" "r2") 5 '()))
(check "a screenful, then --More--, then the next on SPACE"
       "r1|r2|--More--|r3|r4|--More--" (pager-lines (list "r1" "r2" "r3" "r4" "r5") 3 (list #\space #\q)))
(check "RET brings one more line, and --More-- again"
       "r1|r2|--More--|r3|--More--" (pager-lines (list "r1" "r2" "r3" "r4") 3 (list 'enter #\q)))
(check "q stops where it is"
       "r1|r2|--More--" (pager-lines (list "r1" "r2" "r3") 3 (list #\q)))
(check "another key is a ding, and --More-- waits"
       "r1|r2|--More--\a|--More--" (pager-lines (list "r1" "r2" "r3") 3 (list #\j #\q)))

;;; ---- verdict ----------------------------------------------------------------

(newline)
(if (null? failures)
    (begin (display "ALL CHECKS PASSED") (newline) (exit 0))
    (begin (display "FAILURES: ") (write failures) (newline) (exit 1)))
