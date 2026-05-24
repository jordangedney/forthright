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

## Architecture (working names)

- **anvil** — the verifier. The thing generated code gets hammered against until it's
  stack-correct. Stack-effect checking first; richer type/intent checks later. The core
  of the whole bet: anvil is the redundancy Forth doesn't have, living *outside* the
  shipped code.
- *(generator)* — drives the AI generate → check → repair loop against anvil.
- *(corpus)* — generate-and-verify at scale to mint a synthetic training corpus, the one
  credible attack on Forth's "no training data" problem.

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
memory `@ ! c@ c! here allot`, return stack `>r r> r@`, arithmetic `+ - * / mod`,
`= <`, `and or`, I/O `. emit type word find number s= [char]`, `variable constant
latest sys bye`, and the compiling words `: ; if else then begin until while repeat \ (`.
Load **prelude.fr** for the rest (`over rot nip 2dup 2drop negate 1+ 1- cells cell+
> 0= , char cr space square u.`). Numbers (incl. negatives) push themselves; unknown
tokens echo back with `?`.

    echo ': cube dup dup * * ;  4 cube .' | ./fr                                # -> 64
    ( cat prelude.fr; echo ': abs dup 0 < if negate then ;  -5 abs .' ) | ./fr   # -> 5
    ( cat prelude.fr; echo ': cd begin dup . 1 - dup 0 = until drop ;  5 cd' ) | ./fr

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

`ember.fr` is the same idea, **written in fr**: an interactive visual stepper that
walks a word's threaded body on the live data stack, one cell per keypress, with the
current cell highlighted and a live `data` panel. It's built entirely on fr — `see`/
`trace` for the model, `key`/`raw-on` (the kernel's `syscall3` → `ioctl`) for input,
`term.fr` for ANSI output. It runs with **no Python at all**: the kernel loads the
library from its file arguments, then the terminal is the REPL (so `raw-on` has a real
tty). Type a stepping command at the prompt:

    ./fr prelude.fr term.fr ember.fr      # then type:  3 ' cube ember

```
 ember: cube  #2            space=step  r=run  q=quit
 call   cube > square       (stepped INTO square)
 code   dup * ;             (square's body, current cell highlit)
 data   3 3
```

It **steps into colon words** — descending through `docol`/`EXIT` while tracking its
own call stack — so the `code` panel switches to the callee and `call` shows the path
`cube > square`, exactly like the Python ember hopping into a definition (primitives
stay atomic). It also **follows control flow**: `0branch` pops the live flag and
`branch` moves the cursor, so `if/else` and `begin/until` loops step too. `r` runs to
the end. The `ember-fr` script is a convenience/test wrapper (it adds a pty so
keystrokes can be scripted: `./ember-fr --selftest`). The Python `ember` keeps what fr
can't reach — the `ptrace` backend over real machine instructions, and its richer
curses view (RETURN frames, dictionary, Nord palette).

## Verifying it: anvil.fr (self-hosted)

`anvil.fr` is the payoff — a stack-effect verifier **written in fr**, so the whole
trust chain (language + checker) stays small enough to audit. Load it, then either
infer a phrase's effect or define-and-check a word against its declared signature
(effects print as `( x.. -- y.. )`, one glyph per cell):

    ( cat prelude.fr anvil.fr; echo 'check{ dup dup * * }' )       | ./fr  # ( x -- y )
    ( cat prelude.fr anvil.fr; echo 'def sq ( n -- n ) dup * ;' )  | ./fr  # sq ( x -- y )  ok
    ( cat prelude.fr anvil.fr; echo 'def bad ( a b -- c ) + + ;' ) | ./fr  # BAD ( xx -- y )

(anvil.fr builds on `prelude.fr`, fr's standard library — see below.)

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

    ( cat prelude.fr anvil.fr forge.fr; echo forge ) | ./fr

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
      `/ mod`, return stack `>r r> r@`, and `latest` (dictionary introspection)
- [x] **prelude.fr** — fr's standard library, *everything* derivable pulled out of
      the assembly kernel and written in fr: `over rot nip 2dup 2drop`, `negate 1+
      1- cells cell+`, `> 0=`, `, char cr space square`, and `u.` (a decimal printer
      built from `/mod`). `over`/`rot` are defined via `>r`/`r>`. The rule: if a word
      can be written in fr, it lives here, not in fr.s — which is now down to ~2.9 KB
      of irreducible primitives + the parse/compile/IO bootstrap. Load with
      `( cat prelude.fr prog.fr ) | ./fr`. (anvil.fr builds on it.)
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
- [x] **`syscall3`** (kernel) + **`key`** (prelude) — one generic Linux syscall
      (≤3 args: read/write/ioctl), opening raw-tty I/O to fr.
- [x] **term.fr** — terminal control *in fr*: ANSI escapes (`clear at fg bg`) and
      termios cbreak via `ioctl` (`raw-on`/`raw-off`, validated under a pty).
- [x] **Robust input + file loading** (kernel) — `_word` reassembles tokens (and the
      comment words refill) across reads, so input can arrive in any chunk size; and
      `./fr a.fr b.fr` loads source files from `argv` before the stdin REPL.
- [x] **ember.fr** — the **self-hosted ember**: an interactive visual stepper written
      in fr, run with no Python (`./fr prelude.fr term.fr ember.fr`). Steps a word's
      threaded body on the live stack, current cell highlighted, and **follows control
      flow** (if/else + loops). fr now writes, verifies, forges, *and watches* its own
      code — only the ptrace backend stays in Python.
