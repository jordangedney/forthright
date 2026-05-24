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
**Why:** `ember` reads `fr`'s stdout and splits output on newlines to fill its
panel; a space-terminated `.` would make numbers never flush. So `.` keeps the
newline and the prelude adds `u.`/`.n` (no-newline) for inline/formatted output.
If you "fix" `.` to be standard, you break ember's output parsing.

### Forth truth is `-1` (all bits), false is `0`
Standard Forth convention. **Why it matters here:** flags are bitwise-combinable
(`and`/`or`), and `if`/`0branch` test for zero. Comparison words (`= < > 0=`) return
`-1`/`0` accordingly.

### Dictionary entries are packed, no alignment
`[ link | len+flags | name | codeword(CFA) | body ]`, so `CFA = header + 9 + len`.
**Why:** simplicity, and `find`/`see`/`>cfa` all rely on that exact arithmetic.
**Do not** add `.align` between name and codeword — it silently breaks every CFA
computation. High bit of `len` is the IMMEDIATE flag (`0x80`).

### Input buffer is 64 KB (a band-aid, not a fix)
`_word` returns a pointer into `inbuf` and **can't carry a token across a `read`**.
A token split at a buffer boundary becomes garbage. **Why 64 KB:** whole source
files then arrive in one `read`, so it never happens in practice. The real fix
(copy tokens into a holding buffer so they span refills) is deferred — see ROADMAP.

### Helper routines pass everything in registers
`_word`/`_find`/`_number`/`_create`/`_refill` use `call`/`ret`, but `%rsp` *is* the
data stack — so they never touch it (the return address lives there transiently)
and they save/restore `%rsi` (the IP) around syscalls that clobber it. Break this
and the data stack corrupts subtly. This is the easiest kernel invariant to violate.

### ember stays in Python
The visual explorer needs `ptrace` (single-step the real fr, read `/proc/pid/mem`)
and raw-tty input — syscalls fr has no primitives for. **Why not self-host:** the
*introspection* half (decode a definition) *is* self-hosted as `see`; the ptrace
backend and TUI input are out of reach until a generic `syscall` primitive exists
(ROADMAP). `ember.fr` tracks what a self-hosted version would need.

### ember runs fr at native speed via a breakpoint, single-steps only for `s`
ember bootstraps the prelude and runs `r` by setting an `int3` at the `read`
syscall and `PTRACE_CONT`-ing (not single-stepping). **Why:** single-stepping the
prelude load would take seconds; the breakpoint makes it ~0.1 s. Single-step is
reserved for the interactive `s` key, where you actually want to watch each cell.

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
