# AGENT-TODO — findings worth acting on

Notes gathered while working on this port, each waiting on a decision before anything is built
(see `AGENTS.md`).  Line references are to the tree as of this writing.

## scsh API surface

- **`process-group` exported** (done, 2026-10-01).  `(scsh syscalls)` defined it and the cheat sheet
  documents `(process-group)`, but it was missing from the `:export` list.  One word added; our job
  code and its tests use it now.
- **`reduce-port` export reverted** (same day, deliberately).  It is
  `(deprecated-proc port-fold 'reduce-port "Use port-fold instead.")` — a shim that exists only to warn
  about the old name — so leaving it unexported is intentional.  Lesson for any future "unexported but
  defined" audit: **exclude `deprecated-proc` shims**.  The complete set of them is
  `reduce-port` (`scsh/scsh.scm:564`), `file-not-writeable?` (`scsh/fileinfo.scm:110`) and
  `file-writeable?` (`scsh/fileinfo.scm:114`).
- **Unexported, non-`%` names that the cheat sheet does *not* document** — a deliberate public-surface
  decision, not obviously an oversight: `file-info?`, `file-info:device`, `file-info-type`,
  `make-file-info`, `make-group-info`, `make-user-info`, `user-info?`, `user-info:members`,
  `user-info-type`, `group-info?`, `group-info-type`, `errno-msg`, `alist->env-list`,
  `env-list->alist`, `split-env-string`, `guile-sleep`.  (Most other unexported bindings are `%`/`%%`
  record plumbing and correctly hidden.)
- **`status:stop-sig` is bound in nine modules but exported by none**, and its definition cannot be
  found by grep — only its use, at `scsh/procobj.scm:220`.  It is generated dynamically somewhere; if
  we ever want it public, find the generator first.  Our job code sidesteps it by testing the wait
  status directly (`job-stopped-status?`, one line of POSIX).

## The editor: the terminal is never left raw (done 2026-10-01)

Reported from use: "when I exit scsh I'm often left in some kind of raw terminal and have to type
`stty sane`".  Two causes, both fixed.

**The leak.**  `call-with-cooked-terminal` -- which hands a job a sane terminal and takes it back --
gave back `shell-modes`, the *raw* modes.  So the terminal stayed raw between lines; the next
`with-raw-term` then saved *raw* as the modes to restore, and the shell exited raw.  It now hands
back `original-modes`; the next line goes raw again on its own.  `shell-modes` is gone: raw is only
ever a state we are in *while editing*, never one we leave behind.

**The machinery**, so there is nothing left to get wrong: `restore-terminal!` (idempotent, safe with
no terminal), `call-with-restored-terminal` wrapping the whole session in `run.scm` -- Guile runs that
cleanup for `(exit)` too, which is how `(quit)` gets covered -- and handlers on SIGTERM, SIGHUP,
SIGINT and SIGQUIT that restore and then die of the signal.  SIGKILL cannot be caught and a crash
cannot be helped; nothing else changes the terminal and keeps it.

**Two traps found while testing.**  `signal-process` is scsh's, not `(guile)`'s: inside a module with
only `(system foreign)` it is unbound, the handler raised, and the shell simply *ignored* SIGTERM --
`kill` and `getpid` are the core bindings to use.  And Guile only runs a Scheme signal handler at a
safe point: a shell blocked in `read-char` never reaches one, so the handler sat pending and the
shell survived every signal until a key was pressed.  `read-key` now waits for input with `select` in
0.1s slices, which keeps safe points coming.

**Verified on a pty** (modes read from the master by a python harness -- `script` cannot do this: its
stdin hits EOF and the shell exits before it is raw, so the test proves nothing): raw
(`-icanon -echo -isig`) while waiting and while typing, cooked afterwards for C-d, a command then
C-d, C-d with a background job in the table, and each of the four signals.

## The editor: LEFT and RIGHT are opposites (done 2026-10-01)

Reported from use: with the cursor on the `z` of `(((ls df) sdf dsf) zf)`, LEFT jumped to the second
`(`.  `move-left` stepped onto the *start* of the form to its left -- clean over the whole form --
and, worse, onto the start of an *empty* form when there was nothing to step into.  Leftwards of a
form's `)` can only mean that form's **end**, so that is where it goes now; `move-right` gained the
matching step (past the last character of the last element, the next place is the slot before the
`)`, and only from there does it leave the form).  The two now undo each other exactly, which the
tests assert for a handful of positions.

## The editor: Tab keeps the cursor where it is (done 2026-10-01)

Reported from use: with the cursor on the `l` of `ls` in `(run (| (ls) (wc)))`, Tab gave
`(run (| (ls (wc))))` -- the right regrouping -- but dropped the cursor at the end of the form, so the
next Tab was regrouping something else and the two options could never be cycled.  Everything Tab
does happens to the **right** of the locus, so the locus is simply left alone: an element inside the
form keeps its index, a word keeps its offset, and `,`-style places ("just after that `(`") stay
where they are.  `Tab` now cycles the two groupings indefinitely.

The one adjustment is at the right edge: the slot that means "just before the `)`" is clamped to the
form's new end (its offset then means nothing, there being no character there).  `regroup-locus` does
that for both branches.

A position that no longer exists is not followed: when the barf pushes the last element (or the word
the cursor is inside) out of the form, the cursor stays in the form at its end rather than travelling
out with the text -- the alternative, tracking the character, was written first and rejected because
it dead-ends: the element lands beside the form, where the enclosing form is the line, and Tab on the
line does nothing.  Cycling won, as the user asked for it explicitly.

## The editor: Tab cycles through every grouping (revised 2026-10-01)

Reported: on `(ls (a) () () () ())` with the cursor on the `a`, the `)` moves out on each Tab, but at
the end it toggles between the last two groupings for ever instead of coming back round.  Tab chose
its move by looking at the tree alone, and slurp and barf are exact inverses -- so once both are
possible there is nothing left to distinguish them and it can only toggle.

`transpose-node` is now split into `slurp-node` and `barf-node` (with `can-slurp?`/`can-barf?`), and
`regroup` takes the direction Tab went last, keeps going that way, and turns round only when it runs
out of room.  The direction lives in `run-loop`, so any other key forgets it -- a fresh Tab starts by
opening the form outwards, which is the least surprising thing for it to do after you have been
typing.  `transpose-node` remains as the either-way move for callers that do not cycle.

The walk now passes through the state where the form gives up its last child (`(ls () a () () () ())`)
on its way round, since that is the far end of the same journey; the next Tab takes it back in.  If
that reads as too destructive, restricting `can-barf?` to forms with more than one child makes Tab
stop at the original grouping instead -- one line, and it would cost the eject-the-last-child move
that the earlier design had.

## scsh conventions, found from the editor (2026-10-02)

- **No backslash-globbing.**  In bash you write `\*` to defer the glob; in scsh the `run` form
  stringifies a word and GLOBS it, so plain `*` is what you want: `(run (find . -name *.scm))` lists
  the files, while `\*.scm` glob-escapes to the LITERAL name `*.scm` and matches nothing.  (Found
  from the editor: `(begin (run ...) (run (find . -name \*.scm)))` "didn't run" its second form --
  it ran fine and exited 0, having matched nothing.)
- **A `(begin ...)` line's printed value is its last form's status.**  `run` returns the exit status,
  `begin` returns its last form's value, and the REPL prints non-#unspecified results -- hence a lone
  `0` after a begin of two runs.  (Foreground `run`/`&` LINES print no status -- job control returns
  unspecified -- so this is the first time the status has been visible at the prompt.)

## The editor: history -- UP/DOWN recall, ~/.scsh_history (done 2026-10-02)

As the user specified: entries live in `~/.scsh_history`, begin in the first column with `(` (ending
at its own `)`) or `,`, are kept in memory, loaded on startup, and appended after each execution.
UP recalls the previous item, DOWN the next; leaving the line for the first time saves it as a
DRAFT, and DOWN past the newest returns it (bash).  An empty line resets recall to the newest.

The file is parsed with the SCHEME READER, not a line scan: each entry is one readable datum, so
"ends with its closing )" is the reader's job, a multi-line entry spans lines for free, and a
continuation line that happens to start at column 0 (a break inside a bare `,x` line renders that
way) cannot mis-split an entry -- a line scan would.  Hand-edited junk stops the load at that point
and is never overwritten (saving only appends).  `,x` loads as the datum `(unquote x)` and is turned
back into the comma word ("," plus the item's tree); `,x` typed live is ONE word while the loaded one
is two elements -- they render and read identically.  `run.scm` wires it: load at startup, reset at
each fresh line, add after each execution (error or not).  UP/DOWN no longer move structurally --
`move-up`/`move-down` survive as functions for tests; `left` steps out of a form to reach its side.

## The editor: C-r, bash-fidelity fixes (done 2026-10-02)

Reported: "(1) when you hit C-r in bash the visuals start empty, whereas you seem to start with something; (2) bash highlights in reverse video the part of the expression that matches".  Both fixed:

- **search-enter now starts EMPTY** -- nothing pre-selected: the frame shows the bare query, a bare
  C-r RET commits the line as found (exactly bash's empty query), and the first typed letter picks
  the newest match (the narrow clause's `(or pos (length (history-items)))` already scans from the
  newest when pos is #f).
- **`styled` gained a STANDOUT flag** (term.scm): the span splicer renders `\x1b[7m` (reverse
  video) instead of `\x1b[1m` when set.  `draw` takes it as a second optional (opts = (bold
  standout)); the search frame's draw passes a span covering the whole match plus #t, so the match
  is highlighted exactly as bash's is; a failed search stays unhighlighted.

Verified live on a pty: the first frame is `(reverse-i-search)`': ` bare; typing `f` shows the
match in reverse video (`\x1b[7m(run (find . -print))\x1b[0m` in the raw stream -- the `#{.}#`
history entry recalls readably); RET commits and runs it.

## The editor: C-r, the backward search (done 2026-10-02)

Bash's C-r, per the user's spec: each letter narrows (the newest history line containing the longer
query), C-r again steps one match further back, backspace un-narrows, escape accepts and keeps
editing, RET accepts and commits, C-g aborts to the line as C-r found it, and ANY OTHER KEY accepts
the match and then runs as it would have (an arrow leaves search mode and moves; RET commits).

The search is its OWN loop (`search-mode` in `repl.scm`), returning (values tree locus action) to
run-loop, whose C-r row calls it.  The state is (QUERY POS FAILED MATCH-TREE SAVED-TREE SAVED-LOCUS);
`search-enter`/`search-rescan`/`search-accept` are pure helpers, exported for the tests.  The frame
becomes `(reverse-i-search)`': match` via the new #:search-draw hook (edit-line builds it from draw).

**Two lessons from building it, both recorded honestly:**  (1) the search state machine was FIRST
written as a branch of the main loop and misbehaved inexplicably -- the step returned 'evaluate but
the loop kept going, the final return carried the SAVED line instead of the match -- three sessions
of tracing with per-clause prints found the loop's re-entry landing outside the loop's top; the
restructure into its own loop made it work first try.  The lesson: an embedded state machine inside
a REPL loop is harder to reason about than a function that owns its loop; when tracing starts
spraying contradictions, restructure rather than probe further.  (2) a `script`-pty test that feeds
keys with printf is VOID for a shell that goes raw: the bytes arrive before the shell sets raw mode,
the terminal's canonical line discipline eats them (C-r is VREPRINT!), and the test passes/fails
pointlessly.  Delay the keys (sleep 2 first), or use the python pty harness.

## The editor: ; wraps the line in (begin ...) -- a second toplevel (done 2026-10-02)

New hotkey, specified by the user: `;` wraps the whole line's form in `(begin ...)`.  At the very
beginning of the line (the on-the-`(` position) the cursor stays BEFORE the old form; anywhere else
it lands at the begin's toplevel, at the end of the old form, ready to type the next expression.
`wrap-begin` in the engine; a row in `core-rules` (begin is Scheme structure, like the brackets, not
shell policy); `;` again wraps again -- the tree is the truth.

**The begin body is a second prompt.**  `step` now consults the shell's seed not only on an EMPTY
line but at any toplevel slot of a `(begin ...)` body (path null, index > 0 -- never on the head
word -- offset 0): what works at the prompt works there.  The seed's answer is SPLICED at the cursor
(a letter opens a `run` before/after/between the body's forms, `(` opens a Scheme form), with the
seed's locus shifted by the splice.  A seed that opens nothing (the `)` case) is swallowed with the
cursor unchanged.  `splice`/`list-replace`/`remove-at` are exported from the engine for this.

Verified live: `ls;(wc)` -> `(begin (run (ls)) (wc))`.

## The editor: a stage joins its pipeline -- flat, not nested (done 2026-10-02)

Reported: `ls | wc | wc` gave `(run (| (ls) (| (wc) (wc))))` -- the second `|` wrapped the *stage*
into a nested pipe, when the stage is already in a pipe and could simply join it.  `pipe` now has
three cases, in order: the cursor at a pipeline's own end -> the pipe grows a stage; the form is a
STAGE of a pipeline -> a fresh stage splices in beside it (`(run (| (ls) (wc)))` + `|` ->
`(run (| (ls) (wc) ()))`), positioned beside the stage, so a stage followed by another stage gets
its new stage in between; otherwise -> the old wrap, the form becomes the first stage of a fresh
pipe.  The stage is tidied in every case (no dangling empty word travels into the new arrangement).
`ls | wc | wc` now builds `(run (| (ls) (wc) (wc)))` -- one pipe, three stages -- both in the unit
test (every key through the real table) and live.

## The editor: one key-dispatch table (done 2026-10-02)

Reported: "we've got the shell-operators key dispatch cond, the dispatch-char cond, the dispatch-key
cond -- is it not possible to have one key dispatch table?"  Agreed: three conds had accreted as
layers (control keys, Scheme brackets, shell policy) and adding a key meant touching up to three
places.  All three are now ROWS of one ordered table (`core-rules` in `repl.scm`, `shell-rules` in
`scsh.scm`, composed by `run.scm` as `(append shell-rules core-rules)` and threaded through
`edit-line`/`run-loop`/`step`/`dispatch-key` -- a program can pass its own).  A rule is
`(match handle)`; the handler answers `(values tree locus action handled?)` and HANDLED? #f DECLINES,
so the walk falls through -- "assist, never block" is now the walker's shape, and `dispatch-char` and
`shell-operators` are gone as mechanisms (the scsh suite keeps a local `shell-operators` helper that
walks the shell rows, preserving its decline checks).  `finish` returns four values now.

Two bugs the switch caught, both instructive: the walker I first wrote never called the MATCHER -- so
the first row handled every key and every letter was "enter" while the shell rows turned `l` into a
background toggle (found instantly by the pipe smoke test spraying 64MB of frames); and the printer
row excluded space (`>#\space`, copied from the old shell-hook gate) where the old `dispatch-char`
had included it, so SPC stopped splitting words -- caught by the pinned session test.

## The editor: the cursor can rest on the line's first ( (done 2026-10-01)

Reported alongside the two-forms question (shelved by the user, see below): the cursor's leftmost
position was just INSIDE the line's `(` -- the paren itself could never host it.  There is no locus
outside the root, so the root's index-0 slot now renders AT the line's "(": that one position means
both "on the (" and "before the first element", which are the same edit either way.  A just-opened
EMPTY form keeps the cursor between its parens (that is the whole point of the slot the seed hands
you).  Typing at the edge inserts into the first word ("X" -> "(Xls ...)"), verified on a pty with
the screen emulator.

Trade-off, for the record: on a line whose first element is a word, the first LETTER no longer hosts
the cursor -- the positions are "on the (" and "after it", with nothing between, since both were the
same locus.  The right edge is unchanged: the rightmost position is still just BEFORE the line's ")"
(one line away from the same treatment if wanted).

Found while building: the pieces accumulator is in REVERSE final order, and the seed was written in
final order -- the flip silently put the cursor back after the "(" and the direct render tests were
read as success when they showed the old column.  The lesson stands: assert the column, not the
string, and remember acc is reversed.

## The editor: redraw in place for multi-line frames (fixed 2026-10-01)

Reported from use: "if I have a multi-line command, and I arrow to the very end, it scrolls off the
screen with many prompts".  Draw began with `\r`, which returns to column 0 of wherever the cursor
IS -- and after a multi-line frame that is a continuation line -- so every redraw printed the prompt
one line lower and the frame walked down the screen, one prompt per redraw.

`draw` now remembers where it drew the last frame (`*drawn-row*`, `*drawn-lines*` in `term.scm`):
before drawing it moves the cursor UP to the frame's home line, and `leave-frame!` (called by
`edit-line` on the way out, replacing the bare `\r\n`) carries the cursor DOWN past the frame's last
line and resets both counters -- so anything printed between frames (errors, `(jobs)`, the next
prompt) starts clean below.  Verified with an ANSI screen emulator over the pty stream (the pty
itself only shows bytes; a 24x80 screen model shows the truth): after building a multi-line command
and arrowing to the end and back, exactly one prompt is on screen.

Still open: a frame TALLER than the terminal scrolls while printing, and no amount of in-place
redrawing fixes that -- the line-wrap/SIGWINCH work remains deferred.

## The editor: the prompt-line layout (fixed 2026-10-01)

Reported from use: "when I start it, the cursor is at the beginning of the prompt; when I type
something the cursor is after the prompt but the scheme code is on the next line".  Two bugs in the
new block-drawing `draw`, both found by capturing the exact byte stream on a pty:

- `split-newlines` seeded its accumulator with an empty line, so EVERY frame had a phantom empty
  first line -- the prompt printed alone and the code appeared on the line below, with the cursor
  walked "up" onto the prompt line.  The seed is gone (and an empty text still yields one empty
  line).
- The cursor walk-back never accounted for the prompt's width: `\r` plus `col` columns lands at the
  prompt's START when col is 0.  Row 0 now walks to `prompt-length + col`; the other lines start
  where the text does, since their indentation is in the text.

## The editor: multi-line expressions, M-RET (done 2026-10-01)

Conventions chosen by the user: M-RET starts a new line at the cursor (plain RET still evaluates the
whole expression); indentation is Emacs-style tables (special forms' bodies hang +2, others align to
the first argument); UP/DOWN keep their structural meaning for now -- they will become history
recalling later, and forward/back-sexp will be C-M-f / C-M-b when built.

**A break is an element in the tree** (`%break%`, an improper pair -- deliberately neither word nor
form, and `eq?`-unique so nothing typed can ever be one).  `insert-break` puts it at the cursor
(splitting a word if inside one, as the reader would read the halves); backspace at a line start
removes it (joining lines, words stay split); delete-right removes it ahead; the arrows step over it;
slurp/barf carry it as they carry any element; `tree->sexp` drops it, so evaluation, job control and
scripts see no difference.  Indentation is derived at render time (Emacs tables in `render.scm`) --
there is no indentation state.  `render` now returns (TEXT COL ROW BOLD) and `draw` paints a block:
splits at newlines, clears each line and below, walks the cursor to its row/column.  A job's command
text is flattened to one line for the table (`one-line` in `job.scm`).

**Found while building: a Guile 3.0.11 segfault class.**  The renderer's nested `define`s mutating
shared `let*` bindings (the `col`/`tpos` counters closed over by a named-let loop inside a recursive
walk) segfaulted -- deterministically on a form whose first element is a form, under BOTH the
compiler and the interpreter, with correct intermediate results (instrumented prints showed every step
computing right, then the crash in a tail-call re-entry).  Bisected by stubbing; the trigger was the
nested named-let (`first-word`'s `find`) plus the mutable-closure shape.  The renderer is now two
pure passes (pieces, then a linear fold) with no mutable closures; note the fold is O(n^2) in string
building, fine at line lengths.  If segfaults ever return in pure Scheme code, suspect this pattern
first.

## The editor: ON a ( is IN that form (done 2026-10-01)

Reported: "when you are on a (, it doesn't consider you are in that form, it thinks you are on the
outer form, highlighting it, and tabbing on it".  Right -- bold and Tab both went by the form
*containing* the locus, and the position "on a form's (" (locus in the parent at its index) counted as
the parent's.

`target-form-path` is now the single rule both go by: the element at the locus's index, when it is a
form, IS the target -- the rendered cursor column is exactly that "(" -- and otherwise the target is
the containing form.  The user's two cases, verbatim: on a (, that is the form; after a ( but before
the next (, the one before is the form.  (That second position -- inside a form at its start or
between elements -- is a different locus from on-the-(; the two render one column apart, which is
what makes the rule expressible at all.)

The locus rules stay as they were, and stay simple: ON the form's "(" the cursor does not move at
all -- both moves leave the form at its index in the parent, so the locus is still on that "("; inside
the form, REGROUP-LOCUS applies.  One refinement fell out: the end slot ("just before the )") now
FOLLOWS the ")" when a slurp grows the form -- the old clamp left it on the "(" of the element just
slurped in, which broke the two-state cycle (`(run () (ls))` --Tab--> `(run ((ls)))` --Tab--> would
have barfed the wrong form).  It is clamped only when the form shrinks past it.

## The editor: bold marks the two parens (revised 2026-10-01)

Reported from use: "it seems to highlight not just the form I'm in, but all its subforms too.  There
should only at any time be one ( and one ) highlighted."  The first version bolded the enclosing
form's whole span, so on a nested line every subform was bold as well and, worse, **nothing changed
on screen as the cursor moved around inside a form** -- which is why the next sentence was "I can't
arrow the cursor onto the first (": there was no way to see that you had got there.  `render` now
marks exactly the two parens of the enclosing form (two one-character spans).  The form is still
chosen as the user describes it -- the one whose `(` the cursor is at or after.  A comma line has no
parens and so marks nothing.

**Also fixed: a form could not be entered from the left if it was empty.**  `move-right`'s
enter-a-form case required a non-empty form, so `((1) 0 0)` in `(run ())` was unreachable by
arrowing -- and that is exactly where a fresh command form begins.  A sweep over every locus of
several trees, BFS'd through move-left/move-right, now finds nothing unreachable.

## The editor: bold, for where you are (done 2026-10-01)

Bold needs no library and no capability negotiation -- it is `\x1b[1m`, and we already wrote `\x1b[K`
and `\x1b[ND]` by hand.  `render` now returns a third value: a list of `(start . end)` offsets
marking the form the locus is in, brackets and all (at the root, the whole line).  Style is derived
like the text is, so the tree is untouched; `draw` in `term.scm` is still the only thing that knows
about escape sequences, and it works the step back to the cursor out from the *plain* text -- a trap
worth remembering, since escape bytes would otherwise count as columns and throw the cursor off.
The spans are ordinary data, so the tests assert on them with no terminal at all, and the loop's
draw hook receives them next to the text.

Verified on a pty (the escapes, mid-typing): `(run (| (ls) (wc)))` bolds `(ls)`, then `()`, then
`(wc)` as the cursor moves into the second stage -- the nested form, not the whole pipeline.

## The editor: "," -- naming a value, not running a command (done 2026-10-01)

`(run (name))` is not a way to see a variable, so a comma at the head of a line is the shell's escape
to plain Scheme: `,name` evaluates the name, `,(+ 1 2)` the expression.  Two pieces:

- `seed` (in `editor/scsh.scm`) opens nothing for a `,` and lets the comma be typed, so the line
  starts as Scheme rather than as a command;
- `line-datum` (also `editor/scsh.scm`, called by `commit` in `run.scm`) strips the marker.  It
  unwraps the one-element list whose element is an `unquote` -- the document reads as a form, so
  `,x` reaches it as `((unquote x))`.

**A word can carry its prefix** (`word-prefix` in `editor/engine.scm`).  Writing `,x` in one go
leaves ONE word -- no space to split it and nothing structural to break it -- so before this it read
as the symbol `,x` and evaluating it said `Unbound variable: #{,x}#`.  Now a word beginning with `,`
or `,@` reads as that prefix applied to the rest.  This is what makes `,x` work *inside* a command
too: scsh interpolates `(run (echo ,x))` by itself -- verified, it prints the value -- so the mark
works in both places, which the user asked about and could not be sure of.

**A comma line is drawn bare** (2026-10-01, `render.scm`).  The document is the line and is always
bracketed, so `,foo` came out as `(,foo)` -- which reads as a form, and is what prompted "I can't
type ,foo because , expands to (,)".  A line whose first element is a prefixed word now renders
without the line's brackets; every other line keeps them.  Inside a command nothing special happens
at all: the mark is read as an `unquote` and passed through, and scsh's own `run` does the
interpolating (as the user pointed out).

Two things left alone, both worth a decision:

- `'x` typed as one word is still the symbol `'x`, not `(quote x)`.  Guile's reader would give the
  right answer (`read "'x"` is `(quote x)`), but the literal rule keeps only numbers, strings and
  booleans and throws the rest away as a symbol.  Only `,` was asked for, so only `,` was done --
  but the asymmetry is now visible.
- `,x (+ 1 2)` -- a trailing element after the marked one -- is not stripped (the rule is for a line
  that *is* the marked element), so it reaches the interpreter as a call and raises a syntax error.
  Rare, and it fails loudly.

## The editor: backspace walks out of a form (done 2026-10-01)

There is no `(` character to delete -- parens are not in the tree, only forms -- so backspace just
inside a form kills the form, and the line unwinds cleanly: typing `l` gives `(run (l))`, and
backspace takes it to `(run ())`, then `(run)`, then nothing at all.  `delete-left` now has six
cases: a character in a word; a word start with a word before it (join -- the inverse of the SPC
split); just inside a form (the form goes); the end of a node (its last element goes, and the locus
comes to rest at the end of what is now last, so backspace keeps eating leftwards); **between two
elements with a word on the left** (that word's last character goes, the locus resting where the
character was); and **an empty word** (a placeholder, not text -- it goes).  Every step leaves a
well-formed tree, and the session test asserts every frame parses.

**The two dead keys, found by using it (2026-10-01).**  Both positions had something to the left of
them and did nothing at all:

- *Typing `(` was a one-way door.*  A "(" on a fresh line does not leave an empty document: it
  leaves a form with one empty word in it, which renders as `()` and sits at the root, index 0 --
  where no case matched (no enclosing form to kill, nothing to the left, no character to delete).
  The line could never be emptied.  Hence the empty-word case: a placeholder the cursor is sitting
  in is not text, and backspace removes it, so a line can always be emptied.
- *Between two elements,* `(run |(ls))` -- the character to the left is the "n" of `run` -- nothing
  happened, though the same position in a text editor deletes the character there.  It now does.

**Settled: a `(` with content inside it still takes the form with it** (`(run (|ls))` -> `(run)`).
Offered "keep the contents, drop the brackets" (splice the form's children into its parent, the
sibling of Tab's slurp/barf); the user chose today's behaviour -- one key, one form -- and to fix
only the stuck `()` and the dead keys.  Note the mirror position is still a dead key: with the
cursor between two *forms* (`((ls) |wc)`), backspace does nothing, since the element to the left is
a form rather than a word.  Applying the same "kill what is to the left" rule there would delete
that form; not built, and not asked for.

## The editor: literals and quote syntax (done 2026-10-01, one caveat open)

Done, at the read boundary (`tree->sexp` in `editor/engine.scm`), with Guile's reader doing the
reading:

- a leaf that reads as a **number, string or boolean** becomes that literal (`5` -> 5,
  `"hi"` -> "hi", `#t` -> #t); anything else stays a symbol, including other literal kinds
  (characters, vectors) for now;
- a leaf that is a bare **quote prefix** (`'`, `` ` ``, `,`, `,@`) applies to the element after it, so
  a quote typed in front of a form means what it looks like: `'` + `(1)` -> `(quote (1))`;
- rendering hugs a bare prefix to what follows (`(car '(1))`, not `(car ' (1))`).

Also fixed the bug that prompted this: `insert-form` now **splits the word at the cursor** instead of
splicing at the element index, so typing `(car '(` no longer pushes the quote past the new form.

**Settled: `#t` as a shell argument is not a problem.**  A literal in a process form is a literal, and
`run` has never been able to stringify a boolean — scsh proper fails identically
(`(run (echo #t))` -> status 28416, checked with `bin/scsho`), and the scsh way to pass the text is a
string, `(run (echo "#t"))`, which works in both.  Before this change our symbol-only leaves quietly
passed the text `"#t"`, which was our accident rather than scsh's rule; now the editor agrees with
scsh.  So: number, string and boolean are literals everywhere, everything else is a symbol, and no
literals-mode parameter is needed.

## Loose ends in the port (pre-existing, not ours)
## Loose ends in the port (pre-existing, not ours)

- `(suspend)` at `scsh/scsh.scm:814` calls `(signal-process 0 signal/stop)`, but **`signal/stop` is
  bound nowhere** — dead code, as is the `; SIGTSTP blows s48 away. ???` note above it.  `signal/cont`
  does not exist either (only the raw `SIGCONT`).
- Recompiling `scsh/scsh.scm` warns: `set-error-output-port!` (line 629) and `error-output-port`
  (line 644) possibly unbound — guile-2-era leftovers.
- **`call-terminally` reports a failing child as gibberish.**  `scsh/scsh.scm:56` is the wrapper every
  `fork`ed child runs: on an exception it does `(apply display-error #f (current-error-port) args)` --
  Guile-1 shape, where the exception's args *were* the display-error args.  Under Guile 3 that call
  itself fails (`Wrong number of arguments to #<procedure display-error (_ _ _ _ _ _)>`), so the child's
  real error is never seen and it dies with 111.  Found while trying to make a job exit 3: `(exit 3)`
  in a subprocess thunk raises `(quit 3)`, which lands here rather than exiting 3 (`(primitive-exit 3)`
  does, and is what scsh itself uses at lines 64-65).  Needs a Guile-3 shape --
  `(display-error #f (current-error-port) key args)` -- which is a change to scsh proper, so it waits
  for supervision.
- **No `tty.scm`** in this port, though 0.6.7 builds one (431 lines: the `tty-info` termios record and
  the terminal process-group operations).  Our editor implements what job control needs as FFI in
  `editor/term.scm`; scsh proper is still without it.

## Job control

- The mechanism is in our shell layer -- `editor/job.scm` (lifecycle, table, commands),
  `editor/term.scm` (terminal ownership), wired in `editor/run.scm`.  Nothing in `scsh/` was changed for
  it beyond exporting `process-group`.  The design and its provenance are in `JCONTROL.md`.
- **The table exists** (2026-10-01): jobs are numbered (lowest free), carry a state
  (Parked / Running / Stopped / Done) and their command text, and are polled before each prompt, which
  is where a background job's `Done` or `Stopped` is reported and finished jobs are forgotten.  The
  commands are ordinary procedures, since a line can be Scheme: `(jobs)`, `(fg N)`, `(bg N)`,
  `(kill-job N [SIGNAL])`.  `editor/scsh.scm`'s `seed` and the shell's own `run`/`&` still launch jobs.
- **Fixed: a child inherited other jobs' release pipes.** Closing a job's release pipe in the parent is
  only EOF for that job's child if no later fork holds a copy of the write end -- so a parked job could
  never be released once another job had been started in the meantime (it looked like a hang in `wait`).
  Every open release pipe is now tracked in a list and closed in each new child.  The jobs *table* is
  not enough for this, since a job can be dropped from it while its child is still parked.
- **Fixed: the stale-`.go` trap.** `GUILE_AUTO_COMPILE=0` (and `--no-auto-compile`) make Guile load a
  *cached* compiled file even when the source is newer, so edits appear not to take effect.  Removed
  from the test targets and from `bin/scsh`'s shebang.  If a change seems ignored, clear
  `~/.cache/guile/.../guile-scsh/`.
- `(quit)` at the prompt now exits the shell rather than reporting an unbound-variable error.
- **Presentation fixed (2026-10-01).** The table never held two entries for one job -- verified with
  `(length (job-list))` -- but the *launch* printed a table-shaped line, so a launch followed by
  `(jobs)` read as a duplicate.  Now a launch prints bash's `[1] 413981` (number and pid) and the
  table and change notices share bash's shape `[1]+  Stopped  cmd` (with bash's `+`/`-` markers).
- **Fixed: `(fg N)` announced a job that completed in the foreground.**  Bash prints no job-control
  notice when a foreground job finishes (its own output says what happened); it speaks only when one
  *stops*.  `fg` now drops a completed job silently and announces a job that stops again.  Found with it:
  signalling SIGCONT to an already-reaped job raised `No such process`, so both `job-foreground!` and
  `job-background!` now skip the signal once the job is done.
- **Fixed (2026-10-01): how a job ended, in bash's words.**  `job-status-word` decodes the wait status
  -- the low byte is *how* (0 = exited, `#x7f` = stopped, anything else = killed by that signal), the
  high byte is the exit code or the stopping signal -- so the table now says `Done`, `Exit 3`,
  `Terminated`/`Killed`/`Segmentation fault` (the signal's own description), and `Stopped (tty input)`
  for a job the kernel stopped for reading the terminal.  The words are bash's, transcribed from its
  `siglist.c`; Guile has no `strsignal` to borrow them from.
- **Fixed: the shell stopped itself after a foregrounded job ended.**  Handing the terminal to a job
  and taking it back means calling `tcsetpgrp` while we are *not* the terminal's foreground process
  group, which raises **SIGTTOU** -- whose default action is to stop the process.  Symptom: `(& (wc))`,
  `(fg 1)`, type into it, ^D, and the shell stops itself (the outer bash then reports
  `[1]+ Stopped bin/scsh`).  Fix: `ignore-terminal-stop!` in `editor/term.scm` sets SIGTTOU to SIG_IGN,
  called once from `editor/run.scm` -- what ksh/bash/zsh do for the same reason.  SIGTTIN is left alone,
  so a shell that is itself backgrounded still stops when it reads the terminal.
- **Fixed: a space before `(` left a dangling empty word.** Typing `& ( wc )` produced
  `("&" ("wc") "")`, which rendered as `(& (wc) )` and kept a stray gap in the line.  `insert-form`
  now takes the place of an empty word instead of opening beside it (as `insert-space` already did).
- **Fixed: a foreground command printed its exit status.**  `commit` returned the status from
  `job-foreground!`, so every ordinary command trailed a `0` (or `2`, ...) before the next prompt.
  Bash says nothing -- the command's own output says what happened -- so our `run` path now returns
  `*unspecified*`.  (A bare `(run ...)` line is the only thing this affects: a line whose head is
  `run` is a shell line, whereas `(if (run ...) ...)` is Scheme and still gets the status.)
- **Fixed: an empty line at EOF fell through and was evaluated.**  `main` did `(when (null? done)
  (loop))` and then carried on to commit, so a blank line followed by EOF printed `bye`, then
  `error: syntax-error` on the empty document, then `bye` again.  Found by driving `bin/scsh` from a
  pipe (`printf 'l\177\177\177\n' | ./bin/scsh`), which is now a handy tty-free smoke test.
- **Quirk worth knowing:** Guile's `sleep` wants an exact integer number of seconds; sub-second waits
  need `(usleep N)` (microseconds).  Applies to shell code and tests alike.
- Still open: characters and vectors as literals in Scheme lines; and how a stopped job that is never
  resumed should end (currently it sits in the table, reported each time it changes).

