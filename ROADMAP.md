# forthright — roadmap & open ideas

`GUIDE.md` teaches what *is*. This is what *could be* — opinionated, grounded in
the code, written while the whole project is fresh in mind. Read it as "here's
where I'd push next and why," not a contract.

## Where we are

The thesis is **proven in miniature**: a ~3 KB auditable Forth kernel, a standard
library written in itself, a stack-effect verifier (`anvil`) written in fr, and a
generate→check→repair loop (`forge`) that synthesizes verified words — all
self-hosting, trust base small enough to read in a sitting. The *explorer* is
self-hosted too now: `syscall6` opened the OS to fr, so `ember.fr` (simulated
stepping), `ptrace.fr`, and `live.fr` (the visual stepper driving the **real** engine
under ptrace) all run with no Python. What's *not* done is making the loop **real** (a
true AI generator), **deep** (verification beyond stack shape), or **complete** (fr
building its own kernel). Those are the three arcs below.

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
  `term.fr` (ANSI + termios cbreak via `ioctl`), **`ember.fr` — DONE** (a visual stepper in
  fr that steps into colon words, follows control flow, runs with no Python), and **`ptrace.fr`
  — DONE** (fr forks a child, `PTRACE_TRACEME`s it, single-steps it, reads RIP). The kernel
  also **loads source from argv** + reassembles tokens/comments across refills. ember.fr is at
  parity with the Python ember's *core*; what's left to close the gap:
  - **Self-host the ptrace backend — DONE.** `ptrace.fr`'s `watch` forks the running fr,
    single-steps to each `jmp *(%rax)` boundary, and decodes `%rax` via the shared dictionary;
    **`live.fr`** wraps that in a term.fr TUI with `ember.fr`'s exact `call`/`code`/`data` view
    — the visual stepper driving the *real* engine. It tracks the live call nesting by spotting
    `docol`-entries/`EXIT`s in the dispatch stream (`call` shows `cube > square`, `code` is the
    current word's body with the live cell highlit), and reads the data stack with `peekdata`.
    So the Python `ember` is now capability-redundant; what it still has is *polish*, not power:
  - **Polish toward the Python look.** Nord 256-colour palette, a dictionary panel, a live
    edit line (type/define words in-TUI), buffered redraws (one `write` per frame, not per byte).
  - **Buffer redraws.** `term.fr` emits one `write(2)` per byte; a frame is many tiny
    syscalls (flicker). Render into a string buffer and `type` it once. Wants `s"`-style
    string building (or just a scratch buffer + `c!` cursor) — a good prelude addition.

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
- The commit history (`git log --oneline`) is the build narrative if you want the path here.
