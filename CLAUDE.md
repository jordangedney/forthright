# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**forthright** is an experiment toward an "AI writes it, a verifier checks it, ship tiny
auditable Forth" pipeline (see README.md for the thesis). Concretely the repo currently
holds two pieces:

- **`fr`** — a freestanding indirect-threaded-code (ITC) Forth for x86-64 Linux, written
  as a single GNU-assembler file `fr.s`. No libc, no runtime: raw syscalls + threaded code.
- **`ember`** — a Python/curses TUI that single-steps the engine and visualizes it. By
  default it drives the *real* `fr` binary under `ptrace`; `--python` uses an equivalent
  pure-Python model.

Naming map: **forthright** (project) · **fr** (the Forth) · **ember** (the explorer) ·
**anvil** (reserved name for the not-yet-built verifier).

## Commands

```sh
./build.sh                 # assemble + link fr  (as --gstabs ; ld) -> ./fr
echo '3 4 + 5 * .' | ./fr  # fr is a REPL: reads Forth from stdin until EOF
./fr                       # interactive; Ctrl-D / `bye` to quit

./ember                    # TUI driving the real ./fr via ptrace (Linux; needs ~76x20)
./ember --python           # TUI on the pure-Python model instead
./ember --selftest         # headless check of the Python model  (the "test suite")
./ember --native-selftest  # headless check that drives ./fr under ptrace
```

There is no test framework; correctness is asserted by the two `--selftest` modes. After
changing `fr.s`, rebuild and run both: `./build.sh && ./ember --selftest >/dev/null &&
./ember --native-selftest | tail -1` (expect `NATIVE PASS`). The native backend reads
`fr`'s ELF symbol table, so **keep the binary unstripped** (`build.sh` already does).

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
and compiles `EXIT` then leaves compile mode.

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
