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

# --- ember.fr internals (fast: drive the render/step words through a pipe) -----
# These need no tty, so they don't pay the pty cost — they poke ember.fr's logic
# directly: `<args> ' <word> einit` sets up the stepper, then `estep`/`erun` run it.
LT="cat prelude.fr term.fr ember.fr"
A=": abs dup 0< if negate then ;"
S=": sign dup 0< if drop -1 else drop 1 then ;"
CD=": cd begin 1- dup 0= until ;"
CUBE=": cube dup square * ;"

check "ember.fr: frame has title"    "$( ( $LT; echo "5 ' square einit draw" ) | ./fr )"                 "ember: square"
check "ember.fr: highlights cursor"  "$( ( $LT; echo "5 ' square einit draw" ) | ./fr )"                 "[33m"
check "ember.fr: estep runs a word"  "$( ( $LT; echo "5 ' square einit estep .s" ) | ./fr )"             "5 5"
check "ember.fr: estep pushes lit"   "$( ( $LT; echo ": addk 10 + ; 5 ' addk einit estep .s" ) | ./fr )" "5 10"
check "ember.fr: erun reaches EXIT"  "$( ( $LT; echo "5 ' square einit erun edone @ ." ) | ./fr )"        "-1"
check "ember.fr: thread shows branch" "$( ( $LT; echo "$A ' abs einit draw-thread" ) | ./fr )"            "0b"
# control flow: estep follows branches AND steps into colon words. Results, not
# step counts, are the proof (descent changes how many cells a word takes).
check "ember.fr: 0branch falls thru (abs -5)" "$( ( $LT; echo "$A -5 ' abs einit erun .s" ) | ./fr )"     "5"
check "ember.fr: 0branch jumps (abs 5)"       "$( ( $LT; echo "$A  5 ' abs einit erun .s" ) | ./fr )"     "5"
check "ember.fr: if/else if-arm (sign -5)"    "$( ( $LT; echo "$S -5 ' sign einit erun .s" ) | ./fr )"    "-1"
check "ember.fr: if/else else-arm (sign 5)"   "$( ( $LT; echo "$S  5 ' sign einit erun 2 + ." ) | ./fr )" "3"
check "ember.fr: backward branch (loop)"      "$( ( $LT; echo "$CD 3 ' cd einit erun .s" ) | ./fr )"      "0"
# stepping INTO colon words (the call-tree walk, like the Python ember):
check "ember.fr: steps into colon"  "$( ( $LT; echo "$CUBE 3 ' cube einit estep estep ecur @ .cfaname" ) | ./fr )" "square"
check "ember.fr: call-path depth"   "$( ( $LT; echo "$CUBE 3 ' cube einit estep estep cn @ ." ) | ./fr )"          "1"
check "ember.fr: nested run (cube 3)" "$( ( $LT; echo "$CUBE 3 ' cube einit erun .s" ) | ./fr )"                   "27"

# ptrace from fr: fork a child, PTRACE_TRACEME + SINGLESTEP it, confirm RIP advanced.
# This is the groundwork for self-hosting ember's debugger backend (no Python).
check "ptrace.fr: fr single-steps a child" "$( ( cat prelude.fr ptrace.fr; echo trace-demo ) | ./fr )" "MOVED"

# --- end-to-end backends (slower: a pty and a ptraced process) -----------------
check "ember.fr: pty stepper 5->25"  "$(timeout 30 ./ember-fr --selftest)"        "EMBER-FR PASS"
check "ember: Python model"          "$(./ember --selftest)"                      "ALL PASS"
check "ember: native ptrace backend" "$(timeout 60 ./ember --native-selftest)"    "NATIVE PASS"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mALL EMBER CHECKS PASSED\033[0m\n'; else printf '\033[31mSOME EMBER CHECKS FAILED\033[0m\n'; fi
exit "$fail"
