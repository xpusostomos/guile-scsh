# TREE-PLAN — a decorated s-expression tree

**Status: proposal. Nothing here is built.** This is a write-up to decide from; the
repo rule stands that nothing gets written until Chris says go.

Written 2026-10-03. Line references are to the tree as of this writing.

---

## 1. Why

Two drivers, in order of weight:

1. **History fidelity.** A line recalled in a later session must render as it was typed.
   Today `(display '(,f))` comes back as `(display (quote ((unquote f))))` — see §2.
2. **One representation.** A line typed at the prompt, one recalled from history, and one
   built in text mode should produce the *same* tree, so rules behave identically whatever
   the provenance. Today they do not: a typed `,x` is one word, a loaded one is two elements.

A third, smaller: if the tree *is* the s-expression, evaluation needs no projection pass.

## 2. The tree today

The model (`editor/engine.scm:3-6`):

```
tree    ::= (element ...)      a NODE is a list of elements
element ::= string             a WORD (its characters)
          | (element ...)      a NODE
```

`sym?` is `string?`, `node?` is `list?` (`engine.scm:58-60`). **There is exactly one leaf
type: a string of characters.** There is no symbol, number, boolean or string *object* in
the tree. What a word means is decided once, at projection time.

Dumped from the real code (type keys → tree / screen / datum):

| typed | tree | screen | datum |
|---|---|---|---|
| `(display "hi")` | `("display" "\"hi\"")` | `(display "hi")` | `(display "hi")` |
| `(display hi)` | `("display" "hi")` | `(display hi)` | `(display hi)` |
| `(display 5)` | `("display" "5")` | `(display 5)` | `(display 5)` |
| `(display #t)` | `("display" "#t")` | `(display #t)` | `(display #t)` |
| `ls -l` | `("run" ("ls" "-l"))` | `(run (ls -l))` | `(run (ls -l))` |
| `ls \|` | `("run" ("\|" ("ls") ()))` | `(run (\| (ls) ()))` | same |
| `,foo` | `(",foo")` | `,foo` | `((unquote foo))` |

So **string vs symbol is textual**: a string literal keeps its double quotes *in the word*
(`"\"hi\""`); a bare word does not. `5` and `#t` are just words too. The reading happens in
`leaf-plain-datum` (`engine.scm:621-629`): read the word; if it is a number, string or
boolean keep that; otherwise `(string->symbol s)`.

### Nested

It stays flat lists of strings at every depth. Typed keystroke by keystroke:

```
(let ((x 1)) (+ x 2))
   tree   : ("let" (("x" "1")) ("+" "x" "2"))
   screen : (let ((x 1)) (+ x 2))
   datum  : (let ((x 1)) (+ x 2))

(car '(1 2))
   tree   : ("car" "'" ("1" "2"))          <- the ' is a SIBLING element
   screen : (car '(1 2))
   datum  : (car (quote (1 2)))            <- render and datum disagree on sugar

(display '(,f))
   tree   : ("display" "'" (",f"))         <- ,f is ONE word inside a 1-element form
   screen : (display ',f)
   datum  : (display (quote ((unquote f))))
```

Nested shell lines:

```
(|| (epf (ls) (> foo)) (epf (echo fail) (> bar)))
   tree   : ("||" ("epf" ("ls") (">" "foo")) ("epf" ("echo" "fail") (">" "bar")))

ls | wc | grep x
   tree   : ("run" ("|" ("ls") ("wc") ("grep" "x")))

(run (| (epf (ls) (> f)) (wc)))
   tree   : ("run" ("|" ("epf" ("ls") (">" "f")) ("wc")))
```

A break nested inside a form — M-RET inside the first stage of `(run (| (ls) (wc)))`:

```
   tree   : ("run" ("|" ("ls" (break . break)) ("wc")))
   screen : (run (| (ls
            ) (wc)))
   datum  : (run (| (ls) (wc)))
```

and a locus deep in that tree, `((1 1) 0 2)`: path `(1 1)` selects the container `("ls")`,
index 0 the word, offset 2 the end of it.

Two things the nesting makes plain. The shell operators are ordinary words in head position —
`"||"`, `"epf"`, `">"`, `"|"` — the tree does not know they are special; `scsh.scm` reads them.
And render and datum *already* disagree about sugar (`(car '(1 2))` vs `(car (quote (1 2)))`),
because a bare prefix is stored as a sibling word and only fused at projection.

**A line break** is `%break%` = `(cons 'break 'break)` (`engine.scm:69-70`) — an
`eq?`-unique *improper pair*, deliberately neither word nor form, stored as an **element of
the container**:

```
after M-RET at the end of (run
   tree   : ("run" (break . break))
   screen : (run
        )
   datum  : (run)                      <- tree->sexp drops it
```

**The empty word** `""` is the cursor placeholder — "I am about to type here".
**The empty form** `()` is a fresh slot (a new pipeline stage, an empty command).

**A value line** `,foo` typed in one go is a single word `",foo"`; the same line loaded from
history is `("," "foo")` — two elements. They render and read identically (that is the
existing `word-prefix` machinery, `engine.scm:607-613`).

**The cursor is not in the tree.** It is a locus `(path index offset)` — a route down by
child indices, then an element index and a character offset (`engine.scm:14-19`).

**Projection and evaluation**: `tree->sexp` (`engine.scm:656`) drops breaks and empty words,
fuses prefix words into `(quote …)`/`(unquote …)`, and datums the leaves; `line-datum` then
unwraps a value line; `commit` evaluates the result (`editor/run.scm:104-106`).

**History** writes that *datum*: `(write (tree->sexp tree) p)` (`history.scm:138`), and loads
it with `read` + `datum->tree`. That projection is where the sugar dies: Guile's printer has
no `'`/`,` abbreviations, and `datum->tree` only rebuilds a comma at the top level of an entry.

## 3. The proposal in one paragraph

Make the tree an s-expression proper: words become datums, `,f` becomes `(unquote f)` carrying
a *display* attribute of `","`, breaks and slots become attributes on the cons cells that hold
them. Then `eval` takes the tree unchanged (attributes are invisible to it), a sugar-aware
writer emits standard Scheme (`'`/`` ` ``/`,`/`,@` are reader abbreviations of the same datum,
so this is not a new file format), and a reader with source positions enabled
(`read-enable 'positions`) recovers breaks on the way back.

## 4. Decision 1 — what is a leaf — **decided: datums, with as-typed text where it differs**

Leaves become real datums: symbols as symbols, strings as strings, numbers as numbers. The
as-typed text is kept as an attribute on the holding cons cell wherever the printed form is
not what was typed.

What actually reads as what (tested, Guile 3):

```
symbol (same name):  ls foo-bar + - ... -> a.b @ x? x! * ** 1abc 1+ 1- a#b . .. .a | || && a|b \
number:   5 -> 5     +1 -> 1    -1 -> -1     05 -> 5    1e3 -> 1000.0    #x10 -> 16
boolean:  #t #f      character: #\a      vector: #(1)      string: "hi"  ""
reader macros: 'x -> (quote x)  `x -> (quasiquote x)  ,x -> (unquote x)  ,@x -> (unquote-splicing x)
read error (no atom at all):  #     [and the partial forms #\ , #x , " while being typed]
```

So nearly every sequence is a symbol, and the exceptions are a short list. Two of them drive
the attribute:

- **Numbers normalize, permanently.** `05` reads as `5` and prints as `5`; `1e3` prints as
  `1000.0`; `#x10` prints as `16`. A number leaf holding only the datum re-renders `05` as `5`.
  So numbers carry their as-typed text too — the attribute is not only for half-typed states.
- **Partial `#` forms are read errors** (`#`, `#\`, `#x`). Transient: the fallback is a cons
  whose car is a blank/placeholder and whose display attribute holds the text, filled in with
  the real datum as soon as the text is a valid atom of a known kind.

**Strings are auto-closed.** Typing `"` inserts both quotes with the cursor between them, the
same discipline as balanced parens, so an unterminated string is not representable. What that
costs: the leaf is a string datum, so the renderer must re-escape it (`write` semantics), and a
locus offset inside the string indexes the datum's characters while the screen shows the
escaped form — one `"` is two columns. Cursor arithmetic in `render.scm`/`term.scm` therefore
becomes escape-aware (column = length of the escaped prefix). Typing `"` is a *structural* edit,
and backspace at the closing quote deletes the string.

Also settled by this: the `,x`-as-one-word versus `("," "x")`-as-two-elements duality
disappears — both become `(unquote x)`, which is the consistency win of §1.2.

## 5. Decision 2 — where a break lives — **decided: as an attribute**

`(break . break)` as an element is replaced by an attribute on the cons cell, which is what the
destructive primitives in §6 exist to make survivable. Until they are in place, a break as an
attribute would be destroyed by the first structural edit (see §6.2).

## 6. Primitives, if we go destructive

### 6.1 The set

```scheme
;; all of these mutate their first argument and return it
(define (list-splice! lst i v)      ; insert v at index i
  (if (= i 0)
      (cons v lst)                  ; index 0 needs a fresh head cons: the head IS the list
      (begin (set-cdr! (list-tail lst (- i 1)) (cons v (list-tail lst i))) lst)))
(define (list-remove-at! lst i) ...)  ; set-cdr! past element i
(define (list-head! lst n) ...)       ; the destructive list-head: set-cdr! so exactly n conses remain
;; plus SRFI-1's append! — already available, scsh.scm already imports (srfi srfi-1)
```

`list-head!` is what makes the nine sites in §6.6 convertible *without* restructuring them: it
truncates in place instead of allocating, so the surviving conses keep their identity. (Earlier
notes called it `list-truncate!`.) Mind its off-by-one: the version written so far puts the
`set-cdr!` at depth `n`, leaving `n+1` conses — which is why the `list-replace` example built on
it *inserts* rather than replaces. It has to leave exactly `n` to be a drop-in for `list-head`.

`append!` does not copy (`(eq? (append! a b) a)` is `#t`), so attributes on the spine survive.
Three things to know about it:

- it mutates its first argument's last cdr, so that list must be one you own;
- the empty-prefix case just returns the second list (`(append! '() b)` is `b`) — passing a
  retained tree there aliases it with no copy;
- index 0 still needs a fresh cons, as above (fine — a new element brings its own cons).

### 6.2 What this buys, measured

With an attribute on every cons of `(run ls wc)`, replacing element 1 with `X`:

```
append version   result: (run ls X wc)   attributes: (#f #f #f 2)   (input also destroyed)
set-cdr! version result: (run ls X wc)   attributes: (0 1 #f 2)
```

`append` copies all but its last argument, so the copied head conses lose their attributes;
the destructive splice keeps them. That is the whole argument for §6.

### 6.3 The invariant that comes with it

*An op mutates its input; the caller must not retain a tree it is going to edit.*

Every place that retains a tree across an edit must take a copy. The complete list today:

- `history-previous` returns the stored entry itself (`history.scm:163`) → **copy on recall**;
- `*draft*`, the in-progress line stashed while arrowing through history (`history.scm:161`);
- C-r's `SAVED-TREE` (`editor/repl.scm:103-105`);
- tests that hold a tree and then edit it.

Sharing must also go: no `append`-shared tails, no handing out stored trees.

**This is why step 1 cannot be a no-op** — unless history holds strings (§9.1), in which case
the first entry on this list disappears and the rest are trees the user owns and nothing else
edits. Swapping in destructive primitives without either measure would make the first keystroke
after a history recall write straight through into the stored entry.

### 6.4 A trap that found us: Guile dedupes quoted constants

Destructive ops plus the compiler's constant pool is a live hazard, and it bit the test suite on
the first run. Guile shares *equal quoted sub-constants*, so `'("!" "")` and `'(run (ls ""))`
contain **the same** `("")` cons:

```
(define a '("!" ""))    (define b '(run (ls "")))
(set-car! (list-tail a 1) " |")
b  =>  (run (ls " |"))          <- written through
```

An op handed a quoted literal therefore mutates every other constant that shares structure with
it. Three test fixtures were doing exactly this and are now built with `(list …)`.

The rule that follows is not "do not hand ops literals" but the plainer fact behind it:
**quoted data is a constant, and destructive ops require mutable structure.** A constant is
constant by definition (mutating one is an error in R7RS, and Guile does not always stop you),
so the caller must supply a mutable equivalent. The idiom for a one-off is a quasiquote with an
unquote — `` `(,"") `` builds a **fresh** cons each time it is evaluated, and mutating one does
not touch another:

```
(define (f) `(,""))
(eq? (f) (f))  =>  #f                 ; fresh cons each evaluation
(set-car! a "X")  =>  (("X") (""))    ; the other is untouched
```

(In the tests, `(list …)` says the same thing more plainly and is what the three fixtures use.)

Production is clean — `fresh` is `'()`, `seed` goes through `sexp->tree` (which copies), history
items are copies, and the editor's own quoted lists only feed `member` — but it is a trap for
every test written from here on, and it is invisible until something unrelated changes.

### 6.5 Cycles — conceded, not a real risk

A cycle only appears if a list is appended onto its own suffix, e.g. `(append! lst (list-tail lst k))`.
The ops in §6.1 do not do that, and the move ops (slurp `engine.scm:368`, barf `engine.scm:380`)
take a sibling from *after* the cursor and place it *before* or *inside*, so the natural
implementations cannot form a ring. A cheap guard in the move ops (or one cycle check in the
tests) would close it, but it is insurance, not a blocker.

### 6.6 The ops that still copy — the step-3 checklist

Step 1 made the three primitives destructive, but nine sites still rebuild a live container by
copying. Until they are converted, an attribute on the spine is dropped by an ordinary edit.
This is step 3's work, and it is a checklist rather than a design problem.

| where | shape |
|---|---|
| `insert-break` `engine.scm:125` | `(append (list-head cont i) (list left %break% right) (list-tail cont (+ i 1)))` |
| `insert-char*` `engine.scm:219` | `(append cont (list c))` — the cursor-at-the-end case |
| `insert-form` `engine.scm:325` | `(append (list-head cont i) inserted (list-tail cont (+ i 1)))` |
| `slurp-node` `engine.scm:408` | `(append me (list next))` |
| `tidy` `scsh.scm:175` | `map` — copies every container it walks |
| `absorb-redirs`, `epf-stage` `scsh.scm:192-205` | `(append (list-head cont i) … (list-tail cont …))` |
| `pipe-at` `scsh.scm:405-455` | the same shape, four sites |
| `background` | `(append body (list (devnull)))` |

**How they convert** — and a correction. An earlier version of this section claimed the sites
could not be fixed with `append!`, because `list-head` copies before `append` is called. That is
true only if the *library* `list-head` is used. With the destructive `list-head!` (§6.1) there is
nothing to copy, and `append!` sews the pieces back with every surviving cons keeping its identity:

```
before                    : (run ls wc)  tags (0 1 2)
split, sew (tail hoisted) : (run X wc)   tags (0 #f 2)     <- conses 0 and 2 are the same objects
```

So the sites keep their present shape, converted by `list-head!` + `append!`.

The catch is evaluation order. `append!` evaluates its arguments left to right, so if the tail is
written inline after the head, `list-head!` truncates the list before the tail is ever read:

```
tail NOT hoisted          : ERROR: list-tail (run) 2
```

Every one of the nine sites is written `(append (list-head cont i) X (list-tail cont j))` — tail
*after* head — so each needs its tail hoisted into a `let` first, exactly as the `list-replace`
example does. Alternatively they can be restructured onto `splice`/`remove-at`, which relink
without truncating and so need no hoist; note that several sites replace one element with a
*sequence* (`(list left %break% right)`), which neither of those takes, so `list-head!` +
`append!` is the shape that fits them as they stand.

`tidy` needs a destructive variant of its own either way, since `map` allocates.

#### Converted (2026-10-03)

All of the above are done, and so are `tidy` / `drop-trailing-empties` / `drop-empty-tails`
(now destructive, cutting in place; `drop-trailing-empties` writes `set-cdr!` rather than
reversing twice) and `slurp-node` / `barf-node` (which used `append` and `butlast`).

Measured: tag every cons of the tree, run one op, count how many of the *original* cons objects
are still reachable in the result.

```
|  (run (ls))                6 -> 6   original kept 3/3    new 3
|  (run (| (ls) (wc)))        8 -> 8   original kept 7/7    new 1
>  (run (| (ls) (wc)))       10 -> 10  original kept 7/7    new 3
|  (|| (epf (ls) (> foo)) …) 18 -> 18  original kept 17/17  new 1
&  (run (ls))                3 -> 3   original kept 2/2    new 1
*  (run (ls))                7 -> 7   original kept 3/3    new 4
type x at end of (ls)        3 -> 3   original kept 3/3    new 0
```

Every original cons survives; the "new" cells are the ones the edit genuinely adds (the fresh
stage, the redirect, the eglob form, the head cons when the head value changes). The ops no
longer copy.

**Three traps found while converting** (all now fixed):

1. **A value read after an alias moved.** `slurp-node` computed `(length me)` for `kept-locus`
   *after* `me*` — which **is** `me` — had been appended to, so the "old length" was the new
   one and the cursor landed one slot short. Same shape in `barf-node`. The rule: with aliases,
   read the old value before the mutation.
2. **`append!` is a core binding**, visible in every module — so no definition is needed. It
   looked undefined only because listing it in `#:export` creates an *unbound* binding that
   shadows the core one. Engine therefore neither defines nor exports it.
3. **`copy-tree` is also a core binding**, so `tree-copy` is the name used here, to keep the
   engine from overriding it in every importing module.

## 7. Reader and writer

**Writer** — standard Scheme, with two massages:

- `(quote x)` → `'x`, `(quasiquote x)` → `` `x ``, `(unquote x)` → `,x`,
  `(unquote-splicing x)` → `,@x`. All four are reader abbreviations for exactly those datums,
  so a plain `read` recovers identical data.
- breaks: a newline where the `break` attribute says.
- a leaf whose printed form is not what was typed (a partial word) is written with `write`'s
  escapes so it reads back.

**Reader** — `read` with `(read-enable 'positions)`, so source line/column come back on the
pairs; breaks are reconstructed from them. The sugar comes back for free (`'x` reads as
`(quote x)`), and the `display` attribute is reattached when a form's head is one of the four
prefix symbols.

## 8. What does not change

- **The locus stays external.** You were right that this is separable — `(path index offset)`
  is a complete addressing scheme and there is no reason to move it into the tree.
- **Rendering still has to un-project** (`write` is not the renderer's job for words: it must
  print symbol names verbatim, and the sugar forms as `'`/`,`), so the renderer and the history
  writer are two different printers over the same tree. Both need to know the attributes.
- `line-datum`, the shell rules, and the rest of the scsh layer are unaffected except that
  `tree->sexp` becomes "strip decorations" rather than "project".

## 9. Migration

Old history files hold plain datums; new ones hold decorated ones. A version marker (a first
line such as `; scsh-history 2`) is the cheapest discriminator; without it the loader cannot
tell a tree-with-strings from a datum-with-symbols. Whatever we do, hand-edited junk must keep
stopping the load safely, as it does now.

### 9.1 History in text form — **decided**

History holds **strings**, in memory and on disk, the same form in both.

Today `*items*` holds trees (`history.scm:54`) while the file holds `(write (tree->sexp tree))`
(`history.scm:138`) — so in-memory is strictly better than on-disk, and the same feature has two
behaviours depending on whether you have restarted. Unifying them is the reason.

What it buys beyond tidiness:

- **A string is immutable, so every recall parses a fresh tree.** That removes the history
  entry from the retention list in §6.3 entirely — no copy-on-recall to remember, no path by
  which a destructive op can write into a stored entry.
- **Text mode gets simpler**: it wants a string for the buffer and currently renders a tree to
  get one (`textline.scm:74`); it would just take the string.
- C-r can compare strings directly instead of rendering each item (`history.scm:40`).

Two things already work and are not reasons for the change, for the record: C-r searches the
*rendered* form of each stored tree, and text mode already shares the tree history by rendering
it (`text-commit-tree` goes the other way). So neither mode is blocked today.

**Sequencing note.** The string available today is the *projected* datum, so adopting it now
brings the projection's sugar loss into the session (`(display ',f)` expands on recall in the
same session, which currently works). It becomes faithful when step 2's sugar-aware reader and
writer land. Either bundle it with step 2, or take the transient loss and fix it there.

## 10. Costs

- Every op that rebuilds a container gets a destructive version: `insert-char*`, `insert-space`,
  `insert-form`, `insert-break`, `delete-left`, `delete-right`, `delete-node`, `slurp-node`,
  `barf-node`, `wrap-begin`, `with-container`, plus `splice`/`list-replace`/`remove-at`
  (`engine.scm:47-53`) — and `scsh.scm:27-31` shadows the last three with its own copies, so
  both must move.
- The duplication invariant in §6.3 becomes permanent: any new code that retains a tree must copy.
- Two printers (render, history-write) that both understand the attributes.
- The history file format changes, with a migration path.

## 11. The step plan

Agreed direction, in three steps. Nothing is built yet.

**Step 1 — destructive primitives, with the duplication. — DONE (2026-10-03)**

What landed:

- `list-replace`, `splice`, `remove-at` in `engine.scm` are destructive, keeping their names and
  arguments so no call site moved. Only index 0 needs a fresh cons (the head cons *is* the list);
  the simple forms turned out to be *exactly* behaviour-identical to the copying ones — verified
  over every index of lists up to length 4, valid and invalid: 75 calls, same results and same
  errors. That is a stronger guarantee than "should be the same".
- `scsh.scm`'s shadowing copies of `list-replace`/`splice` were removed, so the whole tree shares
  one set of primitives (its `butlast`/`last` stay — the engine does not export those).
- `copy-tree` added to `engine.scm` (keeps `%break%` by identity, so `break?` still holds) and
  exported.
- `history-previous` copies on the way out (§6.3). The other three retention points need nothing
  today: the draft and C-r's saved tree are the user's own line and nothing else edits them.
- Three test fixtures were passing quoted literal trees; they are built with `(list …)` now (§6.5).

Verified: all 8 suites and the scheme-shell suite pass; live in the shell, recalling `(run (ls -l))`,
appending ` -a`, executing, and walking history back shows the original entry pristine.

`list-truncate!` and `append!` were not needed *for step 1 itself* — nothing calls them yet. They
are needed for step 3, along with the nine copying sites in §6.6; see that section for why
`append!` alone does not fix most of them.

**Step 2 — leaves become datums.**
Symbols, strings, numbers, booleans; as-typed text as an attribute where the printed form
differs (§4). This is the substantive step, and the non-mechanical part is the ATOM edits:
`insert-char`/`insert-space`/`delete-left` stop being string surgery and become
edit-the-text-then-re-derive-the-datum, which needs one uniform `leaf-text` accessor
(symbol → `symbol->string`; number → the attribute; string → the string). Get that wrong and
types flip wrongly under backspace. Also here: auto-closed strings, and the escape-aware cursor
arithmetic they require.

**Step 3 — breaks become attributes.**
Retire `(break . break)`; the writer emits the newline from the attribute (§7).

## 12. Still open

- The renderer and the history writer become two printers over one tree, both attribute-aware
  (§8). Worth writing both before step 2 lands, so the pair is designed together.
- Whether the number attribute is worth its weight, or whether normalizing `05` to `5` on
  screen is acceptable.
- The history file version marker and what the loader does with pre-change files (§9).
- Open question 3 from before is still fair: the cheap alternative — keep the tree as it is and
  serialise the *tree* to history losslessly — fixes the reported annoyance, keeps trees as
  values, and costs no primitives. It buys less, but it is a fraction of the work.
