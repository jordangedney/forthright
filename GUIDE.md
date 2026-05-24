# forthright — a guide for a fresh start

This teaches a new reader (human or Claude with no prior context) how the
**fr** language and the **forthright** project work, well enough to read, write,
run, and extend it. `CLAUDE.md` is the terse operating cheatsheet; this is the
tour. Everything lives in `~/vibing/forthright`.

---

## 1. What this is (the thesis)

forthright is an experiment: *Forth's one real weakness is the human burden of an
invisible stack; in an AI era you can keep the language minimal and supply the
missing error-correcting redundancy with a verifier — and keep the whole trust
base small by writing that verifier in the language itself.*

It is realized as a self-hosting stack: a tiny Forth that writes, **verifies**,
and **forges** its own verified code.

| file | what it is |
|---|---|
| `fr.s` | the kernel: a freestanding x86-64 Forth (~3 KB, no libc) in GNU assembler |
| `fr` | the built binary (a REPL reading stdin) |
| `prelude.fr` | fr's standard library — everything derivable, written *in fr* |
| `anvil.fr` | a stack-effect **verifier**, written *in fr* |
| `forge.fr` | generate→check→repair loop, written *in fr* (synthesizes verified words) |
| `term.fr` | terminal control *in fr*: ANSI escapes + termios raw mode (the TUI substrate) |
| `ember` | a Python/curses TUI that `ptrace`s the real `fr` and animates it |
| `build.sh` | `as` + `ld` → `fr` |
| `anvil-reference.py`, `forge-reference.py` | Python specs for the fr versions |
| `ember.fr` | a feature spec/TODO for an eventual self-hosted ember |

Naming map: **forthright** (project) · **fr** (the language) · **anvil** (verifier)
· **forge** (synthesizer) · **ember** (explorer).

---

## 2. Quick start

```sh
./build.sh                              # assemble + link -> ./fr
echo '2 3 + .' | ./fr                   # -> 5   (RPN: push 2, push 3, add, print)
```

`fr` reads Forth from stdin until EOF. The **kernel** alone knows only primitives;
load `prelude.fr` for the full vocabulary by concatenating sources:

```sh
( cat prelude.fr; echo ': abs dup 0 < if negate then ;  -7 abs .' ) | ./fr   # -> 7
( cat prelude.fr anvil.fr; echo 'def sq ( n -- n ) dup * ;' ) | ./fr          # anvil: sq ok
( cat prelude.fr anvil.fr forge.fr; echo forge ) | ./fr                       # synthesize
./ember                                  # the TUI (loads the prelude itself)
```

The layering rule: **prelude.fr** needs the kernel; **anvil.fr** needs the prelude;
**forge.fr** needs both. Always `cat` them in that order before your program.

---

## 3. The fr language

**It's RPN on a stack.** `2 3 +` means push 2, push 3, replace them with 5. A
program is a stream of whitespace-separated *words* (and numbers). A number pushes
itself (negatives included: `-5`). An unknown token prints `token ?`.

**Define words with `: name … ;`**. The body runs when you type `name`:
```
: square  dup * ;        \ ( n -- n*n ):  dup the top, multiply
5 square .               \ -> 25
```
Stack-effect comments `( before -- after )` are conventional documentation (and
`( … )` is also a real comment). `\` comments to end of line. Both need a space
after them (`\ note`, `( note )`) — they are parsed as words.

**Conventions and quirks (read these — they bite):**
- **Truth is `-1`** (all bits set) for true, `0` for false. `= < > 0=` return these.
- **`.` prints a number followed by a NEWLINE.** `u.` (unsigned) and `.n` (signed)
  print with no newline — use those for inline/formatted output.
- **Case-sensitive.** `dup` works; `DUP` is unknown.
- **No string literals** (`s"`/`."`). Print text by emitting chars: `[char] A emit`.
- **Division is signed** (`/ mod`); dividing by zero faults (SIGFPE).
- **A token cannot span an input refill.** The input buffer is 64 KB, so whole
  source files load fine, but this is why `( cat …)` is used rather than huge inputs.
- The prelude must be loaded for `over rot 1+ negate cr …` (see word table).

### Word reference

**Kernel** (available in raw `./fr`):

| group | words (stack effect) |
|---|---|
| stack | `dup (a-aa)` `drop (a-)` `swap (ab-ba)` |
| return stack | `>r (x-)` `r> (-x)` `r@ (-x)` — push/pop/copy to the return stack; **must balance within a word** |
| memory | `@ (a-x)` `! (x a-)` `c@ (a-b)` `c! (b a-)` `here (-a)` `allot (n-)` |
| arithmetic | `+ - * / mod` (signed) |
| compare / logic | `= (ab-f)` `< (ab-f)` `and or` (bitwise) |
| output | `. (n-)` signed+newline · `emit (c-)` one byte · `type (a n-)` a string |
| parse | `word (-a n)` next token · `find (a n - cfa\|0)` · `number (a n - n f)` · `s= (a1 n1 a2 n2 - f)` · `[char]` (immediate: compile next char) |
| reflection | `latest (-hdr)` newest dict entry · `sys (-addr)` engine-CFA table · `execute (cfa-)` run a word · `sp@ (-a)` top-item addr · `sp0 (-a)` empty-stack base |
| system | `syscall3 (a1 a2 a3 n - ret)` raw Linux syscall, ≤3 args (read/write/ioctl/getpid…); `n` is the syscall number |
| define | `: ;` colon defs · `variable name` (name pushes its cell addr) · `n constant name` (name pushes n) |
| control (immediate) | `if … else … then` · `begin … until` · `begin … while … repeat` |
| comments (immediate) | `\` to EOL · `( … )` |
| misc | `bye` exit(0) · `exit` early return from a definition |

**Prelude** (`prelude.fr`, written in fr):

| group | words |
|---|---|
| stack | `over (ab-aba)` `rot (abc-bca)` `nip (ab-b)` `2dup (ab-abab)` `2drop (ab-)` |
| arithmetic | `negate (n--n)` `1+` `1-` `cells (n-n*8)` `cell+ (a-a+8)` |
| compare | `> (ab-f)` `0= (n-f)` |
| memory/parse | `, (x-)` append a cell at `here` · `char (-c)` first char of next token |
| output | `cr` newline · `space` · `u. (u-)` unsigned no-newline · `.n (n-)` signed no-newline |
| input | `key (-c)` read one byte from stdin (via `syscall3`; for an interactive tty) |
| reflection | `' (-cfa)` tick: next word's CFA · `see` disassemble next word · `.cfaname (cfa-)` · constants `'docol 'lit 'exit 'branch '0branch` |
| stack tools | `depth (-n)` · `.s` print the stack (non-destructive) · `trace` step a word on the live stack, printing each step (the self-hosted analog of ember's step view; straight-line + literals only) |
| demo | `square` |

**Terminal control** (`term.fr`, written in fr; load after the prelude — `cat prelude.fr term.fr …`):

| group | words |
|---|---|
| ANSI output | `clear` wipe+home · `home` · `at (row col -)` position cursor (1-based) · `sgr (n-)` raw SGR code · `fg (n-)`/`bg (n-)` colour (0–7) · `bold` · `reset` · `hide-cursor`/`show-cursor` |
| raw input | `raw-on`/`raw-off` enter/leave cbreak (clear `ICANON|ECHO` via ioctl) · `term-size (- rows cols)` · pair with prelude's `key (-c)` |
| compose | `paint (row col colour -)` = `at` + `fg` |

Try `see`: `( cat prelude.fr; echo 'see square' ) | ./fr` → `dup * ;`. It walks the
dictionary and the `sys` table to print any word's threaded body.

---

## 4. How the kernel works (to read/modify `fr.s`)

fr is **indirect-threaded code (ITC)** — *not* inlined/native. The four registers
*are* the engine:

- `%rsi` = **IP** (Forth instruction pointer: points at the next CFA in a thread)
- `%rsp` = **data stack** (push/pop directly)
- `%rbp` = **return stack** (separate; grows down)
- `%rax` = **W** (scratch the inner interpreter loads each step)

`NEXT` (the inner interpreter) is the macro `lodsq ; jmp *(%rax)`: load the next
CFA into W, then jump *through* it (double indirection — the CFA points at a
codeword that points at machine code). `docol` runs colon definitions (pushes the
caller's IP, dives into the body); `EXIT` pops it. `_start` points IP at a
`cold_start → QUIT` thread; `QUIT` is itself threaded Forth (`INTERPRET ; BRANCH`
looping forever).

**Dictionary entry layout (packed, no alignment):**
```
[ .quad link ][ .byte len+flags ][ name bytes ][ codeword cell = the CFA ][ body... ]
```
So **`CFA = header + 9 + len`** — `find` relies on this exact arithmetic. High bit
of the len byte (`0x80`) = IMMEDIATE. `var_latest` holds the newest entry; `find`
walks the `link` chain.

**Compile mode:** `:` builds a header via `_create` and sets its codeword to
`docol`, then `var_state`=compile; `INTERPRET` then *compiles* each word's CFA into
the new body (and `LIT,value` for numbers) instead of executing it. `;` (IMMEDIATE)
compiles `EXIT` and leaves compile mode. **Immediate** words (`if`/`;`/`\`/…) run
*during* compilation — that's how control flow is built: they emit `BRANCH`/`ZBRANCH`
cells with placeholder offsets and back-patch them, using the data stack to remember
slots. `variable`/`constant` use codewords `dovar`/`doconst` (siblings of `docol`).

**Non-obvious invariant — helper routines.** `_word`/`_find`/`_number`/`_create`/
`_refill` are reached with `call`/`ret`, but `%rsp` *is* the data stack — so they
pass everything in registers and never touch the data stack, and they save/restore
`%rsi` around any syscall that uses it (`read`/`write` clobber it).

**Map of `fr.s`** (top to bottom): the `NEXT` macro and `_start`; `docol` /
`dovar` / `doconst` (runtime behaviours); headerless internal words (`EXIT` `LIT`
`BRANCH` `ZBRANCH`); the **dictionary** — chained header+code entries, the bulk of
the file; the outer-interpreter helpers (`_create` `_refill` `_word` `_find`
`_number` `code_INTERPRET`); the `cold_start → QUIT` threaded loop; then
`.rodata` / `.data` (`var_latest` heads the dictionary chain; `systab`) and `.bss`
(stacks, `inbuf`, `dict_space`). To add a word you insert a dictionary entry and
re-thread one link; see §5.

---

## 5. Extending fr

**Golden rule: if a word can be defined in fr, put it in `prelude.fr`, not `fr.s`.**
The kernel stays minimal; the library grows. (Words kept in the kernel anyway:
`s= find number .` — the parse/IO bootstrap — and the irreducible primitives.)

**Add a prelude word:** just write `: name … ;` in `prelude.fr` (after its deps).

**Add a kernel primitive (`fr.s`):**
1. Write the dictionary entry: `h_X: .quad <previous-header>` / `.byte <len>` /
   `.ascii "name"` / `X: .quad code_X` / `code_X: … NEXT`.
2. Re-thread the link chain (its successor's `.quad` must point to it) and update
   the `var_latest:` initializer to the newest header.
3. No `.align` (it breaks the `+9+len` CFA math). Immediate? use `.byte 0x80|len`.
   Internal (not typed, like `LIT`)? omit the header.
4. Control-flow / word-creating words follow the immediate-word and `_create`
   patterns already in the file.

---

## 6. anvil and forge (the verifier and the loop)

**anvil** (`anvil.fr`) is a stack-effect verifier written in fr. Load it after the
prelude. It keeps a table mapping a word → `(consumes, produces)` and runs an
abstract stack simulation (`hgt` height, `lo` low-water mark; inputs = `-lo`,
outputs = `inputs + hgt`).
- `check{ words… }` — infer a straight-line phrase's effect, printed `( x.. -- y.. )`.
- `def name ( in -- out ) body ;` — infer a definition's effect, register it (so
  later words compose), and flag any mismatch with the declared signature (`BAD`).
- `if/else/then` are analyzed: both arms must leave the same net effect or it's
  flagged `br!`.
- `check-body ( body -- in out )` — verify a *compiled* body (walk it by CFA). This
  is what `forge` calls.
Key idea: anvil checks **shape (consistency)**, not **intent**. A balanced stack ≠ a
correct program — see forge.

**forge** (`forge.fr`) is the thesis end to end. A breadth-first generator builds
candidate threaded bodies; `check-body` (anvil) gates them by stack effect; the
shape-valid ones are `execute`d on examples to check intent; the first that passes
both is forged. Run `( cat prelude.fr anvil.fr forge.fr; echo forge ) | ./fr`:
```
  dup + ?      ← anvil approved the shape ( n -- n ), but value test failed
  dup * <=     ← forged: right shape AND 5→25, 3→9
```
The generator stands in for an AI; the point is that nothing is accepted unless
**Forth-checking-Forth** approves it first.

---

## 7. Verifying changes (always run after editing)

**One command: `./test.sh`** — builds and runs every check below, printing
PASS/FAIL (exit non-zero on any failure). Run it first; the individual commands
below are for when you need to look closely at one. (`DECISIONS.md` records *why*
the design is the way it is — read it before changing something that looks odd.)

```sh
./build.sh                                   # must assemble + link cleanly
echo '5 square .' | ./fr                      # (kernel-only smoke test, e.g. dup *)
./ember --selftest                            # Python model of the engine
./ember --native-selftest                     # drives the REAL ./fr under ptrace
( cat prelude.fr anvil.fr; echo 'def bad ( a b -- c ) + + ;' ) | ./fr   # -> BAD
( cat prelude.fr anvil.fr forge.fr; echo forge ) | ./fr                 # -> forges dup *
python3 anvil-reference.py --selftest         # the Python spec still agrees
```
If you change `fr.s`, the ember `--native-selftest` is the best end-to-end check
(it defines words and reads the live dictionary out of the real process). `ember`
reads the binary's symbols, so **keep `fr` unstripped** (`build.sh` does).

---

## 8. A 60-second worked example

```sh
( cat prelude.fr anvil.fr; cat <<'EOF'
: avg ( a b -- c )  + 2 / ;      \ compile a runnable word
6 10 avg .                        \ run it                            -> 8
def avg ( a b -- c )  + 2 / ;     \ anvil checks the declared effect  -> avg ( xx -- y )  ok
see avg                            \ disassemble the compiled word     -> + 2 / ;
EOF
) | ./fr
```
The subtlety: `:` compiles a *runnable* word (so `6 10 avg .` and `see avg` work),
while `def` is anvil *analyzing* the same source against its declared signature — it
does not itself compile a runnable word. They coexist (you write the body twice), or
use `forge`, which builds a real body and both checks and runs it.

Known anvil limitations to be aware of: it is sound for straight-line + `if/else/then`
code; `def` infers and checks the declared signature but (unlike `check{`) does not
print a count of *unknown* words in the body — so make sure body words are in anvil's
effect table (extend the `prim` table in `anvil.fr` if you add primitives, as was just
done for `/` and `mod`).

---

## 9. State of the project

Built and working, all self-hosted where it counts: the kernel, the prelude (with a
self-hosted disassembler `see`), the verifier `anvil`, and the synthesis loop
`forge` — fr writing, verifying, and forging its own code. `ember` (the visual
explorer) stays in Python because it needs `ptrace` and raw-tty input that fr has no
primitives for; `ember.fr` tracks what a self-hosted version would need.

Open directions if continuing: more `forge` targets / a smarter generator; pushing
`s=`/`find`/`number` into the prelude for an even smaller kernel; allowing control
flow inside forged candidates (anvil already does branch analysis); or a robust
`_word` that spans input refills. Commit history (`git log --oneline`) is the
step-by-step narrative.
