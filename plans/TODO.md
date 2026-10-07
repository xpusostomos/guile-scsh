1. rung syntax, glob and run.
2. Improve Usage file and write a tutorial.
3. ~~Configure readline to make filename completion possible.~~  Done
   2026-10-08 without readline: the FFI readline gets no input in this
   environment, so Tab completes through the shell's own hook in both editors
   (structured-scsh/complete.scm).
4. Job control.