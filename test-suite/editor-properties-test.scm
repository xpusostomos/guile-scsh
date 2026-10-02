;;; editor-properties-test.scm -- the shell's user-settable property list.
;;;
;;;   make -C test-suite properties
;;;
;;; The alist holds (SYMBOL . VALUE) pairs: an unset symbol reads as #f,
;;; the setter replaces an existing entry, and (scsh-properties) is the whole
;;; alist.  The alist itself is module-private -- (editor properties.scm) for
;;; why -- so visibility is checked through the procedures.

(use-modules (ice-9 optargs) (editor properties))

(define failures '())

(define (check label expect got)
  (if (equal? expect got)
      (display (string-append "ok   " label "\n"))
      (begin (set! failures (cons label failures))
             (display (string-append "FAIL " label "\n  expect "))
             (write expect) (newline)
             (display "  got    ") (write got) (newline))))

;;; ---- unset, set, replace ------------------------------------------------------

(check "an unset symbol reads as #f"
       #f (scsh-property 'no-such-property))

(check "the setter makes it readable"
       #t (begin (scsh-property-set! 'test-property #t)
                 (scsh-property 'test-property)))

(check "the setter replaces an existing entry"
       7 (begin (scsh-property-set! 'test-property 7)
                (scsh-property 'test-property)))

(check "and the alist holds the one replaced pair"
       '((test-property . 7)) (scsh-properties))

(check "other symbols are untouched"
       #f (scsh-property 'test-other))

(check "the setter returns the value it set"
       #f (scsh-property-set! 'test-property #f))

;;; ---- a property the shell reads: the C-r case switch --------------------------
;;; (The search behaviour itself is checked in editor-history-test.scm.)

(check "'completion-ignore-case is unset by default"
       #f (scsh-property 'completion-ignore-case))

;;; ---- the prompt ---------------------------------------------------------------
;;; 'prompt is a string (the prompt in both modes) or a lambda (called fresh
;;; before every prompt, with #:text saying which editor is asking: #f
;;; structured, #t the unstructured text editor).  Unset defaults to
;;; "scsh$ " structured and "scsh> " in text mode.

(check "the prompt defaults to \"scsh$ \" structured"
       "scsh$ " (scsh-prompt))

(check "and to \"scsh> \" in text mode"
       "scsh> " (scsh-prompt #:text #t))

(check "a string prompt is the prompt"
       "cash> " (begin (scsh-property-set! 'prompt "cash> ")
                       (scsh-prompt)))

(check "the string is the prompt in text mode too"
       "cash> " (scsh-prompt #:text #t))

(check "a lambda prompt is called for its string"
       "lambda> " (begin (scsh-property-set! 'prompt (lambda () "lambda> "))
                         (scsh-prompt)))

(check "a lambda taking the keyword is told which editor asks"
       '("struct" "text")
       (begin (scsh-property-set! 'prompt (lambda* (#:key text)
                                            (if text "text" "struct")))
              (list (scsh-prompt) (scsh-prompt #:text #t))))

(check "the lambda is called fresh each time"
       '("a> " "b> ")
       (let ((n 0))
         (scsh-property-set! 'prompt (lambda ()
                                       (set! n (+ n 1))
                                       (list-ref '("a> " "b> ") (- n 1))))
         (list (scsh-prompt) (scsh-prompt))))

(check "an older lambda without the keyword still works"
       "plain> " (begin (scsh-property-set! 'prompt (lambda () "plain> "))
                        (scsh-prompt #:text #t)))

(check "a non-string non-lambda falls back to the default"
       "scsh$ " (begin (scsh-property-set! 'prompt 7)
                       (scsh-prompt)))

;;; ---- verdict ------------------------------------------------------------------

(unless (null? failures)
  (for-each (lambda (f) (display (string-append "FAILED: " f "\n"))) (reverse failures))
  (exit 1))
(display "all property checks pass\n")
