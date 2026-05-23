# forthright

*A Forth pun, and an old word for honest/transparent.* Both meanings are the point.

## The thesis

Forth's only real defect is a **human** one: invisible, non-local stack state with no
names and no error-correcting redundancy, which makes code hard to write, review, and
trust. Everything else about Forth is a virtue — tiny footprint, total control,
trivially implementable, **auditable end to end**.

In the old regime, fixing the human defect meant baking tooling (type checkers, IDEs,
optimizing compilers) *into the language*. That works — see Factor — but it re-adds all
the weight Forth deleted, so you lose the one thing Forth was uniquely good at and end up
a heavyweight language competing on ecosystem, which a niche language can't win.

The AI era unlocks a different move:

> **Keep the language minimal. Push the tooling out of the artifact and into the
> generation loop.**

- An AI generates plain, minimal Forth.
- An external verifier checks it (stack effects, types, intent).
- The AI repairs and re-checks in a loop.
- The artifact you **ship is still tiny, auditable Forth** — no checker, no types, no
  runtime machinery baked in.

The error-correcting redundancy the language lacks is supplied by the *pipeline*, not the
*artifact*. You get minimal-Forth **and** reliability at once — the configuration that was
impossible when a human had to sit in the writing seat.

## Architecture (working names)

- **anvil** — the verifier. The thing generated code gets hammered against until it's
  stack-correct. Stack-effect checking first; richer type/intent checks later. The core
  of the whole bet: anvil is the redundancy Forth doesn't have, living *outside* the
  shipped code.
- *(generator)* — drives the AI generate → check → repair loop against anvil.
- *(corpus)* — generate-and-verify at scale to mint a synthetic training corpus, the one
  credible attack on Forth's "no training data" problem.

## Open questions / known hard parts

- **anvil verifies consistency, not intent.** A balanced stack ≠ a correct program. The
  human still has to confirm the code does what was meant — and Forth is hard to *read*.
  Bridging consistency-checking to intent-checking is the real research risk.
- **Training-data gravity.** Forth has almost no corpus; the corpus tool is the bet
  against this, and it's unproven.
- Which Forth to target (gforth? a custom minimal core?) is undecided.

## The Forth, written for this machine

Rather than target someone else's Forth, forthright writes its own — for the box
it runs on (x86-64, Linux). `fr.s` is a **freestanding** indirect-threaded-code
(ITC) kernel: no libc, no runtime, just raw syscalls and threaded code. The whole
system between source and kernel is one auditable file — which is the thesis made
literal.

Build and run:

    ./build.sh
    ./fr           # prints 25 (5 SQUARE .) then 5 (2 3 + .)

Engine conventions: `%rsi`=IP, `%rsp`=data stack, `%rbp`=return stack, `%rax`=W.
`NEXT` is the inner interpreter; `docol`/`EXIT` drive the return stack; `SQUARE`
is a real colon definition exercising it.

## Status

- [x] Inner interpreter (ITC NEXT, docol/EXIT), data + return stacks
- [x] Primitives: LIT DUP DROP SWAP + * . BYE
- [x] Colon definitions (SQUARE), freestanding static binary (~451 bytes text)
- [ ] Outer interpreter: KEY / WORD / FIND / NUMBER / INTERPRET (a real REPL)
- [ ] Dictionary + `:` `;` defined *in* the language
- [ ] anvil: external stack-effect verifier for generated words
