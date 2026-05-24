# anvil — specification

The reference description of what `anvil.fr` (the self-hosted stack-effect verifier)
computes. This is the readable spec; `anvil.fr` is the implementation. (It began life
as `anvil-reference.py`; the Python was retired once `anvil.fr` matched it — this file
preserves the *intent*, which is the part worth keeping.)

## What it does

The project thesis: Forth lacks error-correcting redundancy, so anvil supplies it
*outside* the shipped artifact. Reading fr source, by **abstract stack simulation** it
does several things a bare Forth wouldn't until (maybe) crashing at runtime:

1. **infer** each colon word's stack effect `( in -- out )`;
2. **check** that inference against the declared `( … -- … )` comment, if given — the
   declaration is the redundancy, the check is the payoff (verdict `BAD`);
3. **flag unknown words** (typos / undefined), *by name* (verdict `? foo bar`);
4. **check branches** — `if/else/then`: both arms must have the same stack effect
   (verdict `br!`);
5. **check loops** — `begin/until`, `begin/while/repeat`, and counted `do/loop`: the loop
   body must be **stack-neutral** per iteration, or the stack grows/shrinks without bound
   (verdict `br!`);
6. **check control-structure balance** — every `if` has its `then`, every `begin` its
   `until`/`repeat`, every `do` its `loop`; a dangling opener or closer is flagged
   (verdict `ctl!`);
7. **check return-stack balance** — `>r`/`r>`/`r@` must balance within a word (an unmatched
   `>r`, or `r>`/`r@` reaching below the word's own frame, corrupts the return address)
   (verdict `r!`);
8. **check cell kinds** — a light type layer over the height sim tracks each cell as
   *number / address / flag / unknown*. `@ ! c@ c!` require an address; `* / mod` reject an
   address or flag operand; `+` rejects address+address (verdict `ty!`);
9. **catch division by a literal zero** — `/` or `mod` with a literal-`0` divisor (verdict `/0!`);
10. **know `variable`/`constant`** — declaring one registers its name (effect `( -- x )`), so a
    word that uses it is checked rather than flagged unknown — anvil works on *stateful* code;
11. **support recursion** — a word given a declaration may call itself; the self-call is
    checked against the *declared* effect, then the inferred body is verified against the
    same declaration (the assumption is discharged).

The verdicts are: `ok` · `BAD ( … -- … )` (declared *arity* mismatch) · `? names` (unknown
words) · `br!` (branch/loop arms disagree) · `ctl!` (unbalanced control structure) · `r!`
(return stack unbalanced) · `ty!` (cell-kind error) · `/0!` (division by a literal zero). A word
can earn several at once; `BAD` is reserved for the arity headline, the other verdicts explain
everything else. It is **sound for the straight-line and structured code fr produces** (each
structured construct reduces to a height constraint; the kind layer is deliberately
conservative — see below).

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

Primitive effects `name -> (consumes, produces)` mirror the kernel + prelude. The table
covers the shufflers (`dup 2dup over nip drop 2drop swap rot`), arithmetic/logic
(`+ - * / mod negate 1+ 1- abs 2* 2/ min max and or xor lshift rshift`), comparisons
(`= < > <= >= 0=`, each leaving one flag), memory (`@ ! c@ c! , cells cell+`), the
return-stack words (`>r r> r@`), counted-loop helpers (`i j unloop`), and i/o
(`emit key . u. depth space cr bye`). Words anvil knows about but that aren't loaded are
recorded by name (their CFA is 0) — fine, since `def`/`check{` look words up by name; only
the compiled-CFA path (`check-body`, used by forge) needs a real CFA. `def` registers each
checked word's effect so later words compose on top of it.

## Structured code: each construct is a height constraint

Beyond straight-line code, anvil tracks a small **control stack** of frames tagged with the
opener (`if`, `else`, `begin`, `while`, `do`) and the height at that point, so it can enforce:

- **`if … [else …] then`** — `if` consumes the flag and records the entry height `h0`. With
  an `else`, both arms must end at the same height. With an empty else (`if … then`), the
  true arm must be height-neutral (`h0`). Otherwise the merged effect is undefined → `br!`.
- **`begin … until`** — `until` consumes a flag; the net of (body + that consume) must return
  to the `begin` height, else the loop is not stack-neutral → `br!`.
- **`begin … while … repeat`** — `while` consumes the flag; at `repeat` the height must equal
  the `begin` height (the body returns the stack to the loop top) → else `br!`.
- **`do … loop`** — `do` consumes the limit+start; the body (with `i`/`j` available) must be
  height-neutral by `loop` → else `br!`.
- At end of phrase, the control stack must be empty (every opener closed) → else `ctl!`. A
  closer with no matching opener (`then` alone) is also `ctl!`.

**Return stack:** a running depth counter, `>r` +1 and `r>` −1 (`r@` reads without popping);
if it ever goes negative (`r>`/`r@` below the word's frame) or is nonzero at the end (a
leaked `>r`), that's `r!`. (`do/loop`'s own use of the return stack is handled by the loop
machinery, not this counter.)

**Recursion:** when a `def` carries a declaration, anvil registers the *declared* effect
before simulating the body, so a self-call resolves; the body is then checked against the
declaration as usual. (Without a declaration there's no effect to assume, so a self-call is
an unknown word.)

## Cell kinds — a conservative type layer

Alongside the height, every abstract cell carries a **kind**: number, address, flag, or
**unknown**. Kinds enter from three places: an integer literal is a *number*; a comparison
(`= < > <= >= 0=`) yields a *flag*; and a declaration whose input *names* it (`addr`/`adr`/
`ptr` → address, `n`/`u` → number, `flag` → flag — any other name stays unknown) seeds the
input cells. They propagate through the words: shufflers permute the kinds they move; `@`/`c@`
produce *unknown* (a fetched value could be anything); pointer arithmetic is honoured
(`address + number → address`, `cell+`/`1+`/`1-` keep address-ness, `address − address →
number`); other arithmetic yields a *number* only when both operands are numbers.

The crucial design rule: **unknown is absorbing** — any operation with an unknown operand
produces unknown. So anvil never *asserts* a concrete kind it isn't sure of, and a `ty!` only
fires when a cell is *known* to be the wrong kind:

- `@ ! c@ c!` on a cell known to be a number or a flag (e.g. `5 @`, or `( n -- ) @`);
- `* / mod` with an address or flag operand (e.g. `1 2 < 3 *`);
- `+` on two addresses.

Because unknown never triggers it, the layer has essentially no false positives: a value from
a word anvil doesn't model (or anything derived from it) is unknown and passes. It catches the
high-confidence mistakes — fetching through a literal/flag, arithmetic on a boolean — and the
declaration is again the redundancy (`def f ( n -- n ) @ ;` is caught because the input was
*declared* a number).

A literal `0` carries one extra bit of *value* knowledge (a number known to be zero); `/` or
`mod` with that on top is flagged `/0!`. The bit is lost the moment the cell is touched
(`0 1+` is just a number), so only a genuinely literal-zero divisor is caught.

**Stateful code.** While anvil is loaded it shadows `variable` and `constant`: each still
builds the real word *and* registers the name with effect `( -- x )`. So `variable c` then
`def bump ( -- ) c @ 1+ c ! ;` checks cleanly, instead of `bump` being rejected for the
"unknown word" `c`. (It wraps the kernel words via stashed CFAs + `execute`, because fr makes a
word self-visible inside its own definition.)

## Expected behavior (test vectors)

(anvil's interface is `def name ( decl ) body ;` and `check{ … }`.)

| source | result |
|---|---|
| `def sq ( n -- n ) dup * ;` | `ok` — inferred `( x -- y )` matches |
| `def bad ( a b -- c ) + + ;` | `BAD ( xx -- y )` — inferred `(3,1)` ≠ declared `(2,1)` |
| `def cube dup dup * * ;` | no decl — just prints inferred `cube ( x -- y )` |
| `def quad ( n -- n ) dup + ;` then `def q2 quad quad ;` | `ok` — words compose |
| `def t foo bar ;` | `? foo bar` — unknown words, named |
| `def x ( n -- n ) 0 < if dup then ;` | `br!` — the arm isn't height-neutral |
| `def x ( n -- n ) dup 0= if 1+ ;` | `ctl!` — `if` with no `then` |
| `def x ( -- ) begin 5 5 until ;` | `br!` — loop body grows the stack |
| `def x ( -- ) 5 0 do i . loop ;` | `ok` — counted loop, neutral body |
| `def x ( n -- ) >r ;` | `r!` — a leaked `>r` |
| `def fac ( n -- n ) dup 0= if drop 1 else dup 1- fac * then ;` | `ok` — recursion vs the decl |
| `def f ( n -- n ) @ ;` | `ty!` — `@` on a declared *number* |
| `def f ( addr -- n ) 3 cells + @ ;` | `ok` — pointer arithmetic stays an address |
| `check{ 5 6 ! }` | `ty!` — `!` to a number, not an address |
| `check{ 1 2 < 3 * }` | `ty!` — `*` on a flag |
| `def f ( addr -- n ) dup @ swap cell+ @ + ;` | `ok` — fetched values are unknown, so `+` is fine |
| `check{ 5 0 / }` | `/0!` — division by a literal zero |
| `variable c  def bump ( -- ) c @ 1+ c ! ;` | `ok` — anvil knows `c` is an address-producer |
| `check{ dup }` | infers `( x -- yy )` — a phrase that needs 1, leaves 2 |

## The boundary (why forge exists)

anvil proves **shape** (the stack effect is what's claimed), never **value**: `dup +`
checks fine as `( n -- n )` but doesn't square. Intent is checked by *running examples* —
that's `forge`'s job (see `forge-spec.md`). Don't expect anvil alone to certify correctness.
