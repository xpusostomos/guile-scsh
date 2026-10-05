

Note the resume path is a plain SIGCONT: our park-on-pipe applies only before exec, so a job stopped later (SIGTTIN from reading a background terminal, or ^Z) is resumed, not re-parked. That's why fg/bg are small.

The one question that's genuinely yours to make is how the user invokes them, and there are three plausible shapes: a bare word line recognised by the shell before it's treated as a command (jobs, fg, fg  bash-like, but it shadows any program of that name; a ,jobs meta-command in the style of Guile's own REPL ( , no collision, but a second syntax to learn; or key bindings. Plus two smaller ones: whether reporting happens before every prompt (bash does) and what to do with a stopped job nobody ever resumes (keep reporting it, or offer to kill it).

Say which shapes you want and I'll write that up as a proposal for approval before any code.help) 2)   SIGCONT only, terminal stays with the 
shell                         bg                      
  set-tty-process- (signal- take the terminal 
back                                            process- group                          pgid  
wait  SIGCONT) group fg                      
 reporting before  the same poll, printing [1]+ Stopped / [1] Done, dropping   
ones                                                                prompt                  the 
Done  each   
 describing a  pass the committed line (or its tree) into  job:
command                                                         job-                         start, 
filling       job        
 state  (wait (job:proc j) (logior wait/poll  without  WNOHANG + WUNTRACED, both already 
exported                          blocking        wait/
stopped-      children)) transitions       
# Job control in scsh — proposal for approval

Status: **proposal, awaiting sign-off.** Nothing under `scsh/` changes until each step below is
reviewed and approved.

## 0. How we'll work

Nothing under `scsh/` changes without sign-off. The plan is split into **numbered steps, each
independently reviewable**: the diff, the rationale and the tests, then stop. No step is bundled with
another; no "while I was in there" edits.

## 1. Where it belongs in scsh's design

scsh is layered, and job control has to respect the layers:

| layer | file | owns |
|---|---|---|
| syscalls — thin, errno-checked FFI | `scsh/syscalls.scm` | `setpgid`, `getpgrp`, `setsid`, signals |
| process objects | `scsh/procobj.scm` | `proc`, populations, autoreaping, `wait/*` |
| process forms (the shell language) | `scsh/syntax.scm`, `scsh/scsh.scm` | `run`, `&`, `\|`, `fork`, `fork/pipe` |
| **the shell** | *our* `editor/` | policy: foreground/background, jobs, `fg`/`bg` |

**Mechanism in scsh, policy in the shell.** Process groups, the sync handshake and the terminal
syscalls are mechanism; "which job is in the foreground", the jobs table, `fg`/`bg` are shell policy
and stay in our layer.

This is scsh's own unfinished design, not a new feature bolted on:

- `TODO:4  Job control.` — it is on scsh's own list.
- `scsh/syntax.scm:26`: `(& → (fork (lambda () (exec-epf …))))` — the seam is one expansion.
- `scsh/scsh.scm:78`: `really-fork/pipe forker …` — **scsh already parameterises the forker**, and
  `fork` vs `%fork` differ by a policy bit (`clear-interactive?`). A job-aware forker is that shape.
- `scsh/procobj.scm:158`: `(define wait/stopped-children WUNTRACED)`; `:218` `cache-wait-status`
  consults `status:stop-sig` — **stop reporting was designed in**: a stopped child is already
  distinguishable from a dead one.
- `scsh/syscalls.scm:239–252`: `process-group`, `set-process-group`, `become-session-leader` exist.
- `procobj`'s note that early autoreaping "loses process-group information" — process-group-aware use
  was anticipated.
- `scsh.scm:813`: `; SIGTSTP blows s48 away. ???` with `(suspend)` built on SIGSTOP — the stop/continue
  story is exactly where the design stopped.
- `really-fork` runs under `(with-enabled-interrupts 0)` and deliberately does the child's work
  *outside* it — child-side code for job control must sit in that same spot.

**Missing:** terminal ownership (`tcsetpgrp`), a race-free pgroup discipline, a proc-level view of its
job group, and the shell policy.

## 2. The three races that put this inside scsh (not outside)

1. `setpgid` on a child **fails `EACCES` once the child has exec'd** (POSIX). Parent-only calls are a
   race; the fix is the double call, whose child half runs in `really-fork`'s child branch.
2. A foreground child that touches the tty **before** our `tcsetpgrp` lands is stopped by `SIGTTIN` at
   startup. Shells close this with a **sync pipe**: the child parks until the parent says go.
3. Symmetrically, a background child must not read the tty *before* it is moved out of our group.

## 3. Proposed API, step by step

**Step 1 — `(scsh syscalls)`:** `(isatty fd)`, `(tcgetpgrp fd)`, `(tcsetpgrp fd pgrp)`,
errno-checked via `define-errno-syscall`, POSIX names, existing idiom. Touches nothing else.

**Step 2 — `(scsh procobj)`, the proc's group:** `(proc:group proc)` (mirrors `proc:pid`; the accessor
half of the existing `set-process-group`). Confirm and document the status surface job control relies
on: `status:stopped?`, `status:stop-sig`, `status:exit-val`, `status:term-sig`, `status:continued?`.

**Step 3 — the job-aware fork:**

    (fork/job thunk [pgroup]) => proc

child: `setpgid(0,0)` (or join `pgroup`), then **park** on the sync pipe, then run `thunk`.
parent: `setpgid(pid, pid)` best-effort (EACCES tolerated), record the group on the proc, return
**without releasing**.

    (job-release! proc)   ; parent writes the go byte

Pipe EOF (parent died) also releases, so no child is ever parked forever. Stopping/continuing reuses
what exists — `(signal-process-group pgid signal/tstp)` — and `(suspend)`'s story needs revisiting,
separately, on instruction.

**Step 4 — pipelines in one group:** `(fork/job thunk pgroup)` is what lets every stage of
`(run (| a b))` join one job group. This touches the `fork/pipe`/`fork/pipe+` family
(`scsh.scm:71–110`), so it is its own step and its own review.

**Step 5 — the process forms:** `&`/`run` route through the job forker when the session has job
control on — a runtime dispatcher (`fork/job` degrading to plain `fork` when off), so the syntax stays
simple and no compile-time switch is needed. Default **off**, so scripts and non-interactive use
behave exactly as now.

**Step 6 — the shell layer (ours, no scsh changes):** jobs table; `tcsetpgrp` handoff around
foreground runs with `SIGTTOU` ignored; termios save/restore around jobs (we already have that FFI);
`jobs`/`fg`/`bg`/`kill`; `^Z` handling in raw mode; reporting by polling
`wait/poll`/`wait/stopped-children` before each prompt — no second reaper, since scsh already owns
SIGCHLD. The `/dev/null` rule for background stdin then applies only when job control is off (it is the
POSIX rule for exactly that case).

**Step 7 — verification:** unit tests per piece (pgroup assignment, handshake incl. EOF-release, status
decoding, jobs-table transitions), then interactive verification on a real terminal, since the
development sandbox cannot drive a tty.

## 4. Decisions needed before any of it is written

1. **Names.** `fork/job`, `job-release!`, `proc:group`, `job-control?` — or something more in scsh's
   voice? (Names in a library are forever.)
2. **Does `&`'s expansion change** (job-aware by default, degrading when off), or should the shell call
   the job forker explicitly and leave the syntax alone?
3. **Pipeline groups:** `(fork/job thunk pgroup)` or a dynamic `with-job-group` scope that nested
   forkers inherit?
4. **Termios:** bind it in scsh, or keep it in the shell layer (inclination: keep it out for now).
5. **Jobs table:** the shell (inclination) or `procobj`?
6. **Default:** off everywhere (inclination) or auto-on for interactive sessions?

## 5. What will not be done

Touch `scsh/` before sign-off; combine steps; change `(suspend)`/SIGTSTP or the autoreap policy
without raising it first.

---

## Annex A — scsh 0.6's own job control (reference)

`scsh-conservatory/scsh-0.6` commit `81358ac` contains **`scsh/jcontrol.scm`** (64 lines, Copyright
1993 Olin Shivers) and **`scsh/jcontrol1.c`** (97 lines). Neither is in this port.

### A.1 The Scheme file

    (define (fork-job . maybe-thunk)
      (let ((child (fork)))
        (cond (child
               ;; PARENT -- wait for child to stop and then set its proc group.
               (let ((status (wait child wait/stopped-children)))
                 (if (not (status:stop-sig status))     ; Make sure it didn't die.
                     (error "premature job death" status)))
               (set-process-group child child))
              ;; CHILD -- suspend until we are put in our own proc group.
              ;; The test&suspend isn't atomic; the parent needs to do things
              ;; in the right order to make this win.
              (else (let lp ()
                      (signal-process 0 signal/stop)
                      (if (not (= (pid) (process-group))) (lp)))
                    (if (pair? maybe-thunk)
                        (call-terminally (car maybe-thunk)))))
        child))

    (define (resume-job proc-group)
      (set-terminal-proc-group 0 proc-group)        ; Give tty to job.
      (signal-process-group proc-group signal/cont)
      (let ((status (wait proc-group wait/stopped-children)))
        (set-terminal-proc-group 0 (process-group)) ; Take tty back.
        status))

    (define (background-job proc-group)
      (signal-process-group proc-group signal/cont)
      proc-group)

    (define-simple-syntax (run . epf) (resume-job   (fork-job (lambda () (exec-epf . epf)))))
    (define-simple-syntax (&   . epf) (background-job (fork-job (lambda () (exec-epf . epf)))))

with his own closing notes:

    ;;; What if stdin (fd 0) isn't a tty? Need a (control-tty) or (control-tty-fdes) procedure.
    ;;; Need repl loop that manages some kind of a job table, and grabs the terminal back
    ;;; after running a job.  Should I define a WAIT-JOB procedure?  Need a (CONTROL-TTY).

**The mechanism.** Not a sync pipe: the child **stops itself** (`signal/stop` = SIGSTOP) before doing
any work; the parent learns of the stop through the *existing* `wait … wait/stopped-children`
(WUNTRACED) machinery, checks `status:stop-sig`, and calls `set-process-group` on the now-stopped
child — so there is no `EACCES`-after-exec race and no bespoke protocol. The job is then resumed:
foreground via `resume-job` (tcsetpgrp → SIGCONT → wait → tcsetpgrp back), background via
`background-job` (SIGCONT only) — which leaves the background job in its own process group while the
shell keeps the terminal, so a read gets SIGTTIN and stops it. That is bash's behaviour, for free.

**What it settles.** Names (`fork-job`, `resume-job`, `background-job`, `set-terminal-proc-group`;
the job's group is just its pid); `run` and `&` are *redefined* by the job-control module rather than
dispatched at runtime; pipelines need **no** changes — `(run (| a b))` groups at the outer fork, and
`exec-epf`'s inner `fork/pipe` stages inherit that group; the jobs table and repl integration are
explicitly the *shell's* business (his TODO).

**What he left undone.** `(control-tty)`/`(control-tty-fdes)`, the jobs table, `wait-job`, and the
repl loop that takes the terminal back — i.e. our Step 6. Also note his `resume-job` does **not**
save/restore tty *modes*; our shell holds the terminal in raw mode, so mode handoff is ours to add.

### A.2 The C file, and why the port lacks all of this

`jcontrol1.c` is not process-group code: it is Scheme 48 **runtime** support — `set_procmask` /
`get_procmask` (sigprocmask), a pending-signal mask, and `s48_value set_int_handler/get_int_handler`.
It exists because scsh-on-S48 implemented its interrupt layer in C. This port implements
`(scsh sighandlers)` against Guile's own signal API instead, so that file is neither portable nor
needed here.

What is missing in our tree, precisely:

| | |
|---|---|
| `scsh/jcontrol.scm` | absent (the module was never carried over; `TODO:4 Job control.` is still open) |
| `set-terminal-proc-group` (tcsetpgrp) | absent from `scsh/syscalls.scm` |
| `signal/cont` | absent; only the raw `SIGCONT` constant exists (`maybe-define-signal`) |
| `signal/stop` | **referenced but undefined** — `scsh/scsh.scm:814` `(define (suspend) … signal/stop)` cannot run |
| present already | `fork`, `call-terminally`, `wait` + `wait/stopped-children`, `status:stop-sig`, `signal-process`, `signal-process-group`, `process-group`, `set-process-group`, `become-session-leader` (all in `(scsh syscalls)`/`(scsh procobj)`) |

### A.3 Why this port does not have it

Because **scsh 0.6 did not ship it either**, and the port ported what 0.6 built.

- 0.6's `Makefile`, in the list of sources compiled into the image, has the line
  `#	jcontrol` **commented out** — sitting next to `#  dbm` and `#  static`, i.e. job control was an
  optional, disabled module, not part of the standard scsh image.
- The same list *does* include `scsh/tty.scm` (431 lines: the `tty-info` record — control chars,
  input/output/control/local flags, speeds — with accessors and setters, plus the terminal
  process-group operations). **Our port has no `tty.scm` at all**, which is the concrete reason
  `set-terminal-proc-group` is missing: its module was never carried over, and with it went
  `terminal-proc-group`, `tty?`, and the whole `tty-info` surface. (0.6 compiles it through a C side,
  `tty1.h`/`tty.c`, by the same scheme→C two-ply as `syscalls`.)
- The port's stated scope is a *library you can demo from*, not a shell session — `USAGE`: "This is a
  pre alpha software… it can demo some of the features in the original scsh quite well". Consistent
  with that, it carried the process machinery a library user needs (`procobj` with
  `wait/stopped-children` and `status:stop-sig`; `syscalls` with `set-process-group`,
  `signal-process-group`, `become-session-leader`) and left out the session machinery: no `tty.scm`,
  no `jcontrol.scm`, no REPL. `TODO` was inherited along with the sources, so item 4 is still open
  here exactly as it was upstream.

**Consequence for the plan.** We are not restoring a shipped feature; we are *finishing* an unfinished
one — Olin's sketch plus the pieces he left as TODOs (`control-tty`, jobs table, repl loop) — and
restoring the terminal layer the port dropped. So Step 1 should be the terminal operations, and it
carries a scope decision: port 0.6's full `tty.scm` (the `tty-info` record and its C side), or add
only what job control needs — `tty?`, `terminal-proc-group`, `set-terminal-proc-group` — in scsh's
naming, leaving the termios record as a separate decision (our editor already has its own termios FFI
for raw mode).

### A.4 Status in the official 0.6.7 release (local tree: `../scsh-0.6.7`)

- **Not built.** No `Makefile`, `config.status` or objects: a pristine unconfigured source tree.
  (`build/initial.image` is the Scheme 48 bootstrap image shipped with the sources, not a build
  product.)
- **Job control is not in it — the code is gone, not disabled.** `scsh/jcontrol.scm` does not exist;
  the only trace is a stale commented `#	jcontrol` in `Makefile.in:846` (the same line we saw
  commented in the 0.6 Makefile). So the sketch lived in the repo, and the release does not carry it.
- **The terminal layer it would need *is* present and *is* built**: `scsh/tty.scm` is in the built
  source list (`Makefile.in:825`, with `scsh/tty1.o` at `:134`) and provides
  `tty?`, **`set-tty-process-group`** (→ `sch_tcsetpgrp`), **`tty-process-group`** (→ `sch_tcgetpgrp`),
  and the termios `tty-info` record, all through the C side `tty1.c` (plus a NeXT fallback in
  `nextbs.c`).
- **Naming correction:** the 1993 sketch called it `set-terminal-proc-group`; the released 0.6.7 calls
  it **`set-tty-process-group`** / **`tty-process-group`**. We should follow the released names.
- Our port has neither: no `tty.scm`, and no `tcsetpgrp`/`tcgetpgrp` bindings — so restoring the
  terminal operations is required regardless of how we frame the job-control work.

### A.5 Why it was abandoned (history, and a reading of it)

From the repository's commit history for `scsh/jcontrol.scm`:

    1999-09-14  09136048  Added files from david fishers home (~dfisher/scsh-0.5.1).
    2000-12-18  6c136b90  removed obsolete files/code for jcontrol and signal sets

The removal commit (author "mainzelm", 2000-12-18) deleted **nine** files:
`scsh/jcontrol.scm`, `scsh/jcontrol1.c`, `scsh/jcontrol2.c`, `scsh/jcontrol2.scm`, and
`scsh/{aix,bsd,linux,solaris}/sigset.h` — i.e. job control *and* the signal-set machinery it stood
on — and modified `scsh/sighandlers1.c`. So it was removed deliberately as obsolete, together with
the runtime plumbing it depended on, and therefore appears in no 0.6.x release. Note also that it
entered the tree only in 1999 as part of a bulk import of another developer's working tree, and that
there were two generations of it (`jcontrol` and `jcontrol2`), both dropped. It was never in a built
image: the Makefile line was commented out (`#	jcontrol`) both before and after.

**A reading of why** (inference, not documented intent):

1. **It was the kernel of the feature, not the feature.** Olin's own TODOs are the whole user-visible
   part — `control-tty`, the jobs table, `wait-job`, the repl loop. It was disabled in the build, so
   nothing ever exercised it.
2. **Its core had a race that the removed machinery used to paper over.** His comment — "The
   test&suspend isn't atomic; the parent needs to do things in the right order to make this win" —
   describes a lost-wakeup hazard: a `SIGCONT` delivered between the child's process-group check and
   its own `SIGSTOP` can leave a job parked with nobody to resume it. Closing that needs an atomic
   handshake (a sync pipe, or signal masking — precisely the `set_procmask`/signal-set code that was
   being deleted).
3. **It changed the language to get a session feature.** `jcontrol.scm` *redefines* `run` and `&`, so
   loading it would change the meaning of the process forms for programs too — making `run` hand over
   the terminal and respond to `SIGTSTP`. For a language whose larger use is scripting, that is not
   acceptable, and it is exactly what the commented-out Makefile line reflects: it could not be
   enabled without changing `run`'s semantics for scripts.
4. **Demand was interactive-only**, and scsh was predominantly used as a language/scripting embed.

**What this settles for the plan:** job control goes in *our* shell layer (the session), and **`run`/`&`
are not redefined** — which is also what Olin's TODO says ("Need repl loop that manages some kind of a
job table"). And we adopt his lifecycle mechanism, but with the handshake made atomic, since the
sketch's own weakness is the one thing we must not inherit.

### A.6 Provenance of each piece (what we adopt, complete, or specify)

| piece | provenance |
|---|---|
| `fork-job` / `resume-job` / `background-job` — the lifecycle: child owns its group before doing anything; parent learns via the stop machinery; terminal handed over while the job is parked, then resumed | **adopted** from the 1993 sketch (names and semantics) |
| background = resume *without* the terminal, so `SIGTTIN` stops a reader (bash's behaviour) | **adopted** |
| the atomic handshake (a pipe) instead of the sketch's stop-and-re-check loop | **completed** — the defect Olin's own comment names ("the test&suspend isn't atomic") |
| `tty?`, `tty-process-group`, `set-tty-process-group` (0.6.7's released names) | **restored** — absent from this port; implemented as FFI in our terminal layer (a scsh-side addition stays optional) |
| `wait … wait/stopped-children`, `status:stop-sig`, `set-process-group`, `signal-process-group`, `vpipe`, `proc:pid`, `autoreap-policy` | **already in scsh** — used as they are, not changed |
| the jobs table, `fg`/`bg`/`jobs`, reports, `^Z`, tty-mode handoff | **ours to specify** — the sketch left these as questions ("Need repl loop that manages some kind of a job table", "Should I define a WAIT-JOB procedure?") |
| `run`/`&` keep their language semantics | **ours** — the sketch redefined them, which is why it could not ship (§A.5) |

## Annex B — revisions to §3 this forces (proposed, not yet approved)

1. **Drop the sync pipe.** Olin's stop-and-setpgid handshake does the same job with machinery scsh
   already has, and closes the foreground window more cleanly (the parent sets the terminal *before*
   resuming). Steps 3 and 4 become "restore `jcontrol.scm`".
2. **Adopt his names and shapes**: `fork-job`, `resume-job`, `background-job`,
   `set-terminal-proc-group`; the job group is a plain pid; `run`/`&` redefined by the module.
3. **Delete Step 4 entirely** (pipelines need no change).
4. **Add what his file needs to exist**: `set-terminal-proc-group` (and a `(terminal-proc-group fdes)`
   getter) in `(scsh syscalls)`; `signal/cont` (and repair `signal/stop`) alongside the existing
   signal names.
5. **Keep §3 Step 6 unchanged** — it is exactly the gap he named in his own notes, plus terminal-mode
   handoff, which he did not address.
6. **Open question for the user**: whether to port `jcontrol.scm` verbatim-shaped (a module that
   redefines `run`/`&` when loaded, as in 0.6) or to make job control a session switch; and whether
   `(control-tty)`/`(control-tty-fdes)` should be ours (shell) or his proposed scsh procedure.


-------------------------

Do we have job control now?

What exists (editor/job.scm:119–123): *jobs*, with (jobs), (jobs-add! …), (jobs-drop! …), holding records that carry job:proc, job:pid, job:pgid, job:command.
What uses it (editor/run.scm:44,47): a foreground job that stops is added and Stopped is printed; a
background job is added, then released. That's all.
What's missing — nothing reads the list:
- no numbers ([1]), no state (Running / Stopped / Done + status), so entries can't be described or  acted on;
- job:command is never populated — run.scm passes only the thunk — so an entry couldn't even be printed;
- no polling: nothing notices a background job finishing or stopping, so entries go stale and are never removed (jobs-drop! is called only by the test);
- no display (jobs), no fg/bg, and no reaping policy of our own for tracked jobs.

Why it's a stub — deliberately. Olin left exactly this to the shell: "Need repl loop that manages some kind of a job table… Should I define a WAIT-JOB procedure?" And the three deciding questions are the ones I flagged earlier and haven't answered for you.

What finishing it needs — and all the pieces are already in place:

┌─────────────────────────┬─────────────────────────────────────────────────────────────────────┐
│          piece          │                             built from                              │
├─────────────────────────┼─────────────────────────────────────────────────────────────────────┤
│ state transitions       │ (wait (job:proc j) (logior wait/poll wait/stopped-children)) —      │
│ without blocking        │ WNOHANG + WUNTRACED, both already exported                          │
├─────────────────────────┼─────────────────────────────────────────────────────────────────────┤
│ describing a job        │ pass the committed line (or its tree) into job-start, filling       │
│                         │ job:command                                                         │
├─────────────────────────┼─────────────────────────────────────────────────────────────────────┤
│ reporting before each   │ the same poll, printing [1]+ Stopped / [1] Done, dropping the Done  │
│ prompt                  │ ones                                                                │
├─────────────────────────┼─────────────────────────────────────────────────────────────────────┤
│ fg                      │ set-tty-process-group → (signal-process-group pgid SIGCONT) → wait  │
│                         │ → take the terminal back                                            │
├─────────────────────────┼─────────────────────────────────────────────────────────────────────┤
│ bg                      │ SIGCONT only, terminal stays with the shell                         │
└─────────────────────────┴─────────────────────────────────────────────────────────────────────┘

Note the resume path is a plain SIGCONT: our park-on-pipe applies only before exec, so a job stopped later (SIGTTIN from reading a background terminal, or ^Z) is resumed, not re-parked. That's why fg/bg are small.

The one question that's genuinely yours to make is how the user invokes them, and there are three plausible shapes: a bare word line recognised by the shell before it's treated as a command (jobs, fg, fg 2) — bash-like, but it shadows any program of that name; a ,jobs meta-command in the style of Guile's own REPL ( ,help) — no collision, but a second syntax to learn; or key bindings. Plus two smaller ones: whether reporting happens before every prompt (bash does) and what to do with a stopped job nobody ever resumes (keep reporting it, or offer to kill it).

Say which shapes you want and I'll write that up as a proposal for approval before any code.
