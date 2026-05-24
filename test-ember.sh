#!/bin/sh
# test-ember.sh — the explorer's own test suite. Split out from test.sh because
# ember exercises the ptrace backend and the full-screen TUI under a pseudo-terminal,
# which costs more than the rest of the project combined. The interactive checks run
# through `ember-test.fr` — an fr-native pty driver (no Python anywhere). Run it
# directly, or via `./test.sh --all`. Prints PASS/FAIL; exits non-zero on any failure.
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
check "ptrace.fr: fr single-steps a child" "$( echo trace-demo | ./fr lib/ptrace.fr )" "MOVED"
# watch: fr drives the REAL fr engine under ptrace and decodes the live dispatch.
check "ptrace.fr: watch traces real engine" "$( echo "5 ' square watch" | ./fr lib/ptrace.fr )" "square dup *"

# --- ember.fr: the visual explorer on the live ptrace backend ------------------
# ember-trace is the non-interactive core: it peeks the child's REAL data stack at
# each dispatch (no tty needed), so it exercises the engine + branch/call following.
# (ember.fr `include`s its own deps, so it loads with just  ./fr ember.fr)
LT="cat ember.fr"
check "ember.fr: live stack (5 square -> 5 5)"  "$( ( $LT; echo "5 ' square ember-trace" ) | ./fr )"  "5 5"
check "ember.fr: follows if/then (abs -5)"      "$( ( $LT; echo ": abs dup 0< if negate then ;  -5 ' abs ember-trace" ) | ./fr )"  "negate"
check "ember.fr: steps into colon (cube 3)"     "$( ( $LT; echo ": cube dup square * ;  3 ' cube ember-trace" ) | ./fr )"  "27"

# --- end-to-end TUIs (slower: a pty and a ptraced process) ---------------------
# ember-test.fr (fr, via lib/pty.fr) spawns ./fr ember.fr on a real pty, paces keys,
# captures the frames, and asserts substrings — the no-Python replacement for ember-pty.
check "ember.fr: pty stepper 5->25"     "$(echo step   | timeout 40 ./fr ember-test.fr)" "EMBER STEP PASS"
check "ember.fr: bare boots to prompt"  "$(echo prompt | timeout 40 ./fr ember-test.fr)" "EMBER PROMPT PASS"
check "ember.fr: live edit re-targets"  "$(echo edit   | timeout 40 ./fr ember-test.fr)" "EMBER EDIT PASS"
check "ember.fr: bare expr (4 4 +)"     "$(echo expr   | timeout 40 ./fr ember-test.fr)" "EMBER EXPR PASS"
check "ember.fr: autoplay runs to rest" "$(echo auto   | timeout 40 ./fr ember-test.fr)" "EMBER AUTO PASS"
check "ember.fr: captures stdout (OUT)" "$(echo out    | timeout 40 ./fr ember-test.fr)" "EMBER OUT PASS"
check "ember.fr: REPL stack persists"   "$(echo repl   | timeout 40 ./fr ember-test.fr)" "EMBER REPL PASS"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mALL EMBER CHECKS PASSED\033[0m\n'; else printf '\033[31mSOME EMBER CHECKS FAILED\033[0m\n'; fi
exit "$fail"
