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

Known words: `dup drop swap over + - * . negate = < > 0= bye square`, memory words
`@ ! c@ c! , here allot cells cell+ variable constant`, the control-flow words
`if else then begin until`, parsing/IO `word find number s= char [char] emit type cr`,
glue `exit 2dup 2drop nip rot 1+ 1- and or` + `begin while repeat`,
and `:` `;` for defining your own.
Numbers (incl. negatives) push themselves; unknown tokens echo back with `?`.

    echo ': cube dup dup * * ;  4 cube .'          | ./fr   # -> 64
    echo ': abs dup 0 < if negate then ;  -5 abs .' | ./fr   # -> 5
    echo ': countdown begin dup . 1 - dup 0 = until drop ;  5 countdown' | ./fr

Engine conventions: `%rsi`=IP, `%rsp`=data stack, `%rbp`=return stack, `%rax`=W.
`NEXT` is the inner interpreter; `docol`/`EXIT` drive the return stack. The outer
interpreter (`_word`/`_find`/`_number` + `INTERPRET`) is driven by the threaded
`QUIT` loop, which branches back on itself forever.

## Exploring it: ember (TUI)

`ember` is a terminal UI for *watching* the engine work — a threaded-code stepper
styled after the `design` (NEXT-runner) Nord palette and execution colour coding
(ip=cyan, stack=orange, hop=purple, exec=yellow). You single-step the inner
interpreter and *see* the IP walk a thread and the stacks change.

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

## Verifying it: anvil.fr (self-hosted)

`anvil.fr` is the payoff — a stack-effect verifier **written in fr**, so the whole
trust chain (language + checker) stays small enough to audit. Load it, then either
infer a phrase's effect or define-and-check a word against its declared signature
(effects print as `( x.. -- y.. )`, one glyph per cell):

    ( cat anvil.fr; echo 'check{ dup dup * * }' )         | ./fr   # ( x -- y )
    ( cat anvil.fr; echo 'def sq ( n -- n ) dup * ;' )    | ./fr   # sq ( x -- y )  ok
    ( cat anvil.fr; echo 'def bad ( a b -- c ) + + ;' )   | ./fr   # bad ( xxx -- y )  BAD ( xx -- y )

It keeps a name→`(consumes,produces)` table (`prim` for built-ins, `def` for new
words). `check{ … }` / `def` read tokens, classify each (number / known word /
unknown), and run the abstract stack simulation (`hgt`/`lo`): inputs `= -lo`,
outputs `= inputs+hgt`. `def` registers the inferred effect (so words compose) and
flags any disagreement with the declared `( … -- … )`. `anvil-reference.py` is the
Python spec it follows.

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
- [x] Glue for practical programming: `exit 2dup 2drop nip rot 1+ 1- and or`,
      `begin while repeat`; comments `\` and `(` (~3.3 KB text)
- [x] **anvil.fr**, self-hosted: a stack-effect verifier written *in fr* (~90
      lines). `check{ … }` infers a phrase's `( in -- out )`; `def name ( decl )
      body ;` infers a definition's effect, registers it (so later words compose),
      and flags any mismatch with the declared signature. The thesis made literal
      — the redundancy Forth lacks, in a trust base small enough to audit.
      (`anvil-reference.py` = Python spec.)
- [ ] anvil.fr next: branch analysis — both arms of `if/else` must leave the same
      stack effect (the rule that makes a concatenative checker genuinely powerful)
