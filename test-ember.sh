#!/bin/sh
# test-ember.sh — the explorer's own test suite. Split out from test.sh because
# ember is the one subsystem with several backends (the Python model, the ptrace
# backend, and the self-hosted ember.fr driven under a pty), and exercising them
# costs more than the rest of the project combined. Run it directly, or via
# `./test.sh --all`. Prints PASS/FAIL; exits non-zero if anything failed.
cd "$(dirname "$0")" || exit 2
fail=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
check() {
  if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else
    bad "$1 (wanted '$3', got: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-60))"
  fi
}

printf 'building... '
if ./build.sh >/dev/null 2>&1; then printf 'ok\n\n'; else echo "BUILD FAILED"; exit 1; fi

# --- ptrace.fr: process control + driving the real engine (pipe-testable) ------
# fork a child, PTRACE_TRACEME + SINGLESTEP it, confirm RIP advanced.
check "ptrace.fr: fr single-steps a child" "$( ( cat prelude.fr ptrace.fr; echo trace-demo ) | ./fr )" "MOVED"
# watch: fr drives the REAL fr engine under ptrace and decodes the live dispatch.
check "ptrace.fr: watch traces real engine" "$( ( cat prelude.fr ptrace.fr; echo "5 ' square watch" ) | ./fr )" "square dup *"

# --- ember.fr: the visual explorer on the live ptrace backend ------------------
# ember-trace is the non-interactive core: it peeks the child's REAL data stack at
# each dispatch (no tty needed), so it exercises the engine + branch/call following.
LT="cat prelude.fr term.fr ptrace.fr ember.fr"
check "ember.fr: live stack (5 square -> 5 5)"  "$( ( $LT; echo "5 ' square ember-trace" ) | ./fr )"  "5 5"
check "ember.fr: follows if/then (abs -5)"      "$( ( $LT; echo ": abs dup 0< if negate then ;  -5 ' abs ember-trace" ) | ./fr )"  "negate"
check "ember.fr: steps into colon (cube 3)"     "$( ( $LT; echo ": cube dup square * ;  3 ' cube ember-trace" ) | ./fr )"  "27"

# --- end-to-end TUIs (slower: a pty and a ptraced process) ---------------------
check "ember.fr: pty stepper 5->25"     "$(timeout 30 ./ember-pty --selftest)"        "EMBER PASS"
check "ember.fr: bare boots to prompt"  "$(timeout 30 ./ember-pty --prompt-selftest)" "EMBER PROMPT PASS"
check "ember.fr: live edit re-targets"  "$(timeout 30 ./ember-pty --edit-selftest)"   "EMBER EDIT PASS"
check "ember (python): model"           "$(./ember --selftest)"                      "ALL PASS"
check "ember (python): native ptrace"   "$(timeout 60 ./ember --native-selftest)"    "NATIVE PASS"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mALL EMBER CHECKS PASSED\033[0m\n'; else printf '\033[31mSOME EMBER CHECKS FAILED\033[0m\n'; fi
exit "$fail"
