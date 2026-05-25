# forthright — roadmap & open ideas

`GUIDE.md` teaches what *is*. This is what *could be* — opinionated, grounded in
the code, written while the whole project is fresh in mind. Read it as "here's
where I'd push next and why," not a contract.

## Where we are

The thesis is **proven in miniature**: an ITC Forth kernel, a standard
library written in itself, a static analyzer (`anvil`) written in fr, and a
generate→check→repair loop (`forge`) that synthesizes verified words — all
self-hosting. The *explorer* is self-hosted too now: `syscall6` opened the OS to fr, so
`ptrace.fr` + `ember.fr` (a visual stepper driving the **real** engine under ptrace) run on
fr alone. There's
now a real **module system** (`include`, load-once) and a **`lib/` standard library**
(math, string, fmt, random, term, key, draw, tui, time, io) on a few new kernel primitives
(`include`, `s"`/`."` string literals, `cmove fill xor lshift rshift`), so building
TUI apps in fr is ergonomic (`./fr app.fr`). What's *not* done is making the loop
**real** (a true AI generator), **deep** (verification beyond stack shape), or
**complete** (fr building its own kernel). Those are the three arcs below.

## Principles to keep (don't break these)

- **The kernel holds only irreducible primitives.** The rule *"if a word can be written in
  fr, it goes in `prelude.fr`, not the kernel"* keeps the bootstrap clean — when tempted to
  add a primitive, ask whether it's truly irreducible (the parse/compile/IO bootstrap +
  syscalls are; the rest isn't).
- **Keep the tools specified.** `anvil`/`forge` carry written specs (`anvil-spec.md`,
  `forge-spec.md`) — keep those in sync as the tools grow, so the algorithm stays readable
  outside the fr source.
- **Verification is the point, not the generator.** Whatever proposes code (a dumb
  search, an LLM), the guarantee comes from `anvil`. Never let the generator's
  output be trusted without the gate.
- **Self-hosting over performance.** ITC is slow; that's fine here — keep everything in fr
  rather than reaching for native compilation.

## Three arcs

### A. Make the loop real — an actual AI generator (highest payoff, most demo-able)

`forge`'s generator is a breadth-first search standing in for an AI. Replace it
with a real LLM and the project *literally is* its thesis: an AI writes Forth, a
50-line Forth verifier gates it, failures feed back as repair prompts, and only
anvil-approved code ships.

- Easiest path: a small host-language driver (following `forge-spec.md`) that calls an LLM
  for candidates, feeds each through `fr`+`anvil`, and on `BAD`/`br!` sends anvil's verdict
  back as a repair instruction. Keep `anvil.fr` (in fr) as the gate untouched. (Such a driver
  would re-introduce one script — fine, since it's the *generator*, not the verified artifact.)
- The striking part to show: the *verdict-driven repair*. Print the dialogue —
  proposal, anvil's exact complaint, the fix — so you can watch the verifier teach
  the generator. That's the thesis as a live conversation.
- Stretch: a richer spec language than examples — let the human state a property
  (`( a b -- a+b )` plus laws), and let anvil + tests gate against it.

### B. Make the verifier deeper — beyond stack shape

anvil checks *shape* (arity), soundly, including `if/else/then`, loops, the return
stack, and recursion. The frontier is checking *more*, each step making "trust
generated code" stronger:

- ~~**Close the known gaps.**~~ **DONE** — `def` now flags unknown body words *by name*
  (`? foo bar`), and the `prim` table mirrors the kernel + prelude (shufflers, arithmetic,
  comparisons, memory, return-stack, loop helpers, i/o).
- ~~**Loops and recursion.**~~ **DONE** — `begin/until`, `begin/while/repeat`, and counted
  `do/loop` are checked (the loop body must be stack-neutral per iteration → `br!`); control
  structures must balance (`ctl!`); the return stack must balance (`>r`/`r>`/`r@` → `r!`);
  and a *declared* word may recurse (the self-call assumes the declaration). (`?do`/`+loop`/
  `leave` aren't in the kernel yet, so not in anvil either.)
- ~~**Types, not just counts.**~~ **DONE (first cut)** — a conservative cell-kind layer
  (number / address / flag / unknown) rides on the height sim: `@ ! c@ c!` require an
  address, `* / mod` reject address/flag operands, `+` rejects address+address (`ty!`).
  Kinds flow from literals, comparisons, and kind-named decl inputs (`addr`/`n`/`flag`);
  *unknown is absorbing*, so there are essentially no false positives. Next refinements:
  infer address-ness for `variable`/`here`/`'` (currently unknown), track flag-ness into
  `if`/`until` conditions, and let the declaration name *output* kinds too.
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
  engine under ptrace. It forks a child, single-steps it, and lays out the panels:
  `code` (the word's body, one cell per row, live cell highlighted / executed
  dimmed, scrolls), `data` (the peeked stack, top first), `call` (the inferred path), `dict`
  (the live dictionary — its own term/ptrace/ember plumbing filtered out via the `prelude-top`/
  `ember-top` markers, so only kernel+prelude+user words show), an `out` status line, an input
  box, and a key row. Keys: `s`/space step, **`a` autoplay** (`+`/`-` speed, clocked by a
  `key` read timeout via VMIN/VTIME), `r` run-to-end, `e` the live edit line (**a REPL** — each
  line is compiled with the resting stack re-pushed in front and stepped; at the top-level EXIT
  it snapshots the stack and rests instead of exiting, so `5 5 5 +` rests at `10 5` and `3 *`
  continues to `30 5`), `q`/`Esc` quit. It runs on fr alone (`./ember-fr` is a one-line shell exec); the
  kernel also **loads source from argv** + reassembles tokens/comments across refills. (An
  earlier *simulator* ember.fr was dropped once the real-engine version existed; the prelude's
  `trace` is the lightweight model.) It also captures output — the **OUTPUT panel — DONE**:
  `launch` points the child's fd 1/2 at an O_NONBLOCK pipe and the parent drains it non-blocking
  each frame into a scrollback buffer, so a word that prints shows up in the panel instead of
  corrupting the TUI. (Both pipe ends are O_NONBLOCK on purpose: a blocking write end would
  deadlock the single-stepper.) Left to close (polish):
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
it in fr; `anvil` — Forth you have read — rejects the draft with a precise reason; the AI
repairs; anvil accepts; and you ship a word you trust *not because you trust the AI, but
because you trust the verifier*. Everything in the loop except the AI is fr.
That's the whole bet, and it's within reach from here.

## Small, well-scoped TODOs (grab one)

- ~~`def` should report unknown body words (mirror `check{`'s `?` path)~~ — **DONE**
  (`? foo bar`, by name; plus loop/control/return-stack checks + recursion).      `anvil.fr`
- ~~Robust `_word`: span input refills~~ — **DONE** (copies to `wordbuf`; files load via argv).
- `forge`: allow `if/else/then` in candidates (anvil already does branch analysis). `forge.fr`
- `forge`: take the target effect + examples as input instead of hardcoding square. `forge.fr`
- Push `s= find number` to the prelude; shrink the kernel.            `fr.s` / `prelude.fr`
- Build an LLM generator driver (per `forge-spec.md`) gated by `anvil`; print the repair dialogue.
- ~~`do … loop` (counted loops) as immediate words~~ — **DONE** (`do loop i j unloop`;
  `?do`/`+loop`/`leave` still TODO). It cut tetris from 13 hand-rolled `begin` loops + 10
  counter variables down to clean `N 0 do … i … loop`.
- `create … does>` — so data structures (e.g. a menu's item array) build cleanly.  `fr.s`
- Interpret-mode `s"` uses one transient buffer (two in a phrase alias) — rotate a
  small set of buffers so `s" a" s" b" s=` works interpreted, not just compiled.    `fr.s`
- `include` paths resolve from the CWD, not the including file — track the current
  file's dir for relative includes (so `lib/` files could `include term.fr`).        `fr.s`
- Grow `lib/tui.fr`: scrolling lists, multi-field forms, a draw-into-buffer screen.  `lib/tui.fr`
- The commit history (`git log --oneline`) is the build narrative if you want the path here.
