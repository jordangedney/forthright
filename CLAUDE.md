# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **New here / no prior context?** Read `GUIDE.md` first — it teaches the fr language and
> the whole project from scratch. `DECISIONS.md` records *why* the design is the way it is
> (read before "fixing" something odd); `ROADMAP.md` is what's next. Run `./test.sh` to
> verify everything builds and passes. This file is the terse cheatsheet.

## What this is

**forthright** is an experiment toward an "AI writes it, a verifier checks it, ship tiny
auditable Forth" pipeline (see README.md for the thesis). Concretely the repo currently
holds two pieces:

- **`fr`** — a freestanding indirect-threaded-code (ITC) Forth for x86-64 Linux, written
  as a single GNU-assembler file `fr.s`. No libc, no runtime: raw syscalls + threaded code.
  Exposes `syscall3 ( a1 a2 a3 n -- ret )` — a raw Linux syscall (≤3 args: read/write/ioctl
  fit), which opens raw-tty I/O to fr and is the gate for a self-hosted interactive ember.
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
  reads one byte from stdin via `syscall3` (the input primitive for a future fr-native TUI).
- **`term.fr`** — terminal control written in fr, loaded after the prelude
  (`cat prelude.fr term.fr …`). ANSI output (`clear at fg bg sgr bold reset
  hide-cursor show-cursor`) and termios raw/cbreak mode via `ioctl` (`raw-on`/`raw-off`
  clear `ICANON|ECHO`; `term-size` reads `TIOCGWINSZ`). With `key` + `see` + `trace`,
  this is the full substrate for an interactive ember in fr.
- **`ember.fr`** — the **self-hosted ember**: an interactive visual single-stepper written
  in fr (the fr-native analog of the Python `ember`). `<args> ' <word> ember` steps the
  word's threaded body cell by cell on the live data stack, drawing a `code`/`data` panel
  with the current cell highlighted (built on `term.fr` + `see`/`trace`). `space`/`s` step,
  `q`/`Esc` quit. Straight-line + literals only (stops at branches, like `trace`). Launch
  via `./ember-fr` (a Python pty bridge — fr's `raw-on` needs a real tty). The Python
  `ember` keeps what fr can't do: the `ptrace` backend and the full multi-panel debugger.
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
trust base small/auditable — `anvil.fr`, `forge.fr`, `term.fr`, and now `ember.fr` are all
self-hosted. The remaining host-language piece is `ember` (Python), whose `ptrace` backend
fr can't replace; its `anvil-reference.py`/`forge-reference.py` *reference specs* track
intended behavior and **must be kept in sync as those tools gain features**. `ember.fr` is
launched via the `ember-fr` pty bridge (host-glue, like ember's ptrace backend).

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

./ember-fr "5 ' square ember"   # the SELF-HOSTED stepper: ember.fr under a pty (real tty)
./ember-fr --selftest           # headless pty check of ember.fr (scripts keystrokes)
./test.sh                       # core suite: kernel/prelude/anvil/forge/term + reference specs
./test-ember.sh                 # the explorer's own suite (ember model, ptrace, ember.fr/pty)
./test.sh --all                 # both suites
```

There is no test framework; `./test.sh` is the one-command answer for the **core**
(kernel/prelude/anvil/forge/term + the Python reference specs — expect `ALL CHECKS PASSED`,
~0.25s). The explorer has its own, costlier suite, **`./test-ember.sh`** (the Python model,
the ptrace backend, ember.fr under a pty, plus fast pipe-driven ember.fr render/step checks);
`./test.sh --all` runs both. The `--selftest` modes are the individual assertions these call.
The native ember backend reads `fr`'s ELF symbol table, so **keep the binary unstripped**
(`build.sh` already does).

## fr.s architecture (the Forth kernel)

Register convention is the whole engine: `%rsi`=IP, `%rsp`=data stack, `%rbp`=return stack,
`%rax`=W (scratch). The inner interpreter is the `NEXT` macro = `lodsq ; jmp *(%rax)`:
fetch the next CFA into W and jump through it. `docol` (`fr.s:41`) enters a colon definition
(pushes IP to the return stack); `EXIT` pops it. `_start` (`fr.s:33`) sets up the stacks and
points IP at the `cold_start`→`QUIT` thread.

**Dictionary layout is packed, no alignment.** Each entry is `[ .quad link | .byte len |
.ascii name ]` immediately followed by the codeword cell (the CFA). Therefore
`CFA = header + 9 + len`, and `_find` relies on this exact arithmetic. The high bit of the
len byte is the IMMEDIATE flag (`0x80`); `_find` masks with `0x7f`. The list head is the
`var_latest` variable.

**Outer interpreter / REPL:** `_word`/`_find`/`_number` (`fr.s:262`,`309`,`345`) are helper
routines, and `code_INTERPRET` (`fr.s:382`) dispatches one token. The loop itself is *threaded
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

**Known limitation — a token cannot span an input refill.** `_word` returns a pointer into
`inbuf`; if a token straddles the end of one `read` and the next, it splits (you'll see a
bogus partial token like `rop`). `inbuf` is 64 KB so whole source files normally arrive in
one read (pipe reads align to write/newline boundaries), but a `.fr` file larger than that,
or a single token near a buffer edge, can still trip it. The robust fix (copy tokens into a
holding buffer so they span refills) isn't done yet.

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
