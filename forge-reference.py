#!/usr/bin/env python3
"""
forge — the generate -> check -> repair loop, the forthright thesis in miniature.

A generator proposes candidate fr definitions; the SELF-HOSTED verifier anvil.fr
checks each one's stack effect; only the shape-valid candidates are then run on
examples to confirm they compute the right thing; the first that passes both is
"forged" and printed as a verified definition.

The generator here is a breadth-first search over a small word pool — a stand-in
for an AI writing Forth. The point isn't the generator: it's that nothing is
accepted unless **anvil, Forth checking Forth, approves the stack effect first**,
and that anvil checks *shape* while the examples check *intent* (a candidate can
pass anvil yet compute the wrong value — you'll see that happen below).

    python3 forge.py            # run the demo synthesis tasks

Each candidate costs one `fr` run for the anvil check (+ a few for value tests),
so this is a real loop against the real, self-hosted verifier — not a model.
"""

import os
import sys
import itertools
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
FR = os.path.join(HERE, "fr")
PRELUDE = open(os.path.join(HERE, "prelude.fr")).read()
ANVIL = open(os.path.join(HERE, "anvil.fr")).read()

# The generator's vocabulary (all real fr / prelude words).
POOL = ["dup", "drop", "swap", "over", "+", "-", "*", "1+", "1-", "negate"]


def run_fr(script, with_anvil=False):
    src = PRELUDE + ("\n" + ANVIL if with_anvil else "") + "\n" + script
    p = subprocess.run([FR], input=src.encode("utf-8"),
                       capture_output=True, timeout=15)
    return p.stdout.decode("utf-8", errors="replace")


def anvil_verdict(body, din, dout):
    """Ask the self-hosted anvil to check `body` against a declared effect.
    Returns 'ok' | 'BAD' | 'br!' | '?'."""
    decl = "( %s -- %s )" % (" ".join("a%d" % i for i in range(din)),
                             " ".join("r%d" % i for i in range(dout)))
    out = run_fr("def cand %s %s ;\n" % (decl, body), with_anvil=True)
    lines = [l.strip() for l in out.splitlines()]
    if "br!" in lines:
        return "br!"
    if "ok" in lines:
        return "ok"
    if any(l.startswith("BAD") for l in lines):
        return "BAD"
    return "?"


def values_ok(body, examples):
    """Define the candidate for real and run it on each example (intent check)."""
    for args, expected in examples:
        out = run_fr(": cand %s ;\n%s cand .\n" % (body, " ".join(map(str, args))))
        nums = [l.strip() for l in out.splitlines()
                if l.strip().lstrip("-").isdigit()]
        if not nums or int(nums[-1]) != expected:
            return False
    return True


def synthesize(name, din, dout, examples, maxlen=3):
    ex = ", ".join("%s->%d" % (" ".join(map(str, a)), e) for a, e in examples)
    print("forge  %s : ( %d in -- %d out )   examples: %s" % (name, din, dout, ex))
    tried = rejected = 0
    for length in range(1, maxlen + 1):
        for combo in itertools.product(POOL, repeat=length):
            body = " ".join(combo)
            tried += 1
            v = anvil_verdict(body, din, dout)
            if v != "ok":                       # anvil rejects the stack effect
                rejected += 1
                continue
            vok = values_ok(body, examples)      # shape ok -> check intent
            print("   anvil ✓  %-16s  values %s"
                  % (body, "✓  ⟵ FORGED" if vok else "✗  (right shape, wrong result)"))
            if vok:
                print("  => : %s %s ;   "
                      "[verified: effect by anvil, values by test;  %d tried, "
                      "%d rejected by anvil]\n" % (name, body, tried, rejected))
                return body
    print("  => no solution up to length %d  (%d tried)\n" % (maxlen, tried))
    return None


def main():
    if not os.path.exists(FR):
        print("no ./fr — run ./build.sh first"); return 1
    print("=" * 70)
    print("forge: generate -> check (anvil, self-hosted) -> repair")
    print("=" * 70)
    # 1) a one-word answer; 2) shows anvil passing wrong-value candidates;
    # 3) a three-word synthesis (2n+1).
    synthesize("add", 2, 1, [((3, 4), 7), ((10, 5), 15)])
    synthesize("sq",  1, 1, [((3,), 9), ((4,), 16), ((5,), 25)])
    synthesize("lin", 1, 1, [((1,), 3), ((2,), 5), ((3,), 7)])
    return 0


if __name__ == "__main__":
    sys.exit(main())
