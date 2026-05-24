# forthright — roadmap & open ideas

`GUIDE.md` teaches what *is*. This is what *could be* — opinionated, grounded in
the code, written while the whole project is fresh in mind. Read it as "here's
where I'd push next and why," not a contract.

## Where we are

The thesis is **proven in miniature**: a ~3 KB auditable Forth kernel, a standard
library written in itself, a stack-effect verifier (`anvil`) written in fr, and a
generate→check→repair loop (`forge`) that synthesizes verified words — all
self-hosting, trust base small enough to read in a sitting. The *explorer* is
self-hosted too now: `syscall6` opened the OS to fr, so `ptrace.fr` + `ember.fr` (a
visual stepper driving the **real** engine under ptrace) run with no Python. There's
now a real **module system** (`include`, load-once) and a **`lib/` standard library**
(math, string, fmt, term, key, draw, tui, time, io) on a few new kernel primitives
(`include`, `s"`/`."` string literals, `cmove fill xor lshift rshift`), so building
TUI apps in fr is ergonomic (`./fr app.fr`). What's *not* done is making the loop
**real** (a true AI generator), **deep** (verification beyond stack shape), or
**complete** (fr building its own kernel). Those are the three arcs below.

## Principles to keep (don't break these)

- **The kernel is the trust base. Guard its size.** Every byte of `fr.s` is
  something a human must read to trust the whole stack. The rule *"if a word can be
  written in fr, it goes in `prelude.fr`, not the kernel"* is the whole game. When
  tempted to add a primitive, ask whether it's truly irreducible.
- **Keep the reference-spec pattern.** The self-hosted tools that began as Python
  specs keep them (`anvil-reference.py`, `forge-reference.py`) as cross-checks. (`ember.fr`
  has graduated from spec to a real, runnable stepper; the Python `ember` is its richer
  ptrace-backed cousin, not its spec.) Specs are how the fr versions stay honest.
- **Verification is the point, not the generator.** Whatever proposes code (a dumb
  search, an LLM), the guarantee comes from `anvil`. Never let the generator's
  output be trusted without the gate.
- **Auditability over performance.** ITC is slow; that's a feature here. Don't
  reach for native compilation unless minimalism/auditability is preserved.

## Three arcs

### A. Make the loop real — an actual AI generator (highest payoff, most demo-able)

`forge`'s generator is a breadth-first search standing in for an AI. Replace it
with a real LLM and the project *literally is* its thesis: an AI writes Forth, a
50-line Forth verifier gates it, failures feed back as repair prompts, and only
anvil-approved code ships.

- Easiest path: extend `forge-reference.py` (the host-language pipeline — on-thesis
  there) to call an LLM for candidates, feed each through `fr`+`anvil`, and on
  `BAD`/`br!` send anvil's verdict back as a repair instruction. Keep `anvil.fr`
  (in fr) as the gate untouched.
- The striking part to show: the *verdict-driven repair*. Print the dialogue —
  proposal, anvil's exact complaint, the fix — so you can watch the verifier teach
  the generator. That's the thesis as a live conversation.
- Stretch: a richer spec language than examples — let the human state a property
  (`( a b -- a+b )` plus laws), and let anvil + tests gate against it.

### B. Make the verifier deeper — beyond stack shape

anvil checks *shape* (arity), soundly, including `if/else/then`. The frontier is
checking *more*, each step making "trust generated code" stronger:

- **Close the known gaps first.** `def` silently ignores unknown body words (only
  `check{` reports them) — make `def` flag them. Keep anvil's `prim` table in sync
  with the kernel/prelude (we just added `/ mod`; audit for others).
- **Loops and recursion.** `begin/until`, `begin/while/repeat` in checked bodies
  (the loop body must be stack-neutral per iteration — a clean rule to add to the
  branch machinery). Recursion needs a self-reference effect assumption.
- **Types, not just counts.** Track cell *kinds* (number / address / flag) through
  the simulation, so `@` on a flag or `+` on two addresses is caught. This is where
  a concatenative type system earns its keep.
- **Intent, not just consistency.** anvil proves the stack is balanced, never that
  the value is right (forge shows `dup +` passing shape, failing value). Pull the
  example/property checking *into* anvil so the verifier owns intent too — e.g.
  `anvil` runs a candidate against asserted input→output laws.

### C. Make the kernel disappear into fr — the self-compiling endgame

The deepest "audit the whole thing" dream: fr building its *own* kernel, so the
assembly is a throwaway bootstrap.

- **Near term:** push `s=`, `find`, `number` (and maybe `word`) out of the kernel
  into the prelude — they're derivable from `c@`/loops/compare. Shrinks the trust
  base further; mostly mechanical, gated only by speed.
- **The big one — an assembler in fr.** A word that emits x86-64 machine bytes
  (`,` for code), enough to re-emit the primitives. Then a Forth that compiles its
  own NEXT/docol/primitives — true self-hosting, where the `.s` file is a seed you
  could regenerate. Hard, beautiful, and the natural terminus of "everything in fr."
- A generic **`syscall` primitive** — **DONE** (`syscall6` + `key`), and on top of it
  `term.fr` (ANSI + termios cbreak + box drawing), **`ptrace.fr` — DONE** (fork/ptrace/
  single-step/peek), and **`ember.fr` — DONE**: the self-hosted explorer, a **full-screen,
  responsive** Nord dashboard (`measure` re-reads `term-size` each frame) driving the **real**
  engine under ptrace. It forks a child, single-steps it, and lays out the same panels as the
  Python ember: `code` (the word's body, one cell per row, live cell highlighted / executed
  dimmed, scrolls), `data` (the peeked stack, top first), `call` (the inferred path), `dict`
  (the live dictionary — its own term/ptrace/ember plumbing filtered out via the `prelude-top`/
  `ember-top` markers, so only kernel+prelude+user words show), an `out` status line, an input
  box, and a key row. Keys: `s`/space step, **`a` autoplay** (`+`/`-` speed, clocked by a
  `key` read timeout via VMIN/VTIME), `r` run-to-end, `e` the live edit line (**a REPL** — each
  line is compiled with the resting stack re-pushed in front and stepped; at the top-level EXIT
  it snapshots the stack and rests instead of exiting, so `5 5 5 +` rests at `10 5` and `3 *`
  continues to `30 5`), `q`/`Esc` quit. It runs with no Python (`./ember-fr` is a one-line shell exec); the
  kernel also **loads source from argv** + reassembles tokens/comments across refills. (An
  earlier *simulator* ember.fr was dropped once the real-engine version existed; the prelude's
  `trace` is the lightweight model.) ember.fr now matches the Python ember's panels, keys,
  *and* behavior — including the **OUTPUT panel — DONE**: `launch` points the child's fd 1/2
  at an O_NONBLOCK pipe and the parent drains it non-blocking each frame into a scrollback
  buffer, so a word that prints shows up in the panel instead of corrupting the TUI. (Both
  pipe ends are O_NONBLOCK on purpose: a blocking write end would deadlock the single-stepper.)
  So the self-hosted explorer is at full parity; the Python `ember` is now just a reference UI.
  Left to close (polish, not parity):
  - A perf tweak: coalesce the per-byte `emit` writes into one `type`/frame (flicker is
    already gone via in-place redraw; wants `s"`-style string building or a scratch buffer).

## Cross-cutting: the corpus

The thesis's own answer to "Forth has no training data" was: *mint it*. Use
`forge`/`anvil` to generate-and-verify fr programs at scale — a synthetic corpus of
*known-sound* Forth. It feeds arc A (fine-tune/few-shot a generator on it) and is a
genuinely novel artifact (verified-by-construction training data). Smallest version:
let `forge` enumerate and dump every word it can synthesize for a grid of target
effects.

## North star

A session where you state, in plain terms, what you want a word to do; an AI drafts
it in fr; `anvil` — Forth, ~100 lines, that you have read — rejects the draft with a
precise reason; the AI repairs; anvil accepts; and you ship a word you trust *not
because you trust the AI, but because you trust the verifier and the verifier is
small enough to trust*. Everything in the loop except the AI is fr you can audit.
That's the whole bet, and it's within reach from here.

## Small, well-scoped TODOs (grab one)

- `def` should report unknown body words (mirror `check{`'s `?` path).         `anvil.fr`
- ~~Robust `_word`: span input refills~~ — **DONE** (copies to `wordbuf`; files load via argv).
- `forge`: allow `if/else/then` in candidates (anvil already does branch analysis). `forge.fr`
- `forge`: take the target effect + examples as input instead of hardcoding square. `forge.fr`
- Push `s= find number` to the prelude; shrink the kernel.            `fr.s` / `prelude.fr`
- Wire an LLM generator into `forge-reference.py`; print the repair dialogue. `forge-reference.py`
- `do … loop` (counted loops) as immediate words.                               `fr.s`
- `create … does>` — so data structures (e.g. a menu's item array) build cleanly.  `fr.s`
- Interpret-mode `s"` uses one transient buffer (two in a phrase alias) — rotate a
  small set of buffers so `s" a" s" b" s=` works interpreted, not just compiled.    `fr.s`
- `include` paths resolve from the CWD, not the including file — track the current
  file's dir for relative includes (so `lib/` files could `include term.fr`).        `fr.s`
- Grow `lib/tui.fr`: scrolling lists, multi-field forms, a draw-into-buffer screen.  `lib/tui.fr`
- The commit history (`git log --oneline`) is the build narrative if you want the path here.
