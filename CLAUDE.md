# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **New here / no prior context?** Read `GUIDE.md` first — it teaches the fr language and
> the whole project from scratch. `DECISIONS.md` records *why* the design is the way it is
> (read before "fixing" something odd); `ROADMAP.md` is what's next. Run `./test.sh` to
> verify everything builds and passes. This file is the terse cheatsheet.

## What this is

**forthright** is an experiment toward an "AI writes it, a verifier checks it, ship tiny
auditable Forth" pipeline (see README.md for the thesis). Concretely the repo holds the
kernel `fr` plus a stack of self-hosted `.fr` tools (the whole repo is Python-free); the pieces:

- **`fr`** — a freestanding indirect-threaded-code (ITC) Forth for x86-64 Linux, written
  as a single GNU-assembler file `fr.s`. No libc, no runtime: raw syscalls + threaded code.
  Exposes `syscall6 ( a1 a2 a3 a4 a5 a6 n -- ret )` — a raw Linux syscall (up to 6 args),
  the one primitive that opens the whole OS to fr: read/write/ioctl (raw-tty), mmap, and
  crucially ptrace/fork/wait4 (so even the debugger backend is reachable from fr). `syscall3`
  is now a prelude word derived from it. ABI: number in `%rax`, args in `%rdi %rsi %rdx %r10
  %r8 %r9` (arg4 is `%r10`, not `%rcx`); `%rsi` is the Forth IP so arg2 is parked + IP saved.
  Other kernel primitives that exist because they enable a real **library** (and are slow/ugly
  to derive): **`include PATH`** (load another source file, then resume — a nested input-source
  stack saving the parent fd + its unparsed inbuf remainder; *load-once* via a path registry,
  so diamond deps load once), **`s" …"` / `." …"`** string literals (IMMEDIATE; compile an
  inline `(s")`/`(.")` runtime + `[count][bytes][pad]`, advancing the IP **relative** to the
  bytes since the packed dict isn't cell-aligned; interpreted, they act immediately — the
  interpret-mode `s"` buffer is transient), **`cmove fill xor lshift rshift`**, and counted
  loops **`do … loop`** (compile-only; index `i`, outer `j`, `unloop` before an early `exit`).
- **`lib/`** — the self-hosted standard library (see `lib/README.md`). Files load each
  other with the kernel's **`include`**, so a program just `include lib/tui.fr` and runs as
  `./fr myapp.fr`. Modules: `prelude` (core), `math`, `string`, `fmt`, `random`, `term` (ANSI+termios),
  `key` (escape-seq decoding → `KEY-*`), `draw` (panels/rules), `tui` (label/status-bar/menu/
  accept), `time`, `io`, `ptrace`. **Paths are resolved from the project root** (CWD), not the
  including file. The `anvil`/`forge`/`ember` tools live at the repo root and `include lib/…`.
- **`lib/prelude.fr`** — fr's core vocabulary: everything derivable, written in fr
  (`over rot nip 2dup 2drop negate 1+ 1- cells cell+ > 0= , char cr space square u.`;
  `over`/`rot` use `>r`/`r>`). The rule: **if a word can be defined in fr, it goes in
  `lib/prelude.fr` (or another lib module), not in `fr.s`** (the kernel is irreducible
  primitives + the parse/compile/IO bootstrap). Pulled in by every other module via
  `include lib/prelude.fr`. It also defines **`see`** — a self-hosted
  thread decoder (`see square` → `dup * ;`) that walks the dictionary via `latest` and
  the kernel's `sys` table (which exposes the headerless engine CFAs docol/lit/exit/
  branch/0branch). This is the fr-native analog of ember's introspection. `key ( -- c )`
  reads one byte from stdin via `syscall3` (the input primitive the fr-native TUIs use).
- **`lib/term.fr`** — terminal control written in fr (`include lib/term.fr`, which pulls
  the prelude). ANSI output (`clear at fg bg sgr bold reset
  hide-cursor show-cursor`; `cleol`/`atclr` for flicker-free in-place redraw; `fg24` +
  a `nord-*` true-colour palette; `box` + UTF-8 line glyphs for the bordered dashboard) and
  termios raw/cbreak mode via `ioctl` (`raw-on`/`raw-off` clear `ICANON|ECHO`; `raw-timed`/
  `raw-poll` flip VMIN/VTIME so `key` can time out — the frame clock for ember's autoplay;
  `term-size` reads `TIOCGWINSZ`). With `key` + `see` + `trace`,
  this is the full substrate for an interactive ember in fr.
- **`ptrace.fr`** — process control + ptrace in fr (on `syscall6`): `fork`/`wait4`/`traceme`/
  `ssstep`/`getregs`/`peekdata`. `watch` drives the *real* fr engine: fork (child shares the
  memory image, so the parent's dictionary decodes the child's CFAs), single-step to each
  `jmp *(%rax)` boundary, name `%rax`. `5 ' square watch` → `… execute square dup * ; bye`.
- **`ember.fr`** — the **self-hosted explorer**: a visual stepper driving the *real* fr engine
  under ptrace (built on `ptrace.fr` + `term.fr`). `<args> ' <word> ember` forks a child that
  runs the word, then single-steps it to each `jmp *(%rax)` boundary, reading the child's real
  registers and data stack (`peekdata`). A **full-screen, responsive** Nord dashboard (`measure`
  re-reads `term-size` each frame): `code` (the
  word's body, one cell per row, live cell highlighted / executed cells dimmed, scrolls),
  `data` (the real stack `5 → 5 5 → 25`, top first), `call` (the live path `cube > square`,
  inferred from `docol`-entries/`EXIT`s), `dict` (the live dictionary, colon words highlighted),
  `out` (the child's **captured stdout** — `launch` points the child's fd 1/2 at an O_NONBLOCK
  pipe and the parent drains it each frame, so a printing word lands in the panel instead of
  corrupting the TUI), an input box, and a key/status row. Keys: `space`/`s` step, **`a`
  autoplay** (timer-driven via `raw-timed` VMIN/VTIME; `+`/`-` change speed), `r` run to end,
  `e` edit, `q`/`Esc` quit. **The `e` edit line is a REPL** (`edit-target`): each line is
  compiled (`compile-line`) into an anonymous thread — with the *resting* stack re-pushed in
  front — and stepped (so `5 square`, `4 4 +`, or `3` all work; an unknown token flashes
  `<word> ?`). At the thread's top-level `EXIT`, `l-step` calls `e-finish`: snapshot the data
  stack into `esaved`, kill the child, and **rest** (it doesn't `bye`/exit), so the result
  carries to the next line — `5 5 5 +` rests at `10 5`, then `3 *` → `30 5`. (`e-rest` gates
  this to the interactive explorer; `ember-trace` leaves it off and runs to `bye`.) Run with
  **no Python**: `./fr ember.fr`, then type `5 ' square ember` (or the one-line `./ember-fr` shell launcher — the
  terminal *is* the tty `raw-on` needs). `ember-trace` is its non-interactive core (prints the
  live stack per dispatch). The lighter, no-ptrace text stepper is the prelude's `trace`.
  The visual design doc is **`index.html`** (the "NEXT-runner" React mock — its `steps.jsx`/`tui.jsx`
  aren't committed, but its `:root` Nord palette and pulse keyframes are the spec); ember.fr mirrors
  it in the terminal: the `nord-*` palette, a `▸` IP marker, reverse-video fill on the executing
  cell, and a one-frame reverse "pulse" on the data/call panels when they change (see `l-pulse`).
- **`anvil.fr`** — a stack-effect verifier **written in fr** (self-hosted), on prelude+math.
  `check{ … }` infers a phrase's `( in -- out )` by abstract stack simulation; `def name
  ( decl ) body ;` infers + registers a word's effect (so words compose) and checks it
  against the declaration. Verdicts: `ok` · `BAD ( … )` (declared *arity* mismatch) · `? names`
  (unknown words, named) · `br!` (if/else/then arms disagree, or a loop body isn't
  stack-neutral) · `ctl!` (unbalanced control structure — `if` w/o `then`, &c.) · `r!`
  (return stack `>r`/`r>`/`r@` unbalanced) · `ty!` (cell-kind error) · `/0!` (division by a
  literal zero) · `ex!` (early `exit`s leave different effects). It checks `if/else/then`,
  `begin/until`, `begin/while/repeat`, counted `do/loop`, early `exit` consistency, *declared*
  recursion (the self-call assumes the decl), and **cell kinds** — a
  conservative type layer (number/address/flag/unknown, riding on the height sim) where
  `@ ! c@ c!` need an address, `* / mod` reject address/flag operands, and `+` rejects
  address+address; kinds flow from literals, comparisons, kind-named decl inputs *and outputs*
  (`addr`/`n`/`flag`), and a word **advertises its output kind to callers** (a `variable`
  produces an address; `def mkbuf ( -- addr ) … ;` lets `mkbuf @` typecheck) — checked too: a
  body that returns the wrong address-ness vs its declared output is `ty!`. *Unknown is
  absorbing* (and num/flag are interchangeable) so false positives are essentially nil. It also
  **shadows `variable`/`constant`** (building the real word *and* registering its name), so it
  checks *stateful* code instead of flagging the variable unknown. It also handles the
  **parsing words** (`s" … "` → `( addr len )`, `." … "` → `( )`, `[char]`/`char` → a number,
  `'`/`[']` → an address) that consume a following token. Sound for the structured code fr
  produces; proves **shape (+ a little kind), not value**. The reason the project exists;
  `anvil-spec.md` is its spec.
- **`forge.fr`** — the generate → check → repair loop, **self-hosted in fr**: a generator
  builds candidate threaded bodies, the self-hosted `anvil` (`check-body`) verifies each
  one's stack effect, shape-valid candidates are `execute`d on examples, and the first
  passing both is "forged". Run: `echo forge | ./fr forge.fr` (forge includes prelude + anvil).
  Needed `execute` (kernel prim, run a CFA), `'` (prelude tick), and the anvil `check-body`
  refactor (check a compiled body by CFA, not stdin tokens). `forge-spec.md` describes the loop.

Naming map: **forthright** (project) · **fr** (the Forth) · **ember.fr** (the self-hosted
explorer) · **anvil** (the verifier) · **forge** (synthesis).

**File conventions.** Forth source uses the `.fr` extension (the kernel `fr.s` is GNU
assembler). The project's direction is to **self-host its tooling in fr**, keeping the whole
trust base small/auditable — `anvil.fr`, `forge.fr`, `lib/term.fr`, `lib/ptrace.fr`, and
`ember.fr` are all self-hosted; with `syscall6`, even the ptrace debugger backend is in fr.
The `anvil-spec.md`/`forge-spec.md` *reference specs* (markdown) describe intended behavior;
**keep them in sync as those tools gain features**. The explorer runs with no Python
(`./fr ember.fr`, or the one-line shell `./ember-fr`). **The repo is entirely Python-free** —
even the scripted pty test harness is fr (`lib/pty.fr` + `ember-test.fr`, which spawns
`./fr ember.fr` on a real pseudo-terminal, paces keystrokes, and asserts on the captured frames;
a plain pipe can't, since the child's first read would swallow the canned input). (A Python/curses
`ember`, the Python `anvil`/`forge` reference *implementations*, and the Python `ember-pty` were
all removed once the fr versions matched them — see DECISIONS.md.)

## Commands

**Run fr from the project root** — `include` paths (`lib/…`) are CWD-relative.
```sh
./build.sh                 # assemble + link fr  (as --gstabs ; ld) -> ./fr
echo '3 4 + 5 * .' | ./fr  # fr is a REPL: reads Forth from stdin until EOF
./fr                       # interactive; Ctrl-D / `bye` to quit
echo 'check{ dup dup * * }' | ./fr anvil.fr     # self-hosted verifier -> ( x -- y )  (anvil includes prelude)
echo '5 square .' | ./fr lib/prelude.fr         # load a lib module as a file arg, then read stdin
./fr examples/demo.fr                           # a TUI sample using the lib (math/fmt/draw/tui)
./fr examples/tetris.fr                         # a playable Tetris on the lib

./fr ember.fr              # the SELF-HOSTED explorer (it `include`s lib/{prelude,term,ptrace}); type: 5 ' square ember
./ember-fr ["3 ' square ember"] # shell launcher (no Python); no arg = bare `ember` (edit prompt)
echo step | ./fr ember-test.fr  # fr-native pty test of ember.fr; also: prompt edit expr auto out repl tetris
./test.sh                       # core suite: kernel/prelude/lib/anvil/forge/term
./test-ember.sh                 # the explorer's own suite (ptrace.fr, ember.fr under a pty)
./test.sh --all                 # both suites
```

There is no test framework; `./test.sh` is the one-command answer for the **core**
(kernel/prelude/lib/anvil/forge/term — expect `ALL CHECKS PASSED`).
The explorer has its own suite, **`./test-ember.sh`** (ptrace.fr, and ember.fr via `ember-trace`
(pipe) and `ember-test.fr` (an fr-native paced pty)); `./test.sh --all` runs both.

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
does `%rsi += *%rsi`). `do … loop` follows the same pattern — `do`/`loop` are IMMEDIATE and
compile the headerless runtimes `pdo`/`ploop`, which keep `(index, limit)` on the **return
stack** (index on top, so `i` = `r@`, `j` = the next loop out); `unloop` drops that control
before an early `exit`. (`?do`/`+loop`/`leave` are not built yet.) `ZBRANCH`/`BRANCH`/`LIT`/
`EXIT`/`pdo`/`ploop` are headerless internal words (emitted by code, not typed), so they are
not in the `FIND` chain — and `see` can't decode `s"`/`."`/`do`-loops for the same reason.

**Input layer — robust across refills, and loads files from `argv`.** `_word` copies each
token into `wordbuf` as it scans, and `_word`/`\`/`(` all call `_refill` mid-scan when `inbuf`
runs out — so tokens and comments may span any number of refills, and stdin can be read in any
chunk size (a pipe, a pty, a 1-byte dribble) without splitting. `_refill` reads from `var_infd`,
which `_next_source` walks through the `argv` files (`argv[1..]`) and then stdin: so
`./fr a.fr b.fr` loads those files in order and then drops to the stdin REPL (a missing file is
skipped). `argc`/`argv` are captured in `_start` before `%rsp` becomes the data stack. This is
what lets the self-hosted explorer run with no launcher: `./fr ember.fr`. **`include`** nests
on top of this: it pushes a frame (`incl_stack`) saving the current fd + the unparsed `inbuf`
remainder, switches `var_infd` to the new file, and `_refill` pops the frame on EOF (restoring
the parent's inbuf) before falling through to `_next_source`. A path registry (`incl_registry`)
makes it load-once. **`s"`/`."`** compile an inline `(s")`/`(.")` runtime cell + `[count][bytes]`
padded to a cell; the runtime and the compiler both advance **relative to the bytes** (not to an
absolute 8-boundary), because the packed dictionary is not cell-aligned (`CFA = header+9+len`).
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

## ember.fr architecture (the explorer)

`ember.fr` forks the running fr (the child shares the dictionary, so the parent can name the
child's CFAs with `.cfaname`), single-steps it under ptrace to each `jmp *(%rax)` (`FF 20`)
dispatch boundary, and reads the child's registers + data stack via `PTRACE_GETREGS`/`PEEKDATA`
(the wrappers live in `lib/ptrace.fr`). The full-screen dashboard is rebuilt in place each
frame; the panels, keys, and REPL behaviour are documented in `ember.fr`'s header comment.

**Invariants when reading the engine under ptrace (these caused the past "garbage" bugs):**
- The **active cell is at `%rsi-8`**, not `%rsi`: `lodsq` (in `NEXT`) has already advanced the
  IP past the CFA now in `%rax`. Highlight / thread-centre on `%rsi-8`.
- **Only read the stacks at a dispatch boundary**, where the data stack is clean.
- **Bound the thread decode** (stop at `EXIT` / a branch's inline offset / the first non-code
  cell) so raw memory past a definition isn't rendered as giant numbers — `ember.fr`'s
  `body-step`/`body-emit` and the prelude's `see` both do this.
