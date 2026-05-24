# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **New here / no prior context?** Read `GUIDE.md` first — it teaches the fr language and
> the whole project from scratch. `DECISIONS.md` records *why* the design is the way it is
> (read before "fixing" something odd); `ROADMAP.md` is what's next. Run `./test.sh` to
> verify everything builds and passes. This file is the terse cheatsheet.

## What this is

**forthright** is an experiment toward an "AI writes it, a verifier checks it, ship tiny
auditable Forth" pipeline (see README.md for the thesis). Concretely the repo holds the
kernel `fr` plus a stack of self-hosted `.fr` tools (and a Python explorer); the pieces:

- **`fr`** — a freestanding indirect-threaded-code (ITC) Forth for x86-64 Linux, written
  as a single GNU-assembler file `fr.s`. No libc, no runtime: raw syscalls + threaded code.
  Exposes `syscall6 ( a1 a2 a3 a4 a5 a6 n -- ret )` — a raw Linux syscall (up to 6 args),
  the one primitive that opens the whole OS to fr: read/write/ioctl (raw-tty), mmap, and
  crucially ptrace/fork/wait4 (so even the debugger backend is reachable from fr). `syscall3`
  is now a prelude word derived from it. ABI: number in `%rax`, args in `%rdi %rsi %rdx %r10
  %r8 %r9` (arg4 is `%r10`, not `%rcx`); `%rsi` is the Forth IP so arg2 is parked + IP saved.
- **`ember`** — a Python/curses TUI that single-steps the engine and visualizes it. By
  default it drives the *real* `fr` binary under `ptrace`; `--python` uses an equivalent
  pure-Python model. At startup it **bootstraps `prelude.fr`** into the traced fr (so
  `see`, `over`, etc. are available), and `run`/bootstrap use an int3 breakpoint at the
  `read` syscall + `PTRACE_CONT` to run fr at native speed (single-stepping is only for the
  interactive `s`).
- **`prelude.fr`** — fr's standard library: everything derivable, written in fr
  (`over rot nip 2dup 2drop negate 1+ 1- cells cell+ > 0= , char cr space square u.`;
  `over`/`rot` use `>r`/`r>`). The rule: **if a word can be defined in fr, it goes in
  `prelude.fr`, not in `fr.s`** (the kernel is ~2.9 KB of irreducible primitives + the
  parse/compile/IO bootstrap). Load it before any program that needs it:
  `( cat prelude.fr yourprog.fr ) | ./fr`. It also defines **`see`** — a self-hosted
  thread decoder (`see square` → `dup * ;`) that walks the dictionary via `latest` and
  the kernel's `sys` table (which exposes the headerless engine CFAs docol/lit/exit/
  branch/0branch). This is the fr-native analog of ember's introspection. `key ( -- c )`
  reads one byte from stdin via `syscall3` (the input primitive the fr-native TUIs use).
- **`term.fr`** — terminal control written in fr, loaded after the prelude
  (`cat prelude.fr term.fr …`). ANSI output (`clear at fg bg sgr bold reset
  hide-cursor show-cursor`; `cleol`/`atclr` for flicker-free in-place redraw; `fg24` +
  a `nord-*` true-colour palette; `box` + UTF-8 line glyphs for the bordered dashboard) and
  termios raw/cbreak mode via `ioctl` (`raw-on`/`raw-off`
  clear `ICANON|ECHO`; `term-size` reads `TIOCGWINSZ`). With `key` + `see` + `trace`,
  this is the full substrate for an interactive ember in fr.
- **`ptrace.fr`** — process control + ptrace in fr (on `syscall6`): `fork`/`wait4`/`traceme`/
  `ssstep`/`getregs`/`peekdata`. `watch` drives the *real* fr engine: fork (child shares the
  memory image, so the parent's dictionary decodes the child's CFAs), single-step to each
  `jmp *(%rax)` boundary, name `%rax`. `5 ' square watch` → `… execute square dup * ; bye`.
- **`ember.fr`** — the **self-hosted explorer**: a visual stepper driving the *real* fr engine
  under ptrace (built on `ptrace.fr` + `term.fr`). `<args> ' <word> ember` forks a child that
  runs the word, then single-steps it to each `jmp *(%rax)` boundary, reading the child's real
  registers and data stack (`peekdata`). A Nord-coloured bordered dashboard: `call` (live call
  path `cube > square`, inferred from `docol`-entries/`EXIT`s), `code` (current word's body,
  live cell highlighted), `data` (the real stack `5 → 5 5 → 25`). Keys: `space`/`s` step, `r`
  run to end, `e` edit (re-fork on a new target: `3 square`, `2 3 + square`; unknown/non-colon
  flashes `<word> ?`), `q`/`Esc` quit. Run with **no Python**: `./fr prelude.fr term.fr ptrace.fr
  ember.fr`, then type `5 ' square ember` (or the one-line `./ember-fr` shell launcher — the
  terminal *is* the tty `raw-on` needs). `ember-trace` is its non-interactive core (prints the
  live stack per dispatch). The lighter, no-ptrace text stepper is the prelude's `trace`. The
  Python `ember` stays only as a more *mature* UI (curses chrome), not a capability fr lacks.
- **`anvil.fr`** — a stack-effect verifier **written in fr** (self-hosted), built on the
  prelude. `check{ … }`
  infers a phrase's `( in -- out )` by abstract stack simulation; `def name ( decl ) body ;`
  infers + registers a word's effect (so words compose) and flags mismatches with the
  declared signature. The project's reason for existing; `anvil-reference.py` is its spec.
- **`forge.fr`** — the generate → check → repair loop, **self-hosted in fr**: a generator
  builds candidate threaded bodies, the self-hosted `anvil` (`check-body`) verifies each
  one's stack effect, shape-valid candidates are `execute`d on examples, and the first
  passing both is "forged". Run: `( cat prelude.fr anvil.fr forge.fr; echo forge ) | ./fr`.
  Needed `execute` (kernel prim, run a CFA), `'` (prelude tick), and the anvil `check-body`
  refactor (check a compiled body by CFA, not stdin tokens). `forge-reference.py` = Python spec.

Naming map: **forthright** (project) · **fr** (the Forth) · **ember**/**ember.fr** (the
explorer, in Python and now self-hosted) · **anvil** (the verifier) · **forge** (synthesis).

**File conventions.** Forth source uses the `.fr` extension (the kernel `fr.s` is GNU
assembler). The project's direction is to **self-host its tooling in fr**, keeping the whole
trust base small/auditable — `anvil.fr`, `forge.fr`, `term.fr`, `ptrace.fr`, and `ember.fr`
are all self-hosted; with `syscall6`, even ember's ptrace debugger backend is now in fr.
The Python `ember` remains only as the *more mature* explorer UI (Nord curses, dictionary
panel), not a capability fr lacks. The `anvil-reference.py`/`forge-reference.py` *reference
specs* track intended behavior and **must be kept in sync as those tools gain features**. The
fr explorer runs with no Python (`./fr prelude.fr term.fr ptrace.fr ember.fr`, or the one-line
shell `./ember-fr`); `ember-pty` is a Python harness only for *scripted* (paced) testing.

## Commands

```sh
./build.sh                 # assemble + link fr  (as --gstabs ; ld) -> ./fr
echo '3 4 + 5 * .' | ./fr  # fr is a REPL: reads Forth from stdin until EOF
./fr                       # interactive; Ctrl-D / `bye` to quit
( cat prelude.fr anvil.fr; echo 'check{ dup dup * * }' ) | ./fr   # self-hosted verifier -> ( x -- y )

./ember                    # Python TUI driving the real ./fr via ptrace (Linux; needs ~76x20)
./ember --python           # TUI on the pure-Python model instead
./ember --selftest         # headless check of the Python model  (the "test suite")
./ember --native-selftest  # headless check that drives ./fr under ptrace

./fr prelude.fr term.fr ptrace.fr ember.fr   # the SELF-HOSTED explorer (then type: 5 ' square ember)
./ember-fr ["5 ' square ember"] # shell launcher (no Python); pre-runs a command, default 5 square
./ember-pty --selftest          # headless pty test of ember.fr; also --edit-selftest
./test.sh                       # core suite: kernel/prelude/anvil/forge/term + reference specs
./test-ember.sh                 # the explorer's own suite (ptrace, ember.fr, Python ember)
./test.sh --all                 # both suites
```

There is no test framework; `./test.sh` is the one-command answer for the **core**
(kernel/prelude/anvil/forge/term + the Python reference specs — expect `ALL CHECKS PASSED`,
~0.25s). The explorer has its own, costlier suite, **`./test-ember.sh`** (ptrace.fr, ember.fr
via `ember-trace` (pipe) and `ember-pty` (a paced pty), and the Python `ember`);
`./test.sh --all` runs both. The `--selftest` modes are the individual assertions these call.
The native ember backend reads `fr`'s ELF symbol table, so **keep the binary unstripped**
(`build.sh` already does).

## fr.s architecture (the Forth kernel)

Register convention is the whole engine: `%rsi`=IP, `%rsp`=data stack, `%rbp`=return stack,
`%rax`=W (scratch). The inner interpreter is the `NEXT` macro = `lodsq ; jmp *(%rax)`:
fetch the next CFA into W and jump through it. `docol:` enters a colon definition
(pushes IP to the return stack); `EXIT` pops it. `_start:` sets up the stacks and
points IP at the `cold_start`→`QUIT` thread. (Labels are greppable; line numbers drift.)

**Dictionary layout is packed, no alignment.** Each entry is `[ .quad link | .byte len |
.ascii name ]` immediately followed by the codeword cell (the CFA). Therefore
`CFA = header + 9 + len`, and `_find` relies on this exact arithmetic. The high bit of the
len byte is the IMMEDIATE flag (`0x80`); `_find` masks with `0x7f`. The list head is the
`var_latest` variable.

**Outer interpreter / REPL:** `_word:`/`_find:`/`_number:` are helper
routines, and `code_INTERPRET:` dispatches one token. The loop itself is *threaded
Forth*: the `QUIT` word is `INTERPRET ; BRANCH <back>` running forever — assembly and threaded
code interleave through `NEXT`. Compile mode uses `var_state`/`var_here`/`dict_space`: `:`
(`code_COLON`) builds a header + `docol` codeword and enters compile mode; `;` is IMMEDIATE
and compiles `EXIT` then leaves compile mode. Word-creating words share the `_create`
helper (builds the header from a name in `%rdi`/`%rcx`, returns the CFA slot in `%r9`);
the codeword it gets decides runtime behaviour — `docol` (colon), `dovar` (`variable`,
pushes its data address), `doconst` (`constant`, pushes its value). Add `create`/`does>`
the same way.

**Control flow** (`if/else/then`, `begin/until`) is built the standard Forth way: they are
IMMEDIATE words that run *during compilation*, emitting `BRANCH`/`ZBRANCH` (0branch) cells +
a placeholder offset, and using the **data stack at compile time** to remember the slot
addresses they later back-patch (offsets are relative to the offset cell, since `BRANCH`
does `%rsi += *%rsi`). To add more control flow (`while/repeat`, `do/loop`), follow the same
pattern. `ZBRANCH`/`BRANCH`/`LIT`/`EXIT` are headerless internal words (emitted by code, not
typed), so they are not in the `FIND` chain.

**Input layer — robust across refills, and loads files from `argv`.** `_word` copies each
token into `wordbuf` as it scans, and `_word`/`\`/`(` all call `_refill` mid-scan when `inbuf`
runs out — so tokens and comments may span any number of refills, and stdin can be read in any
chunk size (a pipe, a pty, a 1-byte dribble) without splitting. `_refill` reads from `var_infd`,
which `_next_source` walks through the `argv` files (`argv[1..]`) and then stdin: so
`./fr a.fr b.fr` loads those files in order and then drops to the stdin REPL (a missing file is
skipped). `argc`/`argv` are captured in `_start` before `%rsp` becomes the data stack. This is
what lets the self-hosted explorer run with no launcher: `./fr prelude.fr term.fr ptrace.fr ember.fr`.
**Gotcha when scripting:** `_refill`'s read uses `%rsi` (saved/restored), and `syscall` clobbers
`%rcx` — the mid-token refill in `_word` therefore `push`/`pop`s `%rcx` (the live token length).

**Critical, non-obvious invariant — helper-routine calling convention:** because `%rsp` *is*
the data stack, `_word`/`_find`/`_number`/`_refill` are reached with `call`/`ret` but **must
pass everything in registers and never touch the data stack** (the return address lives there
transiently). They must also save/restore `%rsi` around any syscall that uses it
(`read`/`write` clobber it as the buffer arg).

**To add a primitive/word:** add the packed header (link to the previous `h_*`, len byte,
name), a `NAME: .quad code_NAME` CFA cell, then the code ending in `NEXT`; link it into the
chain and update the `var_latest` initializer to the newest header. Do **not** add `.align`
(it breaks the `+9+len` CFA math). The binary is non-PIE static, so absolute-address
immediates are fine. The ITC dispatch instruction `jmp *(%rax)` assembles to bytes `FF 20`,
which `ember` keys on — don't introduce other `jmp *(%rax)` forms casually.

## ember architecture (the explorer)

The engine is deliberately decoupled from the curses UI so it runs headlessly. Two
interchangeable backends expose the same interface (`feed`/`step`/`run` + UI-facing fields
`dstack`/`rstack`/`frame`/`words`/`output`/`exec_name`/`halted`):

- **`VM`** — a pure-Python ITC model (mirrors `fr`, a superset of its words).
- **`NativeVM`** — drives the real `fr`: `fork`+`PTRACE_TRACEME`+`execv`, then single-steps
  machine instructions and stops at every `FF 20` (`jmp *(%rax)`) dispatch boundary. At that
  stop it reads registers (`PTRACE_GETREGS`) and memory (`/proc/<pid>/mem`), walks the live
  dictionary from `var_latest`, and decodes the thread. A tiny ELF `.symtab` parser
  (`_parse_elf_symbols`) supplies the symbol addresses.

`class UI` is the curses layer; `main()` picks `NativeVM` when `./fr` exists on Linux, else
`VM`. Colour coding follows the design: ip=cyan, stack=orange, hop=purple, exec=yellow.

**Non-obvious invariants in `NativeVM` (these were the source of past "garbage" bugs):**
- The **active cell is at `%rsi-8`**, not `%rsi`: `lodsq` has already advanced IP past the
  CFA now in `%rax`. Highlight and thread-center on `%rsi-8`.
- **Only snapshot the stacks at dispatch boundaries**, where the data stack is clean. At the
  input-read pause `fr` is blocked in `code_INTERPRET → _word → _refill → read`, so `%rsp`
  carries transient `call` return-addresses + a saved `%rsi`. `_pause_refresh` therefore
  preserves the last clean snapshot and only refreshes the dictionary/output.
- **Bound the thread decode** (`_body_at`: stop at `EXIT` / a branch's inline offset / the
  first non-code cell) so raw memory past a definition isn't rendered as giant numbers.
