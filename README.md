# forthright

*A Forth pun, and an old word for honest/transparent.* Both meanings are the point.

## The thesis

Forth's only real defect is a **human** one: invisible, non-local stack state with no
names and no error-correcting redundancy, which makes code hard to write, review, and
trust. Everything else about Forth is a virtue — tiny footprint, total control,
trivially implementable, **auditable end to end**.

In the old regime, fixing the human defect meant baking tooling (type checkers, IDEs,
optimizing compilers) *into the language*. That works — see Factor — but it re-adds all
the weight Forth deleted, so you lose the one thing Forth was uniquely good at and end up
a heavyweight language competing on ecosystem, which a niche language can't win.

The AI era unlocks a different move:

> **Keep the language minimal. Push the tooling out of the artifact and into the
> generation loop.**

- An AI generates plain, minimal Forth.
- An external verifier checks it (stack effects, types, intent).
- The AI repairs and re-checks in a loop.
- The artifact you **ship is still tiny, auditable Forth** — no checker, no types, no
  runtime machinery baked in.

The error-correcting redundancy the language lacks is supplied by the *pipeline*, not the
*artifact*. You get minimal-Forth **and** reliability at once — the configuration that was
impossible when a human had to sit in the writing seat.

## Architecture (the blacksmith metaphor)

- **anvil** — the verifier; code gets hammered against it until it's stack-correct. The
  core of the whole bet: the redundancy Forth doesn't have, living *outside* the shipped
  code. **Built** (`anvil.fr`, self-hosted): stack-effect checking + branch analysis;
  richer type/intent checks later.
- **forge** — the generate → check → repair loop. **Built** (`forge.fr`, self-hosted): a
  breadth-first search stands in for the AI generator, and nothing is accepted unless anvil
  approves the shape and an example run confirms intent.
- **ember** — the explorer: *watch* the engine run, cell by cell. The self-hosted `ember.fr`
  drives the real engine under ptrace; the Python `ember` is the older, curses-rich one.
- *(corpus)* — still open: generate-and-verify at scale to mint a synthetic training
  corpus, the one credible attack on Forth's "no training data" problem.

(Everything below `fr.s` — prelude, anvil, forge, term, ember.fr, ptrace, live — is
written *in fr*, so the whole trust base is auditable. Section "Status" lists it all.)

## Open questions / known hard parts

- **anvil verifies consistency, not intent.** A balanced stack ≠ a correct program. The
  human still has to confirm the code does what was meant — and Forth is hard to *read*.
  Bridging consistency-checking to intent-checking is the real research risk.
- **Training-data gravity.** Forth has almost no corpus; the corpus tool is the bet
  against this, and it's unproven.
- Which Forth to target (gforth? a custom minimal core?) is undecided.

## The Forth, written for this machine

Rather than target someone else's Forth, forthright writes its own — for the box
it runs on (x86-64, Linux). `fr.s` is a **freestanding** indirect-threaded-code
(ITC) kernel: no libc, no runtime, just raw syscalls and threaded code. The whole
system between source and kernel is one auditable file — which is the thesis made
literal.

Build and run (it's a REPL — reads Forth from stdin until EOF):

    ./build.sh
    echo '3 4 + 5 * .' | ./fr     # -> 35
    ./fr                          # or type at it interactively; Ctrl-D to quit

The **kernel** (raw `./fr`) knows only the irreducible primitives: `dup drop swap`,
memory `@ ! c@ c! here allot` + bulk `cmove fill`, return stack `>r r> r@`, arithmetic
`+ - * /`, bitwise `and or xor lshift rshift`, `= <`, I/O `. emit type word find number
s= [char]`, string literals **`s" … "` / `." … "`**, `variable constant latest sys
execute sp@ sp0`, the raw syscall `syscall6`, **`include`** (load another source file),
`bye`, and the compiling words `: ; if else then begin until while repeat \ (`.
Load the rest from **`lib/`** — `include lib/prelude.fr` (`over rot nip 2dup negate 1+
cells > 0= , char cr space square u.`), then `lib/math.fr`, `lib/string.fr`, etc. (see
`lib/README.md`). Numbers (incl. negatives) push themselves; unknown tokens echo with `?`.

    echo ': cube dup dup * * ;  4 cube .' | ./fr                                # -> 64
    ( cat lib/prelude.fr; echo ': abs dup 0 < if negate then ;  -5 abs .' ) | ./fr   # -> 5
    ( cat lib/prelude.fr; echo ': cd begin dup . 1 - dup 0 = until drop ;  5 cd' ) | ./fr

Engine conventions: `%rsi`=IP, `%rsp`=data stack, `%rbp`=return stack, `%rax`=W.
`NEXT` is the inner interpreter; `docol`/`EXIT` drive the return stack. The outer
interpreter (`_word`/`_find`/`_number` + `INTERPRET`) is driven by the threaded
`QUIT` loop, which branches back on itself forever.

## Exploring it: ember (TUI)

`ember` is a terminal UI for *watching* the engine work — a threaded-code stepper
styled after the `design` (NEXT-runner) Nord palette and execution colour coding
(ip=cyan, stack=orange, hop=purple, exec=yellow). You single-step the inner
interpreter and *see* the IP walk a thread and the stacks change.

At startup ember loads `prelude.fr` into the traced fr (at native speed, via a breakpoint
at the `read` syscall), so prelude words work at the prompt — e.g. type `see square` and
ember runs the self-hosted disassembler inside the real fr.

By default it **drives the real `./fr` binary**: it launches it under `ptrace`,
single-steps machine instructions, stops at every `jmp *(%rax)` (the ITC dispatch
NEXT/EXECUTE perform), and reads the live registers and memory — `%rsi` is the IP,
`%rsp`/`%rbp` the real stacks — decoding the actual threaded code and dictionary
straight out of `/proc/<pid>/mem`. No gdb required; just `ctypes` + a tiny ELF
symbol parser. You literally watch the real QUIT loop run `(interp)`/`branch` and
hop into colon words. A `--python` flag swaps in a pure-Python model of the same
machine (handy on non-Linux or when `fr` isn't built).

    ./ember                      # TUI driving real ./fr (needs ~76x20 terminal)
    ./ember --python             # TUI on the Python model instead
    ./ember --selftest           # headless Python-model check
    ./ember --native-selftest    # headless ptrace check against ./fr

Type Forth at the `ok>` prompt (`5 square .`, `: cube dup dup * * ;`). When a line
loads a thread you drop into step mode:

    s / space  single-step one cell      a  autoplay (toggle)      +/-  speed
    r          run to completion         n  done, back to editing  q    quit

Watch the `THREAD` panel: the `▸` marks the IP, executed cells dim, a hop into a
colon word pushes a frame onto `RETURN` (purple) and the panel switches to that
word's body; `exit` pops back. The Python engine is a deliberate superset of fr
(adds `over rot / mod = < > negate .s`) so there's more to poke at.

### …and ember.fr — the self-hosted version

`ember.fr` is the same idea, **written in fr** — and it drives the *real* engine, not a
model: it forks fr, runs the word in the child, and single-steps the child under ptrace
(`ptrace.fr`) to each `jmp *(%rax)` dispatch, reading the child's actual registers and
data stack with `PEEKDATA`. The view is a **full-screen, responsive** Nord dashboard
(`term.fr` has true-colour `fg24`/`nord-*` words + `box` drawing; the layout re-reads
`term-size` each frame) that now matches the Python ember's multi-panel layout.
It runs with **no Python at all**: the kernel loads the library from its file arguments,
the terminal is the tty `raw-on` needs, and you type a command at the prompt:

    ./fr ember.fr     # then type:  5 ' square ember
    ./ember-fr                                      # ...or the shell launcher (boots to a prompt)
    ./ember-fr ": cube dup square * ;  3 ' cube ember"   # it pre-runs whatever you pass

```
 ember : cube  #4                                                    step
 ┌─code───────────────────────────┐ ┌─data─────────────┐
 │> 0  dup                        │ │ 5  top           │   (stepped INTO square; live
 │  1  *                          │ ├─call─────────────┤    cell ▸ highlit, stack peeked
 │  2  ;                          │ │ cube > square    │    from the child)
 ├─out────────────────────────────┤ ├─dict─────────────┤
 │ step 4                         │ │ cube square dup… │
 └────────────────────────────────┘ └──────────────────┘
 ┌────────────────────────────────────────────────────┐
 │ ok>                                                  │
 └──────────────────────────────────────────────────────┘
   s=step  a=auto  r=run  e=edit  q=quit
```

It **steps into colon words** — it infers the call path from the live dispatch stream
(`docol`-entries/`EXIT`s), so `code` switches to the callee and `call` shows `cube >
square`. It **follows control flow** (it's the real engine — `if/else` and loops just
work). **`a` autoplays** on a timer (`+`/`-` change the speed — the frame clock is a
`key` read timeout via VMIN/VTIME), and `r` runs to the end. The **`e` edit line is a REPL**:
each line you enter (`5 square`, `4 4 +`, or just `3`) is compiled into a thread — with the
resting stack re-pushed in front — and stepped. When the thread reaches its top-level `EXIT`
the explorer **snapshots the stack and rests** (it does *not* exit), so the result carries to
the next line: `5 5 5 +` rests at `10 5`, then `3 *` continues to `30 5`. A word that
**prints** has its stdout captured into the `out` panel — `launch` points the child's fd 1/2
at a pipe, so the output shows up instead of corrupting the TUI. The non-interactive
`ember-trace` prints the live stack per dispatch (no tty needed); the lighter, no-ptrace model
is the prelude's `trace`. So the Python `ember` is no longer a capability fr lacks — fr's
explorer now matches its panels, keys, and behavior, and the Python one stays only as a
reference UI.

## Verifying it: anvil.fr (self-hosted)

`anvil.fr` is the payoff — a stack-effect verifier **written in fr**, so the whole
trust chain (language + checker) stays small enough to audit. Load it, then either
infer a phrase's effect or define-and-check a word against its declared signature
(effects print as `( x.. -- y.. )`, one glyph per cell):

    echo 'check{ dup dup * * }'       | ./fr anvil.fr   # ( x -- y )
    echo 'def sq ( n -- n ) dup * ;'  | ./fr anvil.fr   # sq ( x -- y )  ok
    echo 'def bad ( a b -- c ) + + ;' | ./fr anvil.fr   # BAD ( xx -- y )

(anvil.fr `include`s `lib/prelude.fr`, so loading it gives you the whole vocabulary — see below.)

It keeps a name→`(consumes,produces)` table (`prim` for built-ins, `def` for new
words). `check{ … }` / `def` read tokens, classify each (number / known word /
unknown), and run the abstract stack simulation (`hgt`/`lo`): inputs `= -lo`,
outputs `= inputs+hgt`. `def` registers the inferred effect (so words compose) and
flags any disagreement with the declared `( … -- … )`. `anvil-reference.py` is the
Python spec it follows.

## Forging it: forge.fr (generate → check → repair, self-hosted)

`forge.fr` closes the loop the whole project is about — **in fr itself**. A
breadth-first generator builds candidate threaded bodies; the self-hosted `anvil`
(`check-body`) verifies each one's stack effect; shape-valid candidates are run
(`execute`) on examples to confirm intent; the first passing both is "forged":

    echo forge | ./fr forge.fr        # forge.fr includes prelude + anvil

      1+ ?
      dup + ?          ← right shape ( n -- n ), wrong value
      dup * <=         ← forged: right shape AND 5→25, 3→9

(`?` = anvil approved the shape but the value test failed; `<=` = forged.) The
generator is a search standing in for an AI; the point is the gate — nothing is
accepted unless **Forth-checking-Forth** approves the stack effect first, and
anvil checks *shape* while `execute` checks *intent*. The whole pipeline runs with
nothing but fr: it writes, verifies, and forges its own code. This needed three
new pieces — `execute` (kernel), `'` (prelude), and `check-body` (anvil checking a
*compiled body* by CFA, not stdin). `forge-reference.py` is the Python spec.

## Status

- [x] Inner interpreter (ITC NEXT, docol/EXIT), data + return stacks
- [x] Primitives: LIT DUP DROP SWAP + - * . BRANCH BYE
- [x] Dictionary (linked list, FIND by name) + outer interpreter / REPL:
      `_word` (tokenize stdin), `_find`, `_number`, `INTERPRET`, `QUIT` loop
- [x] Compile mode: `:` `;` (immediate), `state`/`here`/`dict_space` — define
      words at the prompt; the language now extends itself
- [x] Comparison/stack words: `= < > 0= over negate`
- [x] Control flow: `0branch` + immediate `if else then` / `begin until` —
      fr is now Turing-complete
- [x] Memory: `@ ! c@ c! , here allot cells cell+`, `variable`, `constant`
      (shared `_create` header-builder; `dovar`/`doconst` runtimes)
- [x] Parsing / strings / output: `word find number s= char [char] emit type cr`
      — the toolkit to read source, match names, and print a report (~2.8 KB text)
- [x] Kernel extras: `exit and or begin while repeat`, comments `\` `(`, division
      `/`, return stack `>r r> r@`, and `latest` (dictionary introspection)
- [x] **Library primitives** in the kernel — the irreducible pieces a real library needs:
      **`include PATH`** (load another source file then resume — a nested input-source
      stack + load-once registry, so files declare their own deps and apps run as
      `./fr app.fr`); **`s" … "` / `." … "`** string literals (inline, IMMEDIATE; advance
      the IP relative to the bytes since the dict is packed); and bulk/bitwise
      `cmove fill xor lshift rshift`.
- [x] **`lib/`** — a self-hosted standard library, TUI-oriented (see `lib/README.md`):
      `prelude` (core: `over rot nip 2dup negate 1+ cells > 0= , char cr space square u.`,
      `see`, `trace`), `math`, `string`, `fmt` (number formatting), `term` (ANSI+termios),
      `key` (escape-seq → `KEY-*`), `draw` (panels/rules), `tui` (label/status-bar/menu/
      accept), `time`, `io`. Each `include`s its deps; `examples/demo.fr` shows them compose.
      The rule still holds: if a word can be written in fr, it lives in a lib module, not `fr.s`.
- [x] **`see`** (prelude.fr) — a self-hosted thread decoder: it walks fr's own
      dictionary (via `latest`) and the kernel's `sys` table of engine CFAs to
      disassemble any definition. `see square` → `dup * ;`; `see abs` →
      `dup 0 < 0b 16 negate ;`. fr introspecting itself. (Plus `.n`, signed print.)
- [x] **anvil.fr**, self-hosted: a stack-effect verifier written *in fr* (~110
      lines). `check{ … }` infers a phrase's `( in -- out )`; `def name ( decl )
      body ;` infers + registers a word's effect (so words compose) and flags any
      mismatch with the declared signature; **`if/else/then` are analyzed** — both
      arms must leave the same net effect or it's flagged `br!` (an `if…then` with
      no `else` must be height-neutral). The thesis made literal — the redundancy
      Forth lacks, in a trust base small enough to audit. (`anvil-reference.py` = spec.)
- [x] **forge.fr** — the generate → check → repair loop, *self-hosted in fr*: a
      generator builds candidate bodies, the self-hosted `anvil` (`check-body`)
      verifies each stack effect, shape-valid candidates are `execute`d on examples,
      and the first passing both is "forged". Needed `execute` (kernel), `'`
      (prelude), and anvil checking *compiled bodies* by CFA. fr writes, verifies,
      and forges its own code. (`forge-reference.py` is the Python spec.)
- [x] **`trace`** (prelude.fr) — single-step a word on the live stack, printing it
      each step; the fr-native analog of ember's step view. Needed `sp@`/`sp0`
      (kernel) for `depth`/`.s`.
- [x] **`syscall6`** (kernel) + **`key`** (prelude) — one generic Linux syscall (up to
      6 args), the gate to the whole OS; `syscall3` is derived from it in the prelude.
- [x] **term.fr** — terminal control *in fr*: ANSI escapes (`clear at fg bg`) and
      termios cbreak via `ioctl` (`raw-on`/`raw-off`, validated under a pty).
- [x] **Robust input + file loading** (kernel) — `_word` reassembles tokens (and the
      comment words refill) across reads, so input can arrive in any chunk size; and
      `./fr a.fr b.fr` loads source files from `argv` before the stdin REPL.
- [x] **ptrace.fr** — process control + **ptrace** *in fr*: `fork`, `PTRACE_TRACEME`,
      `SINGLESTEP`, `GETREGS`, `PEEKDATA` — all just `syscall6` shuffles. ptrace was never
      special, just a 4-arg syscall `syscall3` couldn't reach. Its `watch` is a **self-hosted
      NativeVM**: fork the running fr (child shares its memory image, so the parent's
      dictionary *is* the child's), run a word in the child, single-step it from the parent,
      and decode `%rax` at each `jmp *(%rax)` dispatch. `5 ' square watch` →
      `… execute square dup * ; bye` — the real engine traced, observed entirely from fr.
- [x] **ember.fr** — the **self-hosted explorer**: a **full-screen, responsive** multi-panel
      dashboard (`code`/`data`/`call`/`dict` + an `out` line, an input box and a key row —
      matching the Python ember's layout) driving the *real* engine via `ptrace.fr`. `5 '
      square ember` (or `./ember-fr`) forks a child, single-steps it, infers the call path
      from the dispatch stream, and reads the data stack with `PEEKDATA` (`5 → 5 5 → 25`). `s`
      steps, **`a` autoplays** (`+`/`-` speed), `r` runs, `e` is a live edit line (re-fork on a
      new target); the `dict` panel hides the explorer's own plumbing, and a printing word's
      stdout is **captured into the `out` panel** (the child's fd 1/2 are piped). No Python —
      the terminal is the tty. fr now writes, verifies, forges, *and watches its own engine
      run*, at full feature parity with the Python `ember` (which stays as a reference UI).
