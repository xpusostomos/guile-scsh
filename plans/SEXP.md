# SEXP.md — making the tree a real s-expression

**Status: ON HOLD (2026-10-04).** Chris is thinking it over. Step 1 of the step plan is **done
and in the tree**; steps 2 and 3 are not started.

This is the full record of the discussion: the proposal, every objection raised (mine), the
evidence for and against each, the solutions Chris found, the decisions reached, and the honest
pros and cons of going ahead. `plans/TREE-PLAN.md` covers some of the same ground as a working
file; this one supersedes it.

---

## 1. The proposal in one line

Make the editor's tree a **real s-expression**: symbols as symbols, strings as strings, numbers
as numbers, with the few things Scheme cannot express carried as *attributes* on the nodes that
hold them — so `eval` takes the tree directly, and one representation serves typing, history and
text mode alike.

## 2. Why — the two drivers

1. **History fidelity.** A line recalled in a later session must render as it was typed. Today
   `(display '(,f))` comes back as `(display (quote ((unquote f))))` — functionally identical,
   visibly wrong.
2. **One representation.** A line typed at the prompt, one recalled from history, and one built
   in text mode should build the *same* tree. Today a typed `,x` is one word; the same line
   loaded is two elements. They render alike but are not alike, so any rule that inspects the
   tree can behave differently by provenance.

A third, smaller: if the tree *is* the datum, evaluation needs no projection pass.

## 3. What the tree is today

```
tree    ::= (element ...)      a NODE is a list of elements
element ::= string             a WORD (its characters)
          | (element ...)      a NODE
```

`sym?` is `string?`, `node?` is `list?`: **one leaf type, a string.** No symbol, number, boolean
or string *object* anywhere in the tree.

| typed | tree | screen | datum |
|---|---|---|---|
| `(display "hi")` | `("display" "\"hi\"")` | `(display "hi")` | `(display "hi")` |
| `(display hi)` | `("display" "hi")` | `(display hi)` | `(display hi)` |
| `(display 5)` | `("display" "5")` | `(display 5)` | `(display 5)` |
| `(display #t)` | `("display" "#t")` | `(display #t)` | `(display #t)` |
| `ls -l` | `("run" ("ls" "-l"))` | `(run (ls -l))` | `(run (ls -l))` |
| `,foo` | `(",foo")` | `,foo` | `((unquote foo))` |

String vs symbol is **textual**: a string literal keeps its quotes *in* the word. Meaning is
decided at projection (`leaf-plain-datum`: read the word; keep number/string/boolean; else
`string->symbol`).

- **Break** — `%break%` = `(cons 'break 'break)`, an `eq?`-unique improper pair stored as an
  **element**. `tree->sexp` drops it.
- **Empty word** `""` (cursor placeholder); **empty form** `()` (fresh slot).
- **Bare prefixes** (`'`, `` ` ``, `,`, `,@`) are *sibling words*, fused into `(quote …)` only at
  projection — which is why render and datum already disagree: screen `(car '(1 2))`, datum
  `(car (quote (1 2)))`.
- **The cursor is not in the tree** — a separate locus `(path index offset)`.
- **History** writes the *datum* (`(write (tree->sexp tree))`) and loads with `read`.

---

## 4. What it would become

Leaves are datums. A form is a list whose head is the symbol `run`, `|`, `epf`, `>`, … — which is
what they already are to scsh, whose macros give them meaning. `,f` is `(unquote f)` carrying a
*display* attribute of `","`. A break is an attribute on the cell that holds it. `eval` sees none
of the attributes, so the tree goes straight to `eval`. The **writer** emits standard Scheme
(the four prefixes are reader abbreviations of exactly those datums, and a break is a newline),
so this is not a new file format; the **reader** is `read` with `(read-enable 'positions)`, which
recovers breaks from source positions.

---

## 5. The debate, objection by objection

This is the substance of the discussion. Each item is an objection I raised, with the evidence I
had, Chris's answer, and how it landed. Four of my objections turned out to be **wrong**, four
**stood** and shaped the design, and the rest are costs rather than blockers.

### 5.1 "`run`, `epf`, `&&`, `>` are not Scheme" — **I was wrong**

**Mine.** I argued the tree holds shell syntax that isn't Scheme, so it couldn't be a Scheme
datum.

**Chris.** scsh as originally written is 100% Scheme; `run`, `epf`, `&&`, `||` are syntax rules
and `|`, `>`, `&&` are symbols. Either way they are Scheme.

**Verdict: he is right and I was sloppy.** They are ordinary symbols; scsh's macros supply the
meaning. This removes the objection entirely, and it is load-bearing for the whole plan: without
it, nothing else follows.

### 5.2 "Object properties are out-of-band — they can't carry history"

**Mine.** The proposal was to hang annotations on nodes with Guile's object properties. I
measured that they do not survive `write`/`read`:

```
written: "(quote f)"
reread : (quote f)   its display property: #f
```

Eval never looks at them, so they are fine for eval — but history *is* write-and-read, so the
annotations, which are the one thing that must persist, are exactly what is dropped.

**Chris.** You need a custom reader and writer anyway — but the writer emits **no special
tokens**: it writes `,` where the datum is `(unquote …)`, `,@` for `unquote-splicing`, a newline
where the break attribute says. That is plain Scheme, and a plain `read` recovers the same data.
We have not invented a file format. And cursors aren't stored anyway.

**Verdict: my point stands but dissolves into his.** He is right that the *text* is standard
Scheme; the annotations are recovered from source positions (`read-enable 'positions`), which is
still plain text. What survives of my objection: the reader must be position-aware, and the
writer must be sugar-aware — so the persistence depends on that pair, not on the properties.

### 5.3 "Properties on `()` and on symbols are value-global"

**Mine.** Measured:

```
(set! (p '()) 'cursor)  => every () in the process reads 'cursor   ; (list), (cdr '(1)), ...
(set! (p 42) 'c)        => every 42
(set! (p 'foo) 'c)      => every foo, because symbols are interned
(two equal strings)     => independent  — pairs and strings ARE per-object
```

So per-instance state cannot live on an atom or on `()` — and the fresh slot *is* `()`.

**Chris.** Every atom belongs to a cons cell, so attach to the **owning cons cell** and the
symbol problem is gone. For the empty list: `(eq? '() '())` is at odds with what you'd expect —
execute `(eq? (read "(quote ())") (read "(quote ())"))` and you get `#f`: until you evaluate it
down, `(quote ())` is a *pair*, a distinct object, so it can be hung off. And a bare `()` in our
tree "is not valid Scheme — it is an empty cons cell waiting for a user to put something in it",
so a cons can represent it.

**Verdict: partly right, with one correction from me.** `(eq? '() '())` is actually `#t`; what
returns `#f` is `(eq? '(quote ()) '(quote ()))` — two distinct *pairs*, which is exactly the
leverage he wants (a pair is a heap object). But the *bare* `()` element in the tree is still the
immediate, and his suggested replacement isn't a drop-in:

```
(cons '() '()) prints as  (())      <- not ()
(null? (cons '() '()))    #f
```

So an empty form needs a *distinct marker* rather than a plain cons. **That, however, is only
needed if anything attaches to it — and with the cursor external (§5.11) nothing does, so plain
`()` is fine and round-trips through `read`.** The objection is real but has no consequences.

### 5.4 "Properties on the spine are lost on copy, or aliased when shared" — **I was wrong**

**Mine.** The editor's ops are `append`-based. `list-head` allocates, `list-tail` shares. So an
attribute on a cons *before* the edit point is destroyed by a fresh copy, and one *after* it is
literally the same object as in the old tree — written through. Measured, `(run ls wc)` with
tags `(0 1 2)`, splice at index 1:

```
after  tags: (#f #f 1 2)
```

**Chris, first answer:** it is not *truly* shared structure — every part of the tree has its own
cells at the end of the day; the discarded conses are garbage, not "the working structure".
**I conceded this half**: in the steady state there is one live tree, there is no undo in the
editor, so sharing across *versions* is sharing garbage. I checked the one place something is
retained — `history-previous` returns the stored entry itself — which is narrow.

**Chris, second answer — the one that matters:** the loss is because I used the *library*
`list-head`. Write a **destructive** one that severs in place instead of allocating:

```scheme
(define (list-head! lst n)          ; he first called it list-truncate!
  (cond ((null? lst) (error "Index out of bounds or list is empty"))
        ((= n 0) (set-cdr! lst '()) lst)
        (else (list-head! (cdr lst) (- n 1)) lst)))
```

and then sew with `append!` instead of `append`. No cells copied, none lost, every atom stays
joined to its cell. Measured with the tail captured first:

```
before                    : (run ls wc)  tags (0 1 2)
split, sew (tail hoisted) : (run X wc)   tags (0 #f 2)     <- 0 and 2 are the same objects
```

**Verdict: I was wrong, and this is the crux of the whole plan.** With a destructive head and a
destructive append, spine attributes survive ordinary editing. My "append! can't fix it" claim
(§5.5) was a consequence of the same mistake.

### 5.5 "`append!` can't fix the nine sites — `list-head` already copied"

**Mine.** After listing nine tree-rebuilding sites, I claimed `append!` wouldn't help most of
them, because `list-head` has already copied the first *i* conses before `append` is called.

**Chris.** True only if you use the library `list-head`. With `list-head!` there is nothing
copied, so `append!` sews it up. And he showed the shape, with the tail saved first precisely
because `list-head!` destroys it.

**Verdict: he is right.** I measured the *hazard* he was guarding against, which is real and
sharp:

```
tail NOT hoisted          : ERROR: list-tail (run) 2
```

`append!` evaluates its arguments left to right, so an inline tail is read *after* the cut. All
nine sites were written tail-after-head, so each conversion needed the tail hoisted into a `let`.
That is a mechanical edit, not a redesign — which is exactly his "very little impact" claim.

### 5.6 "Destructive ops introduce cycles" — **conceded**

**Mine.** Pure ops can build a wrong tree but never a circular one; `set-cdr!` can produce a ring,
and the renderer would loop forever. A new failure mode, hard to debug.

**Chris.** It is very very hard to imagine creating a cycle with a small selection of primitives
— `append!`, `truncate-head!` — you would have to go out of your way.

**Verdict: he is right.** A cycle needs a list appended onto its own suffix
(`(append! lst (list-tail lst k))`), and the natural slurp/barf implementations take a sibling
from *after* the cursor and place it *before* or *inside*, so they link forward only. At most a
one-line guard; not a reason to avoid the design. I had over-weighted it.

### 5.7 "Half-typed words aren't datums" — **real objection, solved by Chris**

**Mine.** `"`, `#`, `1.`, `,`, `#\` mid-keystroke are not datums, so datum leaves need a fallback
and the leaf's type is unstable as you type.

**Chris.** Two answers. First, a structured editor should not allow mismatched `"` any more than
mismatched `()`: **type `"` and the closing `"` appears immediately**, so once a quote is in play
it is a string and stays one until deleted. Second, in Scheme practically every sequence of
characters is a valid symbol; the few exceptions we would have to teach the tree anyway. For
anything genuinely unparseable, leave the car blank with a display attribute and fill it in when
it is clear what atom it is.

**Verdict: the objection is real, and his answers cover it.** I checked his symbol claim, and it
holds better than I expected:

```
symbol (same name):  ls foo-bar + - ... -> a.b @ x? x! * ** 1abc 1+ 1- a#b . .. .a | || && a|b \
number:   5 -> 5     +1 -> 1    -1 -> -1     05 -> 5    1e3 -> 1000.0    #x10 -> 16
boolean:  #t #f      character: #\a      vector: #(1)      string: "hi"  ""
reader macros: 'x -> (quote x)  `x -> (quasiquote x)  ,x -> (unquote x)  ,@x -> (unquote-splicing x)
read error (no atom at all):  #     [and the partial forms #\ , #x , " while being typed]
```

Auto-closing strings removes the largest case outright. The remaining cases are leading-`#`
forms (partial, transient) and numbers (§5.10).

### 5.8 "The text is the source of truth; types flip under backspace" — **stands, and is answered by the attribute**

**Mine.** Editing is character-level: every keystroke is a partial word. If a leaf holds an
interpreted value, then to backspace through `5x` → `5` you must keep the characters anyway, so
the text stays the source of truth and the datum is a second representation alongside it.

**Chris.** That is what the **display attribute** is for — a string attribute on the parent cons
cell. And the fallback for anything not yet a valid atom: car blank, display holds the text.

**Verdict: the objection stands and *is* the design.** The conclusion is not "don't do it" but
"each leaf carries both its datum and its text, and the ATOM edits edit the text and re-derive
the datum". One object, two facets, kept in sync by construction. The practical consequence is
that every op needs one uniform accessor — call it `leaf-text` (symbol → `symbol->string`;
number → the attribute; string → the string) — and that is the load-bearing piece of step 2.

### 5.9 "Rendering is un-projection — the sugar loss becomes universal"

**Mine.** The screen is built from the tree and must show `',f` because that is what was typed.
If the tree held `(quote (unquote f))` with no attribute there is no way back, so the sugar loss
would become permanent and universal rather than a history-only annoyance — and it would be a
*new* loss, introduced by the fix.

**Chris.** We are moving to an end game where we keep the sugar by a different means — the
display attribute plus the sugar-aware writer and reader.

**Verdict: stands as a cost, defused by the attribute.** Consequence to hold onto: the renderer
and the history writer become **two printers over one tree**, both attribute-aware, and they must
be designed together. The attribute is not optional; without it this objection is fatal.

### 5.10 "Numbers normalize, permanently"

**Mine.** `05` reads as `5` and prints as `5`; `1e3` prints as `1000.0`; `#x10` prints as `16`. So
a number leaf holding only the datum re-renders `05` as `5` — not a transient mid-typing state
but a permanent one.

**Chris.** *(not addressed specifically)*

**Verdict: stands, as a concrete cost, and is an open question.** Either numbers carry their
as-typed text too (one more reason the display attribute is pervasive) or typing `05` shows `5`.

### 5.11 "A cursor in the tree is weaker than the locus" — **conceded**

**Mine.** A per-node cursor (0/1/2 on a list, an offset on an atom) is weaker than
`(path index offset)`: it cannot name "between element i and i+1" or "inside element i at
offset k"; it couples tree and cursor so you lose "two trees, one cursor" for tests, diffs,
undo; and mutating it per keystroke makes the tree not a value.

**Chris.** "If you think cursors are better kept in an external description of how to navigate
down a tree by offsets and indexes, fine, why not keep doing that? That's an argument about
specifically keeping the cursor value in the tree — it is not an argument against using a
different kind of tree."

**Verdict: he is right and the objection is separable.** The locus stays as it is. And there is a
pleasant bonus: with the cursor external, the empty form needs no attribute at all (§5.3), so
plain `()` survives untouched.

### 5.12 "History hands out its stored tree — is that corruption?"

**Chris's report.** He suspected `history-previous` returning the stored tree was a bug, and
reported seeing things get lost in the history when re-editing a recalled line.

**Me.** I tested it and could **not** reproduce: with the ops then in the tree (non-destructive),
recalling the older of two entries and editing it left both entries intact and the file
unchanged — because the ops built new trees and never wrote to a cell. I asked for the keystrokes.

**Verdict: not a bug then — but a certainty later.** Under the destructive ops of step 1, the
first keystroke after a recall would `set-car!`/`set-cdr!` the stored entry. So copy-on-recall was
added with step 1 (and is now in the tree).

**Chris's bigger answer:** make history a **string**, in memory and on disk. A string is
immutable, so every recall parses a fresh tree — which deletes the retention point altogether:
no copy-on-recall to remember, no way for any op to write into a stored entry. It also simplifies
text mode, which wants a string and currently renders a tree to get one.

### 5.13 Two incidental traps, found by doing step 1

Neither was predicted; both are now fixed and recorded.

- **Guile dedupes equal quoted constants.** `'("!" "")` and `'(run (ls ""))` share the inner
  `("")` cons, so an op handed a literal writes through to every constant that shares structure:

  ```
  (define a '("!" ""))    (define b '(run (ls "")))
  (set-car! (list-tail a 1) " |")
  b  =>  (run (ls " |"))
  ```

  Three test fixtures did exactly this. Chris's formulation of the rule is the one to keep: **you
  are not supposed to modify quoted data — it is constant. If you want a structure like `'("")`
  that is modifiable, write `` `(,"") `` and you have a different cons cell** (`(eq? (f) (f))` is
  `#f` for `(define (f) `(,""))`). Production is clean; tests are the trap.
- **Core-binding clashes.** `append!` is a *core* binding, visible in every module — it needs no
  definition at all, and it looked undefined only because listing it in `#:export` creates an
  *unbound* binding that shadows the core one. `copy-tree` is core too, so ours is `tree-copy`.

---

## 6. Chris's solutions, collected

1. `run`/`epf`/`&&`/`|`/`>` are Scheme — symbols and syntax rules, not foreign syntax.
2. Put attributes on the **owning cons cell**, not on the atom (dodges interned symbols).
3. A **destructive `list-head!`** (sever in place) plus `append!` sews without copying.
4. A cons cell never leaves its atom — keep every cell with its element.
5. Save the tail **before** the cut; that is what makes the split-and-sew safe.
6. **Auto-close `"`** exactly as `()` is balanced, so an unterminated string is unrepresentable.
7. A **display attribute on the parent cons** for anything whose printed form is not its text.
8. **History as an immutable string** — kills the aliasing problem at the root.
9. Writer emits standard Scheme sugar and newlines; reader is plain `read` + positions. No new
   format.
10. Quoted data is constant; `` `(,"") `` (or `(list …)`) for a mutable one-off.
11. Cycles are not a practical risk with a small primitive set.
12. The cursor may stay external — that is orthogonal to the tree's representation.

## 7. Decisions

| # | decision |
|---|---|
| 1 | **Leaves become datums**, with the as-typed text as an attribute wherever the printed form differs (numbers; partial states) |
| 2 | **Strings auto-close**; the renderer's cursor arithmetic becomes escape-aware |
| 3 | **`break` becomes an attribute** on the holding cell |
| 4 | **The cursor stays external** — the locus does not move into the tree |
| 5 | **History holds strings**, in memory and on disk, both editors reading the one form |
| 6 | Writer emits **standard Scheme with sugar**; reader is `read` + positions. No new file format |

---

## 8. Pros of moving forward

**The two drivers, concretely.**
- History is faithful: what you typed is what you recall, in any session, with no projection to
  lose the sugar.
- One representation: typed, recalled and text-mode lines build the same tree, so a rule cannot
  behave differently by provenance. The `,x`-as-one-word vs two-elements duality disappears.

**Things that follow from it.**
- `eval` takes the tree directly — no projection pass at commit, no `line-datum` unwrapping
  beyond what already exists.
- Rules can inspect real Scheme values: a keystroke rule can ask `boolean?` on the node it is on,
  instead of string-matching `"#t"`.
- The tree is *inspectable as Scheme*: any Scheme tool, the REPL, a debugger, `write`/`read` —
  all work on it directly. Today it is a private format only this code understands.
- The history file becomes readable **and** faithful — `(display '(,f))` on disk as written.
- Deleting the ad-hoc projection means deleting a whole class of bug: every "render and datum
  disagree" case (`(car '(1 2))` vs `(car (quote (1 2)))`) goes away by construction.
- The ground is already prepared: **step 1 is done**, so the ops no longer copy and identity is
  stable — which is what makes attributes survivable in the first place.
- Stable cell identity is independently useful: marks, annotations, incremental re-rendering,
  and any future feature that wants to remember something about a piece of the line.
- It removes the `''x`-typed-as-one-word is still the symbol `'x` asymmetry noted in
  `AGENT-TODO.md` (a prefix word is no longer a special case).

## 9. Cons, costs and risks

**Breadth of the rewrite.** Step 2 is not local: every ATOM edit stops being string surgery and
becomes edit-the-text-then-re-derive-the-datum, which needs a uniform `leaf-text` accessor and
touches `insert-char`, `insert-char*`, `insert-space`, `delete-left`, `delete-right`,
`insert-break`; `tree->sexp` becomes "strip decorations"; `sexp->tree` its inverse; the renderer
becomes a datum printer; the history format changes. The `|` and `&` rows of the key table, the
glob rule and the shell ops all read the tree directly and must keep working throughout.

**The sugar moves into the renderer.** Unless every sugared form carries a display attribute, the
renderer cannot reproduce `',f` — so the plan *trades* a history-only annoyance for a pervasive
attribute burden, and creates **two printers** (render and history-write) that must agree. Forget
the attribute on one path and the loss becomes worse than today's, not better.

**Numbers need an attribute to be faithful** (`05` → `5`), or you accept normalization on screen.

**Strings force escape-aware cursor arithmetic.** A datum string renders escaped, so one `"`
character is two columns; the locus offset indexes the datum while the screen shows the escapes.
`render.scm`/`term.scm` currently just count characters — that is the one place in the codebase
where that is true, and it stops being true.

**A permanent mutability invariant.** After step 1, *an op mutates its input*, so any code that
retains a tree must copy it. That is a new class of bug and we have already hit it once: the
`slurp-node`/`barf-node` "old length read after the alias moved" bug, where the cursor landed one
slot short. Every future feature that holds a tree — undo, a second cursor, a diff, a snapshot —
inherits the rule.

**The constant-dedup trap** (§5.13) is a standing hazard for tests and for any code that hands a
literal to an op.

**Loss of "trees are values".** No cheap undo snapshots, no comparing a before/after tree, no
freely sharing subtrees between two lines. Today all of that is free.

**Migration.** Old history files hold plain datums; new ones hold decorated trees. A version
marker is needed, and hand-edited junk must keep stopping the load safely.

**Effort versus payoff.** It is a large change to the editor's core for benefits that are partly
aesthetic (sugar in history, rules asking `boolean?`). It competes for attention with whatever
the shell needs next — completion, job-control polish, the `;`-toplevel.

**A subtler risk:** the thing being fixed is *provenance-dependent behaviour* (a typed line and a
loaded line differ). Any path that is missed — one op that rebuilds a tree the old way, one
attribute not set — reintroduces exactly that divergence, and it will be invisible until a line
is recalled. The invariant has to hold *everywhere*, and it is not checkable by the type system.

---

## 10. The cheap alternative, side by side

**Serialise the tree to history, change nothing else.** The tree already *is* readable data —
nested lists of strings plus the break marker — and `read` returns it verbatim. Today only the
projection is written; write the tree instead.

| | keep the tree, serialise it | make the tree a sexp |
|---|---|---|
| history faithful next session | **yes** — `("display" "'" (",f"))` round-trips exactly | yes |
| one representation across editors/modes | partly — recalled and typed trees are still not identical | **yes** |
| rules can ask `boolean?` | no — leaves stay strings | **yes** |
| eval takes the tree directly | no — projection stays | **yes** |
| history file readable *and* pretty | no — it holds `("display" "'" (",f"))` | **yes** — `(display '(,f))` |
| code changed | a writer, `break?` (must become `tag`-based, since a read-back break is not `eq?`), a version marker | the editor's core, the ops, the renderer, two printers, the format |
| trees stay values | **yes** | no |
| new bug classes | none | mutability invariant, dedup trap, escape-aware columns |

The cheap version captures the *reported* annoyance (history fidelity) at a fraction of the cost
and risk, and gives up the representation consistency, the `boolean?` rules and the pretty file.
**This is the decision to make.**

---

## 11. The step plan

**Step 1 — destructive primitives and the copying sites. DONE (2026-10-03).**
`list-replace`, `splice`, `remove-at` destructive, same names and arguments; `list-head!` added
(verified a drop-in for `list-head`, 25 calls, errors included); `tree-copy` added and
`history-previous` copies on the way out; `scsh.scm`'s shadowing copies removed. Then every
tree-rebuilding site converted: `insert-break`, `insert-char*`, `insert-form`, `slurp-node`,
`barf-node`, `tidy`/`drop-trailing-empties`/`drop-empty-tails`, `absorb-redirs`, `epf-stage`, the
four `pipe-at` sites, `redirect-at`'s mid-stage epf, `background`.

Measured — tag every cons, run one op, count the originals still reachable:

```
|  (run (ls))                6 -> 6   original kept 3/3    new 3
|  (run (| (ls) (wc)))        8 -> 8   original kept 7/7    new 1
>  (run (| (ls) (wc)))       10 -> 10  original kept 7/7    new 3
|  (|| (epf (ls) (> foo)) …) 18 -> 18  original kept 17/17  new 1
&  (run (ls))                3 -> 3   original kept 2/2    new 1
type x at end of (ls)        3 -> 3   original kept 3/3    new 0
```

All 8 suites and the scheme-shell suite pass; a live pty session (typing, TAB, backspace, pipes,
redirects, `||`, history recall/edit/execute) behaves correctly. This step is a prerequisite for
the rest: without it, attributes on the spine cannot survive an edit.

**Step 2 — leaves become datums.** The substantive one (§9 lists what it touches).

**Step 3 — breaks and the sugar become attributes.** Retire `(break . break)`; the writer emits
the newline from the attribute.

## 12. Still open

1. **Worth it, or the cheap alternative?** (§10) — the decision.
2. **The number attribute** — keep the as-typed text, or accept `05` → `5`?
3. **The renderer and the history writer** must be designed as a pair before step 2 lands (§5.9).
4. **Migration** — the version marker, and what the loader does with pre-change files.
5. **`leaf-text`** — the load-bearing piece; get it wrong and leaf types flip wrongly under
   backspace.
6. **Whether any of step 1's mutability should be rolled back** if the whole plan is dropped —
   it is a real invariant with real costs and, without steps 2–3, buys nothing on its own.

## 13. Evidence appendix

Every measured claim above is a small scratch probe:

- properties do not survive `read`;
- properties on `()`, `42`, `#t`, `#\a` are value-global; on pairs and strings per-object;
- `list-head` copies / `list-tail` shares — tagged conses return `(#f #f 1 2)` after a splice;
- a destructive head + `append!` with the tail hoisted keeps `(0 #f 2)`; without the hoist it
  errors;
- Guile dedupes equal quoted sub-constants; `` `(,"") `` gives a fresh cons per evaluation;
  `(eq? '() '())` is `#t` (the `#f` is for two `(quote ())` *pairs*);
- the atom table — which sequences read as symbols/numbers/booleans/strings, and the two read
  errors;
- the destructive primitives agree with the copying ones on every index of lists up to length 4,
  valid and invalid (75 calls).
