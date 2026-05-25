# forge — specification

The reference description of the **generate → check → repair** loop — the forthright
thesis in miniature. `forge.fr` is the implementation; this file is the readable spec —
keep them in sync.

## The loop

1. A **generator** proposes candidate definitions (a word body).
2. The **self-hosted verifier `anvil`** checks each candidate's stack effect against the
   declared `( in -- out )`. Anything anvil rejects (`BAD` shape, `br!` branch mismatch,
   `?` unknown) is discarded **without ever being run**.
3. Shape-valid candidates are **run on examples** to confirm they compute the right value.
4. The first candidate that passes **both** gates is "forged" — printed as a verified
   definition.

The generator is a **breadth-first search over a small word pool** — a deliberate stand-in
for an AI writing Forth. The point is not the generator; it's that **nothing is accepted
unless anvil (Forth checking Forth) approves the shape first**, and that the two gates check
different things:

- **anvil checks *shape*** (arity / stack balance) — cheap, sound, no execution.
- **examples check *intent*** (the value) — a candidate can pass anvil yet compute the
  wrong thing, and you watch that happen (e.g. `dup +` has the right shape for `sq` but
  the wrong value).

## Generator vocabulary

A pool of real fr/prelude words, e.g. `dup drop swap over + - * 1+ 1- negate`, enumerated
breadth-first up to some max length (`itertools.product(pool, repeat=length)` for
`length = 1..maxlen`). Each candidate body is a space-joined combo.

## Gates, concretely

- **shape gate** — define the candidate as `def cand ( decl ) <body> ;` under `anvil` and
  read its verdict: `ok` (accept), `BAD` / `br!` / `?` (reject).
- **intent gate** — define `: cand <body> ;` for real and run each example
  `<args> cand .`, comparing the printed result to the expected value. All examples must
  match.

## Demo synthesis tasks (test vectors)

| name | effect | examples | forged |
|---|---|---|---|
| `add` | `( 2 -- 1 )` | `3 4 → 7`, `10 5 → 15` | `+` |
| `sq`  | `( 1 -- 1 )` | `3 → 9`, `4 → 16`, `5 → 25` | `dup *` |
| `lin` | `( 1 -- 1 )` | `1 → 3`, `2 → 5`, `3 → 7` | a 2n+1 body (e.g. `dup + 1+`) |

Each candidate costs a real `fr` run for the anvil check (plus a few for value tests), so
this is a real loop against the real, self-hosted verifier — not a model. The striking
output is the *verdict-driven* search: anvil silently rejects most shapes, and among the
shape-valid ones you see which compute the right value and which don't.
