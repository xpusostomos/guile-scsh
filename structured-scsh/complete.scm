;;; structured-scsh/complete.scm -- Tab: completing a word, the shell's way.
;;;
;;; The word of an scsh line usually IS a path, so what Tab completes is a file
;;; name -- and how that behaves is not a matter of taste: it is bash's
;;; behaviour, because that is what a user's fingers know.  Every rule below was
;;; MEASURED against bash 5.3 driving a real pty, not reasoned about:
;;;
;;;   ls f<TAB>       -> ls file        extended to the longest shared prefix,
;;;                                     bell (the completion is ambiguous)
;;;   ls alpha<TAB>   -> bell only      "alpha" is already as far as it goes
;;;   <TAB>           -> lists         a second Tab that CANNOT extend lists the
;;;                                     matches under the line and prompts again
;;;   ls beta1<TAB>   -> ls beta1 _     one match: completed, and a SEPARATOR
;;;                                     follows, so you can type the next word
;;;   ls sub<TAB>     -> ls sub/        ...but a directory takes a "/" and no
;;;                                     separator (you are going on inside it)
;;;   ls .<TAB><TAB>  -> ./  ../        a dot word sees the dot files, and bash
;;;                                     offers "." and ".." for it
;;;   ls ~/Doc<TAB>   -> ~/Documents/   the "~" is kept exactly as typed, and
;;;                                     only the directory READ is expanded
;;;
;;; Two Tabs are needed to see the matches, and that is the rule precisely: the
;;; second Tab LISTS when the previous Tab could not extend the word.  A Tab
;;; that extends the word starts the count again -- measured: "ga" <TAB> extends
;;; to "gammalongname", and the NEXT Tab only rings the bell, with the listing
;;; coming on the third.
;;;
;;; Where a Tab cannot extend and there is nothing to show it rings the bell, as
;;; bash's does, and when there is no match at all it does that every time.
;;;
;;; NOT carried, and each for a reason:
;;;
;;;   * bash BACKSLASH-ESCAPES a name with a space in it ("sub\ more/").  The
;;;     tree holds a word as one symbol with no quoting yet, so a completed name
;;;     containing a space is simply completed up to the space.
;;;   * the "Display all N possibilities? (y or n)" prompt readline shows for
;;;     more than 100 matches (completion-query-items).  A listing is a listing.
;;;   * COMMAND completion from $PATH in command position -- bash's first word
;;;     is a command, ours completes file names everywhere.
;;;
;;; What a listing SHOWS is the last segment of each candidate ("lib/", not
;;; "/usr/lib/"), which is also bash's -- see listing-names.
;;;   * sorting is the sheLL's COLLATION, which is readline's: bash sorts with
;;;     the locale's collation (strcoll), not with strcmp, so "." and "-" and
;;;     case only break ties.  Measured in one directory holding a, A, b, B, c9,
;;;     C952, "Café.txt", calib, cb, cB, "c-h", c_h, .hidden, "x y", z1, bash
;;;     lists them in exactly that order -- digits before letters, and the
;;;     punctuation and the case ignored until two names are otherwise equal.
;;;     (ice-9 i18n)'s compare is the same glibc collation, so that order is
;;;     what SORTED-CANDIDATES below reproduces, and the shell gets the user's
;;;     own locale the way bash does: from the environment.
;;;
;;; The module is the SHELL's policy, not the editor's: the editor loops know
;;; only that a "complete" hook exists (see repl.scm's #:complete), and the two
;;; adapters at the bottom are what the shell hands them -- one for a tree, one
;;; for a text line.

(define-module (structured-scsh complete)
  #:use-module (ice-9 receive)
  #:use-module (ice-9 i18n)       ; the locale's collation, which is readline's
  #:use-module (srfi srfi-1)      ; filter, every, sort
  #:use-module (srfi srfi-13)     ; string-prefix?
  #:use-module (structured-scsh engine)
  #:use-module (scsh directory)   ; directory-files
  #:use-module (scsh fileinfo)    ; file-directory?
  #:use-module (scsh fname)       ; file-name-directory/nondirectory, tilde
  #:export (longest-common-prefix word-candidates complete-word listing-names
            tree-complete text-complete text-word-start))

;;; ---- the longest shared prefix ----------------------------------------------
;;; bash's "as far as possible": the characters every candidate agrees on.  No
;;; candidates, or one that shares nothing, is "".
(define (longest-common-prefix strings)
  (if (null? strings)
      ""
      (let ((first (car strings))
            (shortest (apply min (map string-length strings))))
        (let lp ((i 0))
          (if (and (< i shortest)
                   (every (lambda (s) (char=? (string-ref s i) (string-ref first i)))
                          strings))
              (lp (+ i 1))
              (substring first 0 i))))))

;;; ---- what the word could become ---------------------------------------------
;;; The word split the way the shell reads a path: its directory part (as TYPED,
;;; so a "~" stays a "~") and the partial name inside that directory.  The
;;; DIRECTORY read is the expanded one -- file-name-* and the home lookup are
;;; scsh's own, which is the point of a shell's completion living here.
(define (word-candidates word)
  (let* ((dir-typed (file-name-directory word))          ; "" or ends in "/"
         (base      (file-name-nondirectory word))
         (dir       (if (string=? dir-typed "")
                        "./"                             ; the current directory
                        (resolve-tilde-file-name dir-typed)))
         (dots?     (string-prefix? "." base))
         (names     (if dots?
                        ;; bash offers these two for a dot word; they are never
                        ;; in a directory listing, and being empty once the dot
                        ;; is ignored they collate first, as bash prints them
                        (append (list "." "..") (read-directory dir dots?))
                        (read-directory dir #f))))
    (map (lambda (name)
           (string-append dir-typed name
                          (if (directory-entry? (string-append dir name)) "/" "")))
         (sorted (filter (lambda (name) (string-prefix? base name)) names)))))

;;; The matching names in the order bash lists them: the locale's collation.
;;; The directory listing's own order (scsh's directory-files, dot files first
;;; and then string<?) is NOT it -- that is the C order, which puts every
;;; capital ahead of every small letter, and a user reading it calls that
;;; unsorted.
(define (sorted names)
  (sort names (lambda (a b) (string-locale<? a b))))

;;; A directory we cannot read has no candidates -- bash finds nothing there too,
;;; and a Tab must not be able to raise.  The same for an entry that is gone by
;;; the time we ask what it was (scandir read the name a moment ago).
(define (read-directory dir dots?)
  (catch #t (lambda () (directory-files dir dots?)) (lambda args '())))

(define (directory-entry? path)
  (catch #t (lambda () (file-directory? path)) (lambda args #f)))

;;; ---- one word, completed -----------------------------------------------------
;;; (complete-word WORD) -> (values REPLACEMENT CANDIDATES SEPARATOR?)
;;;
;;;   REPLACEMENT: what the word becomes.  It ends in "/" when the match is a
;;;                directory (bash goes into it), and is the plain name when it
;;;                is a file.
;;;   SEPARATOR?:  bash's word separator after a completed FILE, so that the
;;;                next word can be typed at once.  A directory has none.
;;;   CANDIDATES:  #f when the word was completed (the answer needed no
;;;                choosing), else the words to choose between -- a list that is
;;;                EMPTY when nothing matched at all.
;;;
;;; So "candidates" is the whole of the caller's decision: #f means it is done,
;;; a list means there is still a choice and the caller bells -- and lists them
;;; if the previous Tab could not extend the word either.
(define (complete-word word)
  (let ((cands (word-candidates word)))
    (cond
      ((null? cands) (values word '() #f))              ; nothing matches
      ((null? (cdr cands)) (values (car cands) #f (file? (car cands))))
      (else
       (let ((prefix (longest-common-prefix cands)))
         (if (string=? prefix word)
             (values word cands #f)                     ; already as far as it goes
             (values prefix #f #f)))))))

;;; A candidate is a file rather than a directory when it does not end in the
;;; "/" word-candidates put on a directory.
(define (file? candidate)
  (not (char=? #\/ (string-ref candidate (- (string-length candidate) 1)))))

;;; What the LISTING shows, as against what the completion types: bash prints the
;;; last segment of each candidate, not the path you are part way through --
;;; "ls /usr/l<TAB><TAB>" lists "lib/  lib32/  lib64/  local/" and "ls Do<TAB>"
;;; completes to "Documents/".  A directory keeps its slash; the "./" that a dot
;;; word lists is the last segment "." plus that slash.
(define (listing-names cands)
  (map (lambda (c)
         (if (string-suffix? "/" c)
             (string-append (file-name-nondirectory (substring c 0 (- (string-length c) 1)))
                            "/")
             (file-name-nondirectory c)))
       cands))

;;; ---- the two adapters --------------------------------------------------------
;;; The editor loops hand over their own state and take it back changed (see
;;; repl.scm's #:complete); what the word IS and how it is written back differ
;;; between the tree and a text line, and that difference is all these two hold.

;;; (tree-complete TREE LOCUS) -> (values TREE LOCUS CANDIDATES)
(define (tree-complete tree locus)
  (receive (replacement cands separator?) (complete-word (word-at tree locus))
    (if cands
        (values tree locus (listing-names cands))
        (receive (t l) (replace-word tree locus replacement)
          (if separator?
              ;; the separator is a WORD SEPARATOR, not a space inside the word:
              ;; a space element is exactly what typing one would leave
              (receive (t2 l2) (insert-char t l #\space) (values t2 l2 #f))
              (values t l #f))))))

;;; readline's rl_basic_word_break_characters, which is what bash breaks a word
;;; on -- so "(run (ls Doc" completes "Doc", and a quote or a "|" ends a word
;;; the way it does in bash.
(define %word-breaks% (string->list " \t\n\"\\'`$><=;|&{("))

(define (text-word-start buf pt)
  (let lp ((i pt))
    (if (and (> i 0) (not (memv (string-ref buf (- i 1)) %word-breaks%)))
        (lp (- i 1))
        i)))

;;; (text-complete BUFFER POINT) -> (values BUFFER POINT CANDIDATES)
(define (text-complete buf pt)
  (let* ((start (text-word-start buf pt))
         (word  (substring buf start pt)))
    (receive (replacement cands separator?) (complete-word word)
      (if cands
          (values buf pt (listing-names cands))
          (let ((text (if separator? (string-append replacement " ") replacement)))
            (values (string-append (substring buf 0 start) text (substring buf pt))
                    (+ start (string-length text))
                    #f))))))
