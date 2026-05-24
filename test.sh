#!/bin/sh
# test.sh — build forthright and run the core checks. Prints PASS/FAIL; exits
# non-zero if anything failed. This is the one-command answer to "is it still
# working?" (it runs the real kernel, prelude, anvil, forge, term, and the Python
# reference specs). The explorer has its own, costlier suite — `./test-ember.sh`
# (the Python model, the ptrace backend, and ember.fr under a pty); run it too
# with `./test.sh --all`.
cd "$(dirname "$0")" || exit 2
fail=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
# check NAME ACTUAL WANTED-SUBSTRING   (runs in the main shell so fail sticks)
check() {
  if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else
    bad "$1 (wanted '$3', got: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-60))"
  fi
}

printf 'building... '
if ./build.sh >/dev/null 2>&1; then printf 'ok\n\n'; else echo "BUILD FAILED"; exit 1; fi

check "kernel: 2 3 + ."          "$(echo '2 3 + .' | ./fr)"                                       "5"
check "kernel: file-arg load"    "$(echo '5 square .' | ./fr prelude.fr)"                          "25"
check "kernel: multi file-arg"   "$(printf '7 12 1 paint bye\n' | ./fr prelude.fr term.fr)"        "[7;12H"
check "prelude: 5 square ."      "$( ( cat prelude.fr; echo '5 square .' ) | ./fr )"               "25"
check "control flow: -7 abs"     "$( ( cat prelude.fr; echo ': abs dup 0 < if negate then ; -7 abs .' ) | ./fr )" "7"
check "see: disassemble square"  "$( ( cat prelude.fr; echo 'see square' ) | ./fr )"               "dup * ;"
check "trace: step square on 5"  "$( ( cat prelude.fr; echo '5 trace square' ) | ./fr )"           "* > 25"
check "syscall3: raw write(2)"   "$( ( cat prelude.fr; echo 'variable m 72 m c! 73 m 1+ c! 1 m 2 1 syscall3 drop' ) | ./fr )" "HI"
check "syscall6: mmap a page"    "$( ( cat prelude.fr; echo '0 4096 3 34 -1 0 9 syscall6 dup 42 swap ! @ .' ) | ./fr )" "42"
INCF="$(mktemp)"; printf ': inc-ok 909 ;\n' > "$INCF"
check "kernel: include loads file" "$( printf 'include %s\ninc-ok .\n' "$INCF" | ./fr )"              "909"
rm -f "$INCF"
check "kernel: .\" prints string"  "$( printf '." hello there"' | ./fr )"                             "hello there"
check "kernel: s\" addr len"       "$( ( cat prelude.fr; echo 's" abcd" nip .' ) | ./fr )"          "4"
check "kernel: compiled string"    "$( ( cat prelude.fr; echo ': g ." hi" 9 . ; g' ) | ./fr )"      "hi9"
check "kernel: cmove + type"       "$( ( cat prelude.fr; echo 'variable b 16 allot s" hey" b swap cmove b 3 type' ) | ./fr )" "hey"
check "kernel: fill"               "$( ( cat prelude.fr; echo 'variable b 16 allot b 3 88 fill b 3 type' ) | ./fr )" "XXX"
check "kernel: xor lshift rshift"  "$( printf '6 3 xor .  1 4 lshift .  64 1 rshift .\n' | ./fr )"     "5"
check "term: ANSI cursor+colour"  "$( ( cat prelude.fr term.fr; echo '7 12 1 paint' ) | ./fr )"        "[7;12H"
check "anvil: def ... ok"        "$( ( cat prelude.fr anvil.fr; echo 'def sq ( n -- n ) dup * ;' ) | ./fr )" "ok"
check "anvil: catches BAD"       "$( ( cat prelude.fr anvil.fr; echo 'def bad ( a b -- c ) + + ;' ) | ./fr )" "BAD"
check "anvil: branch imbalance"  "$( ( cat prelude.fr anvil.fr; echo 'def x ( n -- n ) 0 < if dup then ;' ) | ./fr )" "br!"
check "forge: synthesizes dup *" "$( ( cat prelude.fr anvil.fr forge.fr; echo forge ) | ./fr )"    "dup * <"
check "anvil-reference.py spec"   "$(python3 anvil-reference.py --selftest)"                         "ALL PASS"
check "forge-reference.py"        "$(python3 forge-reference.py)"                                    "FORGED"

# --all (or -a): also run the explorer suite, folding its result into the exit code.
case "$1" in
  --all|-a) echo; echo '== ember suite (test-ember.sh) =='; ./test-ember.sh || fail=1 ;;
esac

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mALL CHECKS PASSED\033[0m\n'; else printf '\033[31mSOME CHECKS FAILED\033[0m\n'; fi
case "$1" in
  --all|-a) : ;;
  *) printf '(explorer: run \033[36m./test-ember.sh\033[0m for the ember backends, or \033[36m./test.sh --all\033[0m)\n' ;;
esac
exit "$fail"
