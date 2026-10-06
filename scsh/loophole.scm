; Copyright (c) 1993, 1994 Richard Kelsey and Jonathan Rees.  See file COPYING.

;; original file: alt/loophole.scm.
(define-module (scsh loophole)
  :export (loophole))

(define-syntax loophole
  (syntax-rules ()
    ;; The original wrote (begin (lambda () type) form), referencing the type
    ;; name so that an unknown one would warn.  There are no such type names
    ;; here -- `:value' in (scsh utilities) is the only use, and nothing defines
    ;; it -- so the check is dropped and the form passes through.
    ((loophole type form)
     form)))
    
