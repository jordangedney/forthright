# anvil — specification

The reference description of what `anvil.fr` (the self-hosted stack-effect verifier)
computes. This is the readable spec; `anvil.fr` is the implementation. (It began life
as `anvil-reference.py`; the Python was retired once `anvil.fr` matched it — this file
preserves the *intent*, which is the part worth keeping.)

## What it does

The project thesis: Forth lacks error-correcting redundancy, so anvil supplies it
*outside* the shipped artifact. Reading fr source, by **abstract stack simulation** it
does four things a bare Forth wouldn't until (maybe) crashing at runtime:

1. **infer** each colon word's stack effect `( in -- out )`;
2. **check** that inference against the declared `( … -- … )` comment, if given — the
   declaration is the redundancy, the check is the payoff;
3. **flag unknown words** (typos / undefined);
4. **flag top-level code that underflows** the stack.

It is **sound for straight-line (branchless) code**. For `if/else/then`, the rule is:
*both arms of a branch must have the same stack effect, or the effect is undefined* —
that's where the branch machinery slots in (anvil.fr implements this; the `br!` verdict
is its "arms disagree" error).

## The core: abstract stack simulation

Simulate a token sequence on an abstract stack, tracking only **height** relative to the
entry top (it may go negative — consuming below what the word was given) and the
**lowest** height reached:

```
height = 0          # relative to the entry top
low    = 0          # most-negative height seen
for tok in seq:
    if tok is an integer literal:  cons, prod = 0, 1     # a number just pushes
    elif tok is a known word:      cons, prod = effect[tok]
    else:                          record tok as unknown; continue
    height -= cons
    low = min(low, height)        # a new low while height<0 is an underflow point
    height += prod

inputs  = -low                    # cells the phrase consumes below entry
outputs = inputs + height         # cells left above entry at the end
```

So a word's inferred effect is `( inputs -- outputs )`. A **declaration** `( a b -- c )`
parses to `(2, 1)` (count tokens on each side of `--`); inference must equal it or it's a
**MISMATCH**. Top-level code is analyzed the same way on an initially empty stack: any
point where `height < 0` is an **underflow** (the first such token + its deficit is the
error).

Primitive effects `name -> (consumes, produces)` mirror the kernel + prelude:
`dup (1,2) drop (1,0) swap (2,2) over (2,3) rot (3,3)`, the binops `+ - * / mod (2,1)`,
`negate = < > (… ,1)`, `. (1,0)`, `.s/bye (0,0)`, and the predefined `square (1,1)`.
`def` registers each checked word's effect so later words compose on top of it.

## Expected behavior (test vectors)

| source | result |
|---|---|
| `: sq ( n -- n ) dup * ;` | ok — inferred `( x -- y )` matches |
| `: bad ( n -- n ) dup ;` | **FAIL** — inferred `(1→2)` ≠ declared `(1→1)` |
| `: cube dup dup * * ;` | ok — no decl, just inferred `( x -- y )` |
| `: quad ( n -- n ) dup + ;` then `: q2 quad quad ;` | ok — words compose |
| `: x foo bar ;` | **FAIL** — unknown words `foo bar` |
| `: double 2 * ;` then `5 double .` | ok — top level balances |
| `dup` (top level) | **FAIL** — underflow (needs 1 more cell) |
| `: drop2 ( a b -- ) drop drop ;` then `5 drop2` | **FAIL** — needs 2, has 1 |

## The boundary (why forge exists)

anvil proves **shape** (the stack effect is what's claimed), never **value**: `dup +`
checks fine as `( n -- n )` but doesn't square. Intent is checked by *running examples* —
that's `forge`'s job (see `forge-spec.md`). Don't expect anvil alone to certify correctness.
