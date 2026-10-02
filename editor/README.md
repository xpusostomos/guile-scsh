# editor/ — the structure editor

The document is a **tree**, never text.

    tree    ::= (element ...)      a NODE is a list of elements
    element ::= string             a SYMBOL leaf (its characters)
              | (element ...)      a NODE

Text is only ever *produced* (by the renderer); it is never parsed back in and
never edited as characters.  Balanced parentheses are not an invariant that is
checked — they are not representable: a node simply is a node.

The cursor is a **locus** `(container-path index offset)`:

- `container-path` — indices selecting a node; `()` is the root
- `index` — `0..len` of that node; `len` is the empty position at the end
- `offset` — character offset within a symbol leaf (0 otherwise)

There are exactly two kinds of edit:

- **atom edit** — type or backspace characters inside the current symbol
- **struct edit** — every other key operates on nodes: `(` opens a form and steps
  in, `)` leaves it, C-r is bash's backward search: each letter narrows the
  match from the history, C-r steps one match further back, backspace
  un-narrows, escape accepts and keeps editing, RET accepts and commits, C-g
  aborts to the line as C-r found it, and any other key accepts the match and
  then runs as usual.  The frame becomes `(reverse-i-search)`': match`
  (`(failed ...)` when the query matches nothing).  UP/DOWN recall the line
  history (`~/.scsh_history`: each
  entry is one readable datum — a `(run …)` line or a `,value` — appended after
  every execution, loaded on startup; the draft you were typing comes back when
  you DOWN past the newest), `;` wraps the whole line in `(begin ...)` -- a second
  toplevel inside which everything works as at the prompt (typing `ls` opens a
  `run`, typing `(` opens a Scheme form; the shell's seed is consulted at any
  of the begin body's toplevel slots).  **ESC** switches the shell to the
  *unstructured* line editor (`editor/textline.scm`) — a plain text line with
  readline-style keys (characters insert at the point, backspace/delete,
  left/right/home/end, UP/DOWN recall the same history, **C-r** is the same
  backward search the structure editor runs — the frame is
  `(reverse-i-search)`query: match`` with only the matched span in reverse
  video, letters narrow, C-r steps one match further back, backspace
  un-narrows, enter accepts the match as the line, escape accepts and keeps
  editing, C-g aborts to the line as C-r found it, any other key accepts the
  match and runs — the matched line is the item's rendering, so it re-reads),
  C-c aborts the line,
  C-d ends the shell on an empty line and deletes forward otherwise) — and
  back again.  The switch is persistent until ESC is pressed once more, and the
  half-typed line crosses over: a tree crosses as its rendering, text crosses
  back read as Scheme — an unclosed form is closed so the work survives the
  crossing, which is editor plumbing, not what the line will mean.
  **A text line is pure Scheme**: it is
  read as Scheme and committed, nothing more — shell commands are typed the
  scsh way, `(run (ls -l))`; a bare word commits as the value it names
  (`car` shows `$1 = #<procedure car …>`, carried in the tree as the comma
  marker `,car`); more than one form on a line, or a line that does not read,
  commits nothing and says so.  A line starting with **`!`** is the escape to
  the standard shell: the rest of the line, verbatim, goes to
  `sh -c "..."` — the `'bourne-shell` property names the shell, defaulting to
  `/bin/bash` when it exists, else `/bin/sh`.  On startup the shell reads an
  init file — `$XDG_CONFIG_HOME/scsh/init.scm` when that variable is set,
  else `~/.config/scsh/init.scm`, else the old `~/.scsh` — plain Scheme,
  loaded with guile's own `load` before the first prompt, where it can set
  `scsh-properties`, define things, anything a Scheme file can; an error
  stops it where it happened, is reported, and the shell starts anyway.
  It commits as
  `(run (SH -c "..."))` — the same foreground machinery any command gets — and
  the history stores it as the readable datum `(! "ls -l")`, never Scheme;
  recall brings back `!ls -l` and it runs the same way again.  Values print REPL-style, numbered:
  `$N = value`.  The prompt names the editor: the
  `'prompt` property is a string (used in both modes) or a lambda, called
  fresh before every line with `#:text` telling it which editor is asking
  (`#t` text, `#f` structured); unset, the defaults are `scsh$ ` structured
  and `scsh> ` in text mode.  At the very start of the line the
  cursor stays before the old form; anywhere else it lands after it, ready for
  the next expression.  (`;` is a hotkey, so a literal semicolon cannot be
  typed -- the same bargain as the structural parens.)  Tab moves the boundary
  of the form you are in -- out or
  back, keeping its direction until it runs out of room and then turning round,
  so pressing it repeatedly walks through every grouping of that form and comes
  back to the one it started in -- and the cursor does not move all the while,
  backspace at a
  word boundary joins with the previous word, delete removes an element, and SPC
  splits a word in two ("ls-l" → "ls" "-l") or opens a new one at its end

## Files

- `engine.scm` — nodes, symbols, locus, and the pure edit ops
  (`insert-char`, `delete-left`, `delete-right`, `insert-form`, `leave-form`,
  `delete-node`, `transpose-node`, and the movements `move-left/right/home/end/up/down`)
- `render.scm` — tree → text plus the cursor's column (the only place text is made)
- `term.scm` — the raw terminal front-end: raw mode by FFI to libc termios, key
  decoding (escape sequences), one-line redraw.  If stdin is not a terminal it
  changes nothing, so the editor still runs over a pipe.
- `repl.scm` — the structural REPL loop.  Dispatch is ONE ordered rule table:
  a rule is `(match handle)` — the matcher picks the keys the row is for, the
  handler does the work and may **decline** (`handled? #f`), sending the walk on
  to the next row, so "assist, never block" is the walker's shape.  `core-rules`
  holds the editor's rows (control keys, `(` and `)` as Scheme structure, the
  printer last — which always handles and types printable characters).  The
  table is passed through the whole machinery (`dispatch-key`, `run-loop`,
  `edit-line` all take it), so a program can supply its own; `run.scm` composes
  the default.  `dispatch-key` is pure
  `(tree locus key) → (tree' locus' action)`; `run-loop` drives it with any key
  source and display; `edit-line` is the same loop on a terminal.
- `scsh.scm` — the scsh layer: what a shell line starts as (the first word opens
  `(run ())`), and what the shell operators do structurally — `|` makes a stage join a
  pipeline: the form you are in becomes the first stage of a fresh pipeline, but
  if it is already a stage of one (or you are at the pipeline's own end) the
  fresh stage simply splices in beside it — pipes never nest by accident, so
  `ls | wc | wc` is `(run (| (ls) (wc) (wc)))`.  A redirection already in the
  line keeps aiming at the command it was aimed at: `ls >f` then `|` wraps the
  pair in an `epf` stage (`(run (| (epf (ls) (> f)) ()))` — scsh's keyword for
  "this command, with these redirections"), and a redirect sitting after a
  pipeline moves down into its last stage when the line pipes on.  `>`
  opens a redirection aimed at the command the cursor is on: beside a plain
  command, after the pipeline when the cursor is on its last stage (where scsh
  applies it anyway), or epf-wrapped around a middle stage — and a second `>`
  stacks after the first.  `&` turns the line
  into `(& …)` and back — and because we have no job control, a backgrounded
  line is given `(< /dev/null)` on stdin (as POSIX prescribes for an
  asynchronous list without job control), so it cannot eat your keystrokes;
  delete that form if you want the terminal attached.  An operator fires **only at the end of a form** — where
  the next thing you see is that form's `)` — and only when there is a command
  to act on.  Anywhere else (just after a `(`, in the middle of a word, before
  another word) the character is simply the atom: you are building the form.
  Each operator is a declining row of the key table (`shell-rules`), so a
  declined `|` falls through to the printer and is typed.  The editor itself
  still knows nothing of any of this; its loops take the key table and a
  `#:seed`.
- `run.scm` — the editor as an scsh REPL: `./editor/run.scm`.  Loads the scsh
  modules, starts each line as `(run ())` with the locus in the command form,
  and evaluates the committed tree.

## Naming a value rather than running a command

A REPL has to be able to show you a variable, and `(run (name))` is not that.
So a comma at the head of a line is the shell's escape to plain Scheme:

    ,name        the variable name
    ,(+ 1 2)     the expression, evaluated

A comma word reads as an `unquote` (`(run (echo ,x))` hands scsh `(unquote x)`,
and scsh interpolates it, so the same mark works inside a command); at the top
of a line `line-datum` strips it, since nothing at the top of a line is inside a
quasiquote — Scheme rejects `,x` there outright.  The comma is written in one go
as part of the word: there is no space or bracket to split `,x`, so a *word* may
carry its prefix, not only a bare leaf.

That is all the shell does for a command: the mark is passed through and scsh
does the rest.  A line that *begins* with such a word is drawn bare — `,foo`,
not `(,foo)` — because it names a value rather than being a form.

## Where you are: the form's two parens, in bold

`render` returns a third value besides the text and the cursor column: a list of
`(start . end)` offsets into that text, marking the **two parens** of the form
the locus is in — exactly two characters, never the form's contents:

    (run (| (ls) (wc)))      the "(" and ")" of the second stage are bold
    (run (| (ls) (wc)))      the line's own, when the cursor is at the root

The form is the one whose `(` the cursor is **on** — sitting just before a form
is sitting on its `(`, and that form is then the target of bold *and* of Tab;
anywhere else the target is the form containing the cursor (the one whose `(` is
behind you).  So these two marks tell you where you are at every step.  Bold the
whole form instead and every subform is bold too, which says nothing as the
cursor moves around inside one.  A comma line has no parens, so it marks
nothing.

Style is derived here exactly as the text is: the tree stays the truth, and
`term.scm` is the only file that knows how to draw it — it splices in
`\x1b[1m`/`\x1b[0m`, working the step back to the cursor out from the *plain*
text, since escape sequences take no space on screen.  A test needs no terminal
to check any of this: the spans are ordinary data, and the loop's draw hook is
handed them alongside the text.

## More than one line: M-RET

A line break is only whitespace to Scheme, so it changes nothing about what the
expression means -- and so it is just more structure in the tree: M-RET inserts
a **break element** where the cursor is (splitting a word if the cursor is
inside one, exactly as the reader would read the halves as two symbols).  A
break moves with the structure when slurp/barf carry it, backspace at a line
start removes it (joining the lines), and `tree->sexp` drops it, so evaluation,
job control and scripts see no difference at all.

The indentation of a continuation line is **derived, never stored** -- there is
no indentation state to get out of sync.  Emacs's rule: a special form's body
(`let`, `lambda`, `define`, `if`, ...) hangs two past the form's `(`; anything
else aligns to the form's first argument.  Plain RET still evaluates the whole
expression; only M-RET starts a line.

The frame is drawn as a block now (`draw` splits at the newlines, clears each
line and anything below), and the cursor is walked back to its row and column.

## Tests

    make -C test-suite engine

Both suites are terminal-free: `editor-engine-test.scm` asserts on tree shapes;
`editor-repl-test.scm` feeds scripted keystrokes through the real loop and checks
every frame that was drawn.

## The terminal

`term.scm` is the only file that touches the tty, and it never leaves it raw.
Raw is a state we are in *while editing*: `with-raw-term` restores on any escape
from a line, `call-with-restored-terminal` (which wraps the whole session) covers
`(exit)` and errors, and handlers on SIGTERM/SIGHUP/SIGINT/SIGQUIT restore before
dying of the signal.  SIGKILL and a crash are the only things that can beat it.
Input is waited for with `select` in short slices rather than one blocking read,
because Guile only runs a signal handler at a safe point.

Text enters the editor in exactly two places — a file/paste import, and the
Enter-line fallback — and both use Guile's own `read`.  There is no parser here.

## Running it

    ./bin/scsh                             # the shell (this editor), on a terminal
                                           # a line starts empty; the first word
                                           # typed opens (run ()) for you
    ./bin/scsh --plain                     # a plain Guile REPL with scsh loaded
    ./editor/run.scm                       # same as bin/scsh, but without the loader

`bin/scsh` may also be given files to load first, and it finds the tree from
wherever it is invoked.

and, with no terminal (keys piped in), which is also how it can be tested:

    printf 'echo hi\n' | guile -q -L . editor/run.scm
    scsh> (run (echo hi))
    hi
    0

## Deferred

- strings and numbers as leaf kinds (today everything is a symbol leaf)
- paste: bulk text import, to be handled at `read` with repair
- colours (bold, for the form the cursor is in, is in -- see below)
- lines longer than the terminal (wrapping) and SIGWINCH redraw
- history (a vector of trees, recalled structurally)
