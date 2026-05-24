# forthright — design decisions

The non-obvious choices and *why* they were made, so a future reader doesn't
relitigate them or accidentally undo them. Short and blunt. (`GUIDE.md` = what is;
`ROADMAP.md` = what's next; this = why it's like this.)

### Indirect-threaded code (ITC), not direct-threaded / subroutine / native
`NEXT` is `lodsq ; jmp *(%rax)` — a double indirection through a codeword.
**Why:** ITC is the smallest and simplest model; the engine fits in a few lines
you can fully read. **Tradeoff:** slowest of the threading models. That's an
accepted cost — the project's value is auditability, not speed. Don't switch to
native compilation unless you preserve "a human can read the whole engine."

### Freestanding: no libc, raw syscalls, static
`fr` links with `ld` alone and talks to the kernel directly (`read`/`write`/
`exit`). **Why:** the whole trust base is then *one assembly file*; nothing
between your source and the OS is unaudited. **Consequence:** we hand-roll I/O,
there's no malloc (the dictionary is a bump region), and errors fault hard
(e.g. `/0` → SIGFPE). All intentional.

### anvil is self-hosted in fr; forge may be external
`anvil.fr` (the verifier) is written *in fr*. `forge`/the generator can live in a
host language. **Why:** the verifier is the *trust anchor* — you trust generated
code because anvil approved it, so anvil must be small and auditable, hence in fr.
The generator is the *pipeline* (the thesis says to externalize it; the "AI" is
external by nature) and can't sneak anything past the in-fr gate regardless of how
big/opaque it is. So self-hosting buys nothing for the generator and everything for
the verifier. (We built `forge.fr` anyway, for purity; `forge-reference.py` remains
the spec.)

### "If a word can be defined in fr, it goes in `prelude.fr`, not `fr.s`"
The kernel keeps only irreducible primitives + the parse/compile/IO bootstrap.
**Why:** every kernel byte is trust-base; the prelude is auditable fr. This is the
single most important rule for keeping the project honest. We pushed `over rot 1+
negate cells …` out via `>r`/`r>`; the next candidates are `s=`/`find`/`number`.

### `s=`, `find`, `number` kept in the kernel (for now)
They're *derivable* in fr but stay in asm. **Why:** they're the parsing bootstrap
the outer interpreter needs, and they're hot. Moving them is a clean future purity
pass (ROADMAP arc C), gated only on accepting the speed hit.

### `.` prints a trailing newline (not the Forth-standard space)
**Why:** the test harness and `ember.fr`'s OUT panel both read `fr`'s stdout and split
on newlines; a space-terminated `.` would make numbers never flush onto their own line.
So `.` keeps the newline and the prelude adds `u.`/`.n` (no-newline) + `lib/fmt.fr` for
inline/formatted output. If you "fix" `.` to be standard, expect output parsing to break.

### Forth truth is `-1` (all bits), false is `0`
Standard Forth convention. **Why it matters here:** flags are bitwise-combinable
(`and`/`or`), and `if`/`0branch` test for zero. Comparison words (`= < > 0=`) return
`-1`/`0` accordingly.

### Dictionary entries are packed, no alignment
`[ link | len+flags | name | codeword(CFA) | body ]`, so `CFA = header + 9 + len`.
**Why:** simplicity, and `find`/`see`/`>cfa` all rely on that exact arithmetic.
**Do not** add `.align` between name and codeword — it silently breaks every CFA
computation. High bit of `len` is the IMMEDIATE flag (`0x80`).

### The input layer reassembles tokens across refills (no more buffer-boundary bug)
`_word` copies each token into a `wordbuf` as it scans, and it (plus the comment words
`\` and `(`) call `_refill` mid-scan when `inbuf` runs out. So a token or comment can
span any number of reads — stdin may arrive in any chunk size (a pipe, a pty, a 1-byte
dribble) without splitting. (`inbuf` stays 64 KB just to keep reads efficient.) **The
sharp edge:** `_refill`'s read uses `%rsi` (the IP, saved/restored) and `syscall`
clobbers `%rcx` — so the mid-token refill `push`/`pop`s `%rcx`, the live token length.
This earlier *was* a band-aid (big buffer, hope tokens don't straddle); the copy makes
it correct.

### fr loads source files from argv, then reads stdin
`./fr a.fr b.fr` loads those files in order and then drops to the stdin REPL.
`_refill` reads from `var_infd`; on EOF, `_next_source` closes it and opens the next
`argv` file (`O_RDONLY`), then finally stdin (once), then signals true EOF. `argc`/`argv`
are grabbed in `_start` before `%rsp` is repurposed as the data stack; a missing file is
skipped (open returns negative → try the next). **Why:** this is what lets the
self-hosted explorer run with **no launcher** — `./fr ember.fr`
loads the library from disk and leaves fd 0 as the real tty, which `raw-on`/`key` need. It also
retires the `cat a.fr b.fr | ./fr` idiom (though that still works). Capped at "files then
stdin" deliberately — no `include`-from-source, no search path; just enough to bootstrap.

### Helper routines pass everything in registers
`_word`/`_find`/`_number`/`_create`/`_refill` use `call`/`ret`, but `%rsp` *is* the
data stack — so they never touch it (the return address lives there transiently)
and they save/restore `%rsi` (the IP) around syscalls that clobber it. Break this
and the data stack corrupts subtly. This is the easiest kernel invariant to violate.

### `syscall6` is the one OS primitive; everything else is a prelude word
The kernel exposes a single generic `syscall6 ( a1 a2 a3 a4 a5 a6 n -- ret )` rather
than per-call words (`read`/`write`/`ioctl`). Args go in `%rdi %rsi %rdx %r10 %r8 %r9`
(arg4 is `%r10`, not the C `%rcx`, which `syscall` clobbers); `%rsi` is the Forth IP,
so arg2 is parked in `%rcx` *before* the call and the IP is saved across it. **Why 6
and not 3:** the original `syscall3` couldn't reach 4+-arg calls — including `ptrace`
— so generalising it is what made fr's own debugger backend possible. `syscall3` now
lives in the *prelude*, derived by passing three zeros, which keeps the kernel to one
syscall word and the common case readable. **Sharp edge:** a wrong syscall number does
a *real* syscall — fr no longer fails safe (e.g. a stray `ptrace` could stop a process).

### term.fr uses cbreak (not full raw) and emits byte-at-a-time
The fr terminal layer clears only `ICANON|ECHO` in `c_lflag` — *cbreak*, not full
raw mode. **Why:** a key-driven explorer wants unbuffered, un-echoed keystrokes but
is happy to keep signals (Ctrl-C) and output post-processing; clearing two bits in
one `c_lflag` cell is also far simpler than zeroing the whole struct + setting
VMIN/VTIME. It reads/writes the 8-byte cell at offset 12 (which spans `c_lflag` +
`c_line` + a few `c_cc` bytes) and only flips bits in the low 32, so the rest round-
trips untouched. **Output is one `write(2)` per byte** (every `emit`). The TUIs stay
flicker-free not by buffering but by **redrawing in place**: `clear` once, then `atclr`
(position + erase-to-end-of-line) each row and overwrite it, so the screen never blanks
mid-frame. Coalescing the per-byte writes into one `type` per frame is a separate,
optional syscall-count optimization (ROADMAP). **What's tested:** `test.sh` checks the
ANSI escapes through a pipe; raw
mode is validated once under a pty (a byte with no newline echoes immediately and
exactly once → `ICANON` and `ECHO` are both off), since `ioctl` needs a real tty.

### one explorer (`ember.fr`), driving the real engine; the simulator was dropped
The ptrace backend was the one piece this doc long called "out of fr's reach" — a claim
that died with `syscall3`. `ptrace`/`fork`/`wait4` are just syscalls, so `ptrace.fr`'s
`watch` is a working **self-hosted NativeVM**: it forks the running fr (the child shares
its memory image, so the parent's dictionary *is* the child's), runs a word in the child,
single-steps it from the parent, and decodes `%rax` at each `jmp *(%rax)` dispatch.
**`ember.fr`** wraps that in a `term.fr` dashboard — `call`/`code`/`data`, with the live
call path inferred from `docol`-entries/`EXIT`s and the data stack read via `peekdata`.
**Why only one explorer now:** there was briefly a second, `ember.fr`-as-*simulator* (it
walked the threaded code itself, from before fr could ptrace). Once the real-engine version
existed, the simulator was redundant *and* less truthful (a model can drift), so it was
deleted; the prelude's `trace` already fills the lightweight no-ptrace "model" niche.
**A subtlety that made the real backend simple:** forking instead of `execve`ing means no
ELF/argv work and a shared dictionary — the parent decodes the child's CFAs and finds the
stack base (`sp0`) for free.

### the Python/curses `ember` prototype was removed
The original explorer was a ~1200-line Python/curses program with two backends: a pure-Python
model of the engine, and a `NativeVM` that ptraced the real `fr` (its own ELF-symbol parser +
`/proc/<pid>/mem` decode). **Why remove it:** once `ember.fr` reached full parity (layout,
autoplay, captured output, the REPL edit line), the Python one demonstrated nothing fr can't
do — and a 1200-line Python TUI quietly contradicts the project's whole "no Python in the loop"
point. Unlike `anvil-reference.py`/`forge-reference.py`, it was a *UI*, not a spec, so there
was nothing to keep it as. We lose one thing: an *independent* ptrace observer that
cross-checked the binary/dictionary layout — judged not worth the weight (the reference specs
plus fr's own `ember-trace`/`watch` exercise the engine, and a layout regression surfaces in
`test.sh --all`). Recoverable from git history if that cross-check is ever wanted back.

### `ember.fr` runs with no launcher; `ember-fr` is a one-line shell exec
`raw-on` does an `ioctl` on fd 0, which fails on a pipe — so `ember.fr` needs a real tty.
But for *interactive* use the **terminal already is that tty**, and the kernel loads the
library from `argv`, so launching is just `./fr ember.fr` —
no Python (`ember-fr` is exactly that one-line `exec`). The Python that *was* `ember-fr`
only existed to pace scripted keystrokes through a pty (a pipe can't — fr's first read
would swallow them); that's purely a *test* concern, now isolated in `ember-pty`. **Why
`q` calls `bye`:** the explorer is a single-shot view (like `htop`), so quitting it quits
fr cleanly. (Re-targeting via the `e` edit line kills the child and forks a fresh one.)
**Spelled-out labels** (`call` `code` `data` via per-char `emit`) predate fr's `s"`/`."`
(added later); `ember.fr` hasn't been migrated to use them yet.

### anvil checks *shape* (consistency), not *intent*
It proves a definition's stack effect is what it claims; it cannot prove the value
is right (`dup +` passes a `( n -- n )` check but doesn't square). **Why noted:**
this is the deliberate boundary — `forge` adds example/value testing on top to
cover intent. Don't expect anvil alone to certify correctness.

### Names
`forthright` (Forth + "honest/transparent"), and a blacksmith metaphor for the
tools: **anvil** (the work is hammered against it = verified), **forge** (where
verified words are made), **ember** (the live, glowing execution you watch). Forth
source files use the `.fr` extension; the kernel is `fr.s` (GNU assembler).
