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
# directly by setting its state variables and calling draw / estep.
LT="cat prelude.fr term.fr ember.fr"

check "ember.fr: frame has title"   "$( ( $LT; echo "5 ' square ecfa ! ' square cell+ dup ebody ! ebp ! 0 estepn ! 0 edone ! draw" ) | ./fr )" "ember: square"
check "ember.fr: highlights cursor" "$( ( $LT; echo "5 ' square ecfa ! ' square cell+ dup ebody ! ebp ! 0 estepn ! 0 edone ! draw" ) | ./fr )" "[33m"
check "ember.fr: estep runs a word" "$( ( $LT; echo "5 ' square cell+ ebp ! 0 edone ! 0 estepn ! estep .s" ) | ./fr )" "5 5"
check "ember.fr: estep pushes lit"  "$( ( $LT; echo ": addk 10 + ; 5 ' addk cell+ ebp ! 0 edone ! 0 estepn ! estep .s" ) | ./fr )" "5 10"
check "ember.fr: estep ends at EXIT" "$( ( $LT; echo "' square cell+ 16 + ebp ! 0 edone ! estep edone @ ." ) | ./fr )" "-1"
check "ember.fr: thread shows branch" "$( ( $LT; echo ": abs dup 0< if negate then ; ' abs cell+ dup ebody ! ebp ! draw-thread" ) | ./fr )" "0b"
# branch-stepping: estep follows control flow. abs takes the 0branch on 5 (3 cells:
# dup 0< 0branch) but falls through on -5 (4: + negate); sign exercises if/else;
# cd loops via a backward branch (3 iterations x 4 cells = 12). estepn is the proof.
A=": abs dup 0< if negate then ;"
S=": sign dup 0< if drop -1 else drop 1 then ;"
CD=": cd begin 1- dup 0= until ;"
ESTEP="estep estep estep estep estep estep estep estep estep estep estep estep estep estep"
check "ember.fr: 0branch jumps (abs 5)"     "$( ( $LT; echo "$A  5 ' abs cell+ ebp ! 0 edone ! 0 estepn ! $ESTEP estepn @ ." ) | ./fr )" "3"
check "ember.fr: 0branch falls thru (abs -5)" "$( ( $LT; echo "$A  -5 ' abs cell+ ebp ! 0 edone ! 0 estepn ! $ESTEP estepn @ ." ) | ./fr )" "4"
check "ember.fr: if/else branch (sign -5)"  "$( ( $LT; echo "$S  -5 ' sign cell+ ebp ! 0 edone ! 0 estepn ! $ESTEP .s" ) | ./fr )" "-1"
check "ember.fr: backward branch (loop)"    "$( ( $LT; echo "$CD  3 ' cd cell+ ebp ! 0 edone ! 0 estepn ! $ESTEP estepn @ ." ) | ./fr )" "12"

# --- end-to-end backends (slower: a pty and a ptraced process) -----------------
check "ember.fr: pty stepper 5->25"  "$(timeout 30 ./ember-fr --selftest)"        "EMBER-FR PASS"
check "ember: Python model"          "$(./ember --selftest)"                      "ALL PASS"
check "ember: native ptrace backend" "$(timeout 60 ./ember --native-selftest)"    "NATIVE PASS"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mALL EMBER CHECKS PASSED\033[0m\n'; else printf '\033[31mSOME EMBER CHECKS FAILED\033[0m\n'; fi
exit "$fail"
