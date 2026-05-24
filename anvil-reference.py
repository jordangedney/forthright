#!/usr/bin/env python3
"""
anvil — a stack-effect verifier for forthright (fr) Forth source.

The project thesis: Forth lacks error-correcting redundancy, so we supply it
*outside* the shipped artifact. anvil reads fr source and, by abstract stack
simulation, does four checkable things a bare Forth never would until (maybe)
crashing at runtime:

  1. infer each colon word's stack effect ( in -- out );
  2. check that inference against the declared ( ... -- ... ) comment, if given
     — the declaration is the redundancy; the check is the payoff;
  3. flag unknown words (typos / undefined);
  4. flag top-level code that underflows the stack.

This is *sound* for straight-line (branchless) code, which is all fr currently
is. When if/else/then arrive, the interesting rule — both arms of a branch must
have the same stack effect, or the effect is undefined — slots straight into
`analyze` (that's where a concatenative checker earns its keep).

Usage:
    anvil [FILE]        # check a file, or stdin if omitted
    anvil --selftest    # run built-in checks
"""

import sys

# Primitive stack effects: name -> (consumes, produces). Mirrors fr's words
# plus ember's superset (over rot / mod = < > negate .s).
PRIMS = {
    "dup": (1, 2), "drop": (1, 0), "swap": (2, 2), "over": (2, 3), "rot": (3, 3),
    "+": (2, 1), "-": (2, 1), "*": (2, 1), "/": (2, 1), "mod": (2, 1),
    "negate": (1, 1), "=": (2, 1), "<": (2, 1), ">": (2, 1),
    ".": (1, 0), ".s": (0, 0), "bye": (0, 0),
    "square": (1, 1),                  # a colon word fr predefines in assembly
}


# --- ANSI colour (only when writing to a terminal) ------------------------
_TTY = sys.stdout.isatty()


def c(text, code):
    return "\033[%sm%s\033[0m" % (code, text) if _TTY else text


OK, BAD, DIM, ACC = "32", "31", "90", "36"


def is_int(tok):
    try:
        int(tok)
        return True
    except ValueError:
        return False


# --- abstract stack simulation -------------------------------------------
def analyze(seq, known):
    """Simulate `seq` (a list of tokens) on an abstract stack.

    Returns dict:
      unknown    : list of unknown tokens (effect is undefined if non-empty)
      effect     : (inputs, outputs) — inputs = cells consumed below entry,
                   outputs = cells present above entry at the end
      underflow  : (token, deficit) for the first op that reaches below the
                   entry stack, else None
    """
    height = 0          # stack height relative to entry top (may go negative)
    low = 0             # most-negative height reached
    underflow = None
    unknown = []
    for tok in seq:
        if is_int(tok):
            cons, prod = 0, 1
        elif tok in known:
            cons, prod = known[tok]
        else:
            unknown.append(tok)
            continue
        height -= cons
        if height < low:
            low = height
            if underflow is None and height < 0:
                underflow = (tok, -height)
        height += prod
    inputs = -low
    outputs = inputs + height
    return {"unknown": unknown, "effect": (inputs, outputs), "underflow": underflow}


def parse_decl(comment_tokens):
    """( a b -- c ) -> (declared_in, declared_out), or None if not a stack
    declaration (no `--`)."""
    if "--" not in comment_tokens:
        return None
    k = comment_tokens.index("--")
    return (len(comment_tokens[:k]), len(comment_tokens[k + 1:]))


def tokenize(text):
    """Whitespace tokens, with `\\` line comments stripped."""
    out = []
    for line in text.splitlines():
        for t in line.split():
            if t == "\\":
                break
            out.append(t)
    return out


def eff_str(inp, out):
    return "( %s -- %s )" % (" ".join("x%d" % i for i in range(inp)) or "",
                             " ".join("y%d" % i for i in range(out)) or "")


# --- the checker ----------------------------------------------------------
class Report:
    def __init__(self):
        self.lines = []
        self.errors = 0

    def ok(self, text):
        self.lines.append("  " + c("✓", OK) + " " + text)

    def bad(self, text):
        self.lines.append("  " + c("✗", BAD) + " " + text)
        self.errors += 1

    def note(self, text):
        self.lines.append("    " + c(text, DIM))


def check(text):
    toks = tokenize(text)
    known = dict(PRIMS)
    rep = Report()
    toplevel = []
    i, n = 0, len(toks)
    while i < n:
        t = toks[i]
        if t == "(":                          # standalone comment
            j = i + 1
            while j < n and toks[j] != ")":
                j += 1
            i = j + 1
            continue
        if t == ":":
            if i + 1 >= n:
                rep.bad("':' with no name"); break
            name = toks[i + 1]; i += 2
            decl = None
            if i < n and toks[i] == "(":       # stack-effect declaration
                j = i + 1; com = []
                while j < n and toks[j] != ")":
                    com.append(toks[j]); j += 1
                decl = parse_decl(com)
                i = j + 1
            body = []
            while i < n and toks[i] != ";":
                if toks[i] == "(":             # inline comment inside body
                    j = i + 1
                    while j < n and toks[j] != ")":
                        j += 1
                    i = j + 1; continue
                body.append(toks[i]); i += 1
            missing_semi = i >= n
            i += 1                              # consume ';'

            res = analyze(body, known)
            label = c(name, ACC)
            declshow = " declared %s" % eff_str(*decl) if decl else ""
            if res["unknown"]:
                rep.bad("%-10s unknown word(s): %s" %
                        (label, ", ".join(sorted(set(res["unknown"])))))
                continue
            inp, out = res["effect"]
            inferred = "inferred %s" % eff_str(inp, out)
            if decl and (inp, out) != decl:
                rep.bad("%-10s %s  but%s  — MISMATCH" % (label, inferred, declshow))
            elif decl:
                rep.ok("%-10s %s  matches %s" % (label, inferred, eff_str(*decl)))
            else:
                rep.ok("%-10s %s" % (label, inferred))
            if missing_semi:
                rep.bad("%-10s missing ';'" % label)
            known[name] = (inp, out)
        else:
            toplevel.append(t); i += 1

    # top-level code (runs on an initially empty stack)
    if toplevel:
        res = analyze(toplevel, known)
        if res["unknown"]:
            rep.bad("top level: unknown word(s): %s" %
                    ", ".join(sorted(set(res["unknown"]))))
        elif res["underflow"]:
            tok, deficit = res["underflow"]
            rep.bad("top level underflows at `%s` (needs %d more cell%s)" %
                    (tok, deficit, "" if deficit == 1 else "s"))
        else:
            inp, out = res["effect"]
            rep.ok("top level %s  (leaves %d cell%s on the stack)" %
                   (eff_str(inp, out), out, "" if out == 1 else "s"))

    return rep


def run(text):
    rep = check(text)
    print(c("anvil", ACC) + " — stack-effect check\n")
    print("\n".join(rep.lines) if rep.lines else "  (nothing to check)")
    print()
    if rep.errors:
        print("  " + c("%d problem%s — FAIL" % (rep.errors, "" if rep.errors == 1 else "s"), BAD))
        return 1
    print("  " + c("all consistent — PASS", OK))
    return 0


# --- self-test ------------------------------------------------------------
def selftest():
    cases = [
        # (source, expect_errors)
        (": sq ( n -- n ) dup * ;", 0),
        (": bad ( n -- n ) dup ;", 1),                  # inferred (1->2) != decl
        (": cube dup dup * * ;", 0),                    # no decl, just inferred
        (": quad ( n -- n ) dup + ;\n: q2 quad quad ;", 0),
        (": x foo bar ;", 1),                           # unknown words
        (": double 2 * ;\n5 double .", 0),              # top level balances
        ("dup", 1),                                     # top-level underflow
        (": drop2 ( a b -- ) drop drop ;\n5 drop2", 1),  # needs 2, have 1
    ]
    passed = 0
    for src, want in cases:
        rep = check(src)
        good = (rep.errors == want)
        passed += good
        print("  [%s] errs=%d want=%d  | %s" %
              (c("OK", OK) if good else c("XX", BAD), rep.errors, want,
               src.replace("\n", "  ")[:54]))
    print("\n%s (%d/%d)" % (c("ALL PASS", OK) if passed == len(cases)
                            else c("FAILURES", BAD), passed, len(cases)))
    return 0 if passed == len(cases) else 1


def main():
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if args:
        with open(args[0]) as f:
            text = f.read()
    else:
        text = sys.stdin.read()
    sys.exit(run(text))


if __name__ == "__main__":
    main()
