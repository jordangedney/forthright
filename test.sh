#!/bin/sh
# test.sh — build forthright and run the core checks. Prints PASS/FAIL; exits
# non-zero if anything failed. This is the one-command answer to "is it still
# working?" (it runs the real kernel, prelude, lib, anvil, forge, and term). The
# explorer has its own, costlier suite — `./test-ember.sh` (the ptrace backend and
# ember.fr under a pty); run it too with `./test.sh --all`. No Python anywhere.
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
check "kernel: file-arg load"    "$(echo '5 square .' | ./fr lib/prelude.fr)"                          "25"
check "kernel: multi file-arg"   "$(printf '7 12 1 paint bye\n' | ./fr lib/prelude.fr lib/term.fr)"        "[7;12H"
check "prelude: 5 square ."      "$( ( cat lib/prelude.fr; echo '5 square .' ) | ./fr )"               "25"
check "control flow: -7 abs"     "$( ( cat lib/prelude.fr; echo ': abs dup 0 < if negate then ; -7 abs .' ) | ./fr )" "7"
check "see: disassemble square"  "$( ( cat lib/prelude.fr; echo 'see square' ) | ./fr )"               "dup * ;"
check "trace: step square on 5"  "$( ( cat lib/prelude.fr; echo '5 trace square' ) | ./fr )"           "* > 25"
check "syscall3: raw write(2)"   "$( ( cat lib/prelude.fr; echo 'variable m 72 m c! 73 m 1+ c! 1 m 2 1 syscall3 drop' ) | ./fr )" "HI"
check "syscall6: mmap a page"    "$( ( cat lib/prelude.fr; echo '0 4096 3 34 -1 0 9 syscall6 dup 42 swap ! @ .' ) | ./fr )" "42"
INCF="$(mktemp)"; printf ': inc-ok 909 ;\n' > "$INCF"
check "kernel: include loads file" "$( printf 'include %s\ninc-ok .\n' "$INCF" | ./fr )"              "909"
rm -f "$INCF"
check "kernel: .\" prints string"  "$( printf '." hello there"' | ./fr )"                             "hello there"
check "kernel: s\" addr len"       "$( ( cat lib/prelude.fr; echo 's" abcd" nip .' ) | ./fr )"          "4"
check "kernel: compiled string"    "$( ( cat lib/prelude.fr; echo ': g ." hi" 9 . ; g' ) | ./fr )"      "hi9"
check "kernel: cmove + type"       "$( ( cat lib/prelude.fr; echo 'variable b 16 allot s" hey" b swap cmove b 3 type' ) | ./fr )" "hey"
check "kernel: fill"               "$( ( cat lib/prelude.fr; echo 'variable b 16 allot b 3 88 fill b 3 type' ) | ./fr )" "XXX"
check "kernel: xor lshift rshift"  "$( printf '6 3 xor .  1 4 lshift .  64 1 rshift .\n' | ./fr )"     "5"
check "kernel: do/loop + i"      "$( printf ': s 0  6 1 do i + loop  . ; s\n' | ./fr )"               "15"
check "kernel: unloop early-exit" "$( printf ': f 9 0 do i 4 = if i . unloop exit then loop ; f\n' | ./fr )" "4"
check "kernel: nested do (i/j)"  "$( printf ': g 2 0 do 2 0 do j . i . loop loop ; g\n' | ./fr )"     "0"
# --- lib/ modules (each `include`s its own deps, so just  ./fr lib/X.fr ) -------
check "lib/math: mod"            "$( printf '17 5 mod .\n' | ./fr lib/math.fr )"                       "2"
check "lib/math: clamp"          "$( printf '5 0 3 clamp .\n' | ./fr lib/math.fr )"                    "3"
check "lib/string: s= (compiled)" "$( printf ': e s" ab" s" ab" s= ; e .\n' | ./fr lib/string.fr )" "-1"
check "lib/fmt: u.r"             "$( printf '42 5 u.r\n' | ./fr lib/fmt.fr )"                          "  42"
check "lib/fmt: .x hex"          "$( printf '255 .x\n' | ./fr lib/fmt.fr )"                            "FF"
check "lib/time: now-ms > 0"     "$( printf 'now-ms 0 > .\n' | ./fr lib/time.fr )"                     "-1"
check "lib/key: loads"           "$( printf '." KEYOK"\n' | ./fr lib/key.fr )"                         "KEYOK"
check "lib/draw: panel"          "$( printf '1 1 10 3 s" PNL" panel\n' | ./fr lib/draw.fr )"          "PNL"
check "lib/tui: loads"           "$( printf '." TUIOK"\n' | ./fr lib/tui.fr )"                         "TUIOK"
LIBF="$(mktemp)"
printf 's" %s" zpath open-w dup s" io-ok" write-fd drop close-fd\n' "$LIBF" | ./fr lib/io.fr
check "lib/io: write a file"     "$(cat "$LIBF")"                                                      "io-ok"
rm -f "$LIBF"
check "lib/random: in range"     "$( echo '42 seed!  5 random% 5 <  5 random% 0 >= and .' | ./fr lib/random.fr )" "-1"
# --- examples ----------------------------------------------------------------
check "examples/demo runs"       "$(timeout 5 ./fr examples/demo.fr)"                                  "New game"
# tetris is interactive (auto-runs); ember-test.fr loads it under an fr-native pty,
# plays a couple of keys, quits — asserting it drew blocks and exited cleanly.
check "examples/tetris (pty)"    "$(echo tetris | timeout 40 ./fr ember-test.fr)"                      "TETRIS OK"
check "term: ANSI cursor+colour"  "$( ( cat lib/prelude.fr lib/term.fr; echo '7 12 1 paint' ) | ./fr )"        "[7;12H"
# anvil/forge include their own deps, so run them as file-args (load-once, no cat'ing).
check "anvil: def ... ok"          "$(echo 'def sq ( n -- n ) dup * ;'              | ./fr anvil.fr)" "ok"
check "anvil: catches BAD"         "$(echo 'def bad ( a b -- c ) + + ;'             | ./fr anvil.fr)" "BAD"
check "anvil: names unknown words" "$(echo 'def t foo bar ;'                        | ./fr anvil.fr)" "? foo bar"
check "anvil: branch imbalance"    "$(echo 'def x ( n -- n ) 0 < if dup then ;'     | ./fr anvil.fr)" "br!"
check "anvil: missing then (ctl!)" "$(echo 'def x ( n -- n ) dup 0= if 1+ ;'        | ./fr anvil.fr)" "ctl!"
check "anvil: loop must be neutral" "$(echo 'def x ( -- ) begin 5 5 until ;'        | ./fr anvil.fr)" "br!"
check "anvil: do/loop balances"    "$(echo 'def x ( -- ) 5 0 do i . loop ;'         | ./fr anvil.fr)" "ok"
check "anvil: return-stack (r!)"   "$(echo 'def x ( n -- ) >r ;'                    | ./fr anvil.fr)" "r!"
check "anvil: recursion checks"    "$(echo 'def fac ( n -- n ) dup 0= if drop 1 else dup 1- fac * then ;' | ./fr anvil.fr)" "ok"
check "anvil: @ needs an address"  "$(echo 'def x ( n -- n ) @ ;'                     | ./fr anvil.fr)" "ty!"
check "anvil: typed pointer arith" "$(echo 'def x ( addr -- n ) 3 cells + @ ;'        | ./fr anvil.fr)" "ok"
check "anvil: store needs address" "$(echo 'check{ 5 6 ! }'                           | ./fr anvil.fr)" "ty!"
check "anvil: * rejects a flag"    "$(echo 'check{ 1 2 < 3 * }'                       | ./fr anvil.fr)" "ty!"
check "anvil: knows variables"     "$(echo 'variable c  def b ( -- ) c @ 1+ c ! ;'   | ./fr anvil.fr)" "ok"
check "anvil: division by zero"    "$(echo 'check{ 5 0 / }'                           | ./fr anvil.fr)" "/0!"
check "anvil: output kind checked" "$(echo 'def f ( -- addr ) 5 ;'                    | ./fr anvil.fr)" "ty!"
check "anvil: out-kind propagates" "$(echo 'variable v  def g ( -- ) v 2 * drop ;'    | ./fr anvil.fr)" "ty!"
check "forge: synthesizes dup *"   "$(echo forge | ./fr forge.fr)"                                    "dup *"

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
