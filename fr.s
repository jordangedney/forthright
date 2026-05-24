# forthright — a freestanding indirect-threaded-code Forth for x86-64 Linux.
#
# No libc, no runtime: just raw syscalls and threaded code. The entire system
# between your source and the kernel is in this one file — which is the point.
#
# Threading model (ITC):
#   A "word" is a dictionary entry whose header is [ link | len | name ] followed
#   by a *codeword*: the address of the machine code that runs the word. A colon
#   definition's codeword points at `docol`; a primitive's points at its own code.
#
#   The CFA (code field address) is the address of the codeword cell — that is
#   what threaded code and EXECUTE jump through, and what FIND returns.
#
# Register conventions (the heart of a Forth engine):
#   %rsi  IP   — Forth instruction pointer: points at the next CFA in a thread
#   %rsp  DSP  — the data (parameter) stack; we use push/pop directly
#   %rbp  RSP  — the return stack (grows down), separate from the data stack
#   %rax  W    — scratch / the "working" register NEXT loads each step
#
# Helper routines (_word/_find/_number/_refill) are reached with call/ret. Since
# %rsp IS the data stack, the return address lives there transiently — safe only
# because these routines pass everything in registers and never touch the data
# stack. They must also preserve %rsi (the IP) across any syscall that uses it.

	.macro NEXT
	lodsq			# W = *IP ; IP += 8   (the next CFA)
	jmp *(%rax)		# jump to the code that CFA points at
	.endm

# ===========================================================================
	.text
	.global _start
_start:
	cld				# strings ascend: lodsq increments IP
	mov (%rsp), %rax		# argc (at entry %rsp -> [argc][argv0][argv1]...)
	mov %rax, var_argc
	lea 8(%rsp), %rax		# &argv[0]
	mov %rax, var_argv
	mov $return_stack_top, %rbp
	mov $data_stack_top, %rsp	# (the original %rsp/argv is now discarded)
	mov $cold_start, %rsi		# IP -> the cold-start thread (QUIT)
	NEXT

# docol — run by every colon definition: save caller's IP, enter this body.
docol:
	sub $8, %rbp
	mov %rsi, (%rbp)		# push IP onto return stack
	add $8, %rax			# W -> codeword; body begins one cell later
	mov %rax, %rsi
	NEXT

# dovar / doconst — runtime behaviours for `variable` / `constant` (cf. docol).
# On entry %rax = the word's CFA, so its data cell is at CFA+8.
dovar:					# ( -- addr )  push the data cell's address
	lea 8(%rax), %rdx
	push %rdx
	NEXT
doconst:				# ( -- n )  push the stored value
	mov 8(%rax), %rdx
	push %rdx
	NEXT

# ===========================================================================
# Internal words (no dictionary header — used only by threaded code, not typed).

EXIT:	.quad code_EXIT			# return from a colon definition
code_EXIT:
	mov (%rbp), %rsi		# pop IP off the return stack
	add $8, %rbp
	NEXT

LIT:	.quad code_LIT			# push the inline literal that follows
code_LIT:
	lodsq
	push %rax
	NEXT

BRANCH:	.quad code_BRANCH		# IP += inline offset (used for loops)
code_BRANCH:
	add (%rsi), %rsi
	NEXT

ZBRANCH: .quad code_ZBRANCH		# ( flag -- )  IP += inline offset if flag is 0
code_ZBRANCH:
	pop %rax
	test %rax, %rax
	jz .zbranch_take
	add $8, %rsi			# flag is true (nonzero): skip the offset cell
	NEXT
.zbranch_take:
	add (%rsi), %rsi		# flag is false (zero): take the branch
	NEXT

# ===========================================================================
# Dictionary. Each entry is packed (no alignment), so CFA = header + 9 + len:
#       .quad link      (8 bytes: address of previous header, 0 terminates)
#       .byte len       (1 byte: name length; high bits reserved for flags)
#       .ascii name
#   CFA:.quad code/docol
#       [body...]

h_DUP:	.quad 0
	.byte 3
	.ascii "dup"
DUP:	.quad code_DUP			# ( a -- a a )
code_DUP:
	mov (%rsp), %rax
	push %rax
	NEXT

h_DROP:	.quad h_DUP
	.byte 4
	.ascii "drop"
DROP:	.quad code_DROP			# ( a -- )
code_DROP:
	add $8, %rsp
	NEXT

h_SWAP:	.quad h_DROP
	.byte 4
	.ascii "swap"
SWAP:	.quad code_SWAP			# ( a b -- b a )
code_SWAP:
	pop %rax
	pop %rdx
	push %rax
	push %rdx
	NEXT

h_PLUS:	.quad h_SWAP
	.byte 1
	.ascii "+"
PLUS:	.quad code_PLUS			# ( a b -- a+b )
code_PLUS:
	pop %rax
	add %rax, (%rsp)
	NEXT

h_MINUS: .quad h_PLUS
	.byte 1
	.ascii "-"
MINUS:	.quad code_MINUS		# ( a b -- a-b )
code_MINUS:
	pop %rax			# b
	sub %rax, (%rsp)		# a -= b
	NEXT

h_STAR:	.quad h_MINUS
	.byte 1
	.ascii "*"
STAR:	.quad code_STAR			# ( a b -- a*b )
code_STAR:
	pop %rax
	pop %rdx
	imul %rdx, %rax
	push %rax
	NEXT

# DOT ( n -- )  print top of stack as a signed decimal + newline.
h_DOT:	.quad h_STAR
	.byte 1
	.ascii "."
DOT:	.quad code_DOT
code_DOT:
	pop %rax
	mov $numbuf+31, %rdi
	movb $10, (%rdi)		# trailing newline
	mov %rdi, %r9			# end of buffer
	xor %r10, %r10			# negative flag
	test %rax, %rax
	jns .Ldot_conv
	neg %rax
	mov $1, %r10
.Ldot_conv:
	mov $10, %rcx
.Ldot_digit:
	xor %rdx, %rdx
	div %rcx			# rax/=10 ; rdx = remainder
	add $'0', %dl
	dec %rdi
	mov %dl, (%rdi)
	test %rax, %rax
	jnz .Ldot_digit
	test %r10, %r10			# emit '-' if negative
	jz .Ldot_emit
	dec %rdi
	movb $'-', (%rdi)
.Ldot_emit:
	mov %r9, %rdx
	sub %rdi, %rdx
	inc %rdx			# length = end - start + 1
	push %rsi			# save IP (write uses %rsi)
	mov %rdi, %rsi
	mov $1, %rdi			# fd = stdout
	mov $1, %rax			# sys_write
	syscall
	pop %rsi
	NEXT

h_BYE:	.quad h_DOT
	.byte 3
	.ascii "bye"
BYE:	.quad code_BYE			# ( -- )  exit(0)
code_BYE:
	mov $60, %rax
	xor %rdi, %rdi
	syscall

# : ( -- )  read the next token as a name, build a dictionary header for it at
# HERE, and switch to compile mode. INTERPRET then compiles the body until ';'.
h_COLON: .quad h_BYE
	.byte 1
	.ascii ":"
COLON:	.quad code_COLON
code_COLON:
	call _word			# rdi = name ptr, rcx = len
	call _create			# build header; r9 = where the codeword goes
	movq $docol, (%r9)		# codeword = docol; this cell is the CFA
	add $8, %r9
	mov %r9, var_here		# body compiles from here on
	movq $1, var_state		# enter compile mode
	NEXT

# ; ( -- )  IMMEDIATE: compile EXIT to end the definition, leave compile mode.
h_SEMI:	.quad h_COLON
	.byte 0x81			# F_IMMEDIATE (0x80) | length 1
	.ascii ";"
SEMI:	.quad code_SEMI
code_SEMI:
	mov var_here, %r8
	movq $EXIT, (%r8)		# compile EXIT
	add $8, %r8
	mov %r8, var_here
	movq $0, var_state		# back to interpret mode
	NEXT

# ---------------------------------------------------------------------------
# Comparison primitives (Forth truth is -1 = all bits set, false = 0).

h_EQ:	.quad h_SEMI
	.byte 1
	.ascii "="
EQ:	.quad code_EQ			# ( a b -- flag )
code_EQ:
	pop %rax
	pop %rdx
	cmp %rax, %rdx
	sete %al
	movzbq %al, %rax
	neg %rax
	push %rax
	NEXT

h_LT:	.quad h_EQ
	.byte 1
	.ascii "<"
LT:	.quad code_LT			# ( a b -- flag )  signed a < b
code_LT:
	pop %rax			# b
	pop %rdx			# a
	cmp %rax, %rdx			# sets flags for a - b
	setl %al
	movzbq %al, %rax
	neg %rax
	push %rax
	NEXT

# ---------------------------------------------------------------------------
# Control flow. These are IMMEDIATE: they run during compilation, emitting
# branches and back-patching offsets, using the data stack to remember slots.
# Compiled layout, e.g.  if T then  ->  <0branch off> <T> ;  off skips T when
# the flag is false.  if T else E then  ->  <0branch o1> <T> <branch o2> <E> .

h_IF:	.quad h_LT
	.byte 0x82			# IMMEDIATE | len 2
	.ascii "if"
IF:	.quad code_IF			# ( -- slot )
code_IF:
	mov var_here, %r8
	movq $ZBRANCH, (%r8)		# compile 0branch
	add $8, %r8
	push %r8			# leave the offset slot to patch later
	movq $0, (%r8)			# placeholder offset
	add $8, %r8
	mov %r8, var_here
	NEXT

h_ELSE:	.quad h_IF
	.byte 0x84			# IMMEDIATE | len 4
	.ascii "else"
ELSE:	.quad code_ELSE			# ( slot -- slot' )
code_ELSE:
	pop %r10			# the if's 0branch slot
	mov var_here, %r8
	movq $BRANCH, (%r8)		# compile branch to jump over the else-part
	add $8, %r8
	push %r8			# leave this branch's slot for `then`
	movq $0, (%r8)
	add $8, %r8
	mov %r8, var_here		# here = start of the else-part
	mov var_here, %rax		# patch the if's 0branch to land here
	sub %r10, %rax
	mov %rax, (%r10)
	NEXT

h_THEN:	.quad h_ELSE
	.byte 0x84			# IMMEDIATE | len 4
	.ascii "then"
THEN:	.quad code_THEN			# ( slot -- )
code_THEN:
	pop %r8
	mov var_here, %rax
	sub %r8, %rax			# offset = here - slot
	mov %rax, (%r8)
	NEXT

h_BEGIN: .quad h_THEN
	.byte 0x85			# IMMEDIATE | len 5
	.ascii "begin"
BEGIN:	.quad code_BEGIN		# ( -- dest )
code_BEGIN:
	mov var_here, %r8
	push %r8			# loop-back target
	NEXT

h_UNTIL: .quad h_BEGIN
	.byte 0x85			# IMMEDIATE | len 5
	.ascii "until"
UNTIL:	.quad code_UNTIL		# ( dest -- )  compile 0branch back to dest
code_UNTIL:
	pop %r10			# dest from `begin`
	mov var_here, %r8
	movq $ZBRANCH, (%r8)
	add $8, %r8
	mov %r10, %rax
	sub %r8, %rax			# offset = dest - slot (negative: jump back)
	mov %rax, (%r8)
	add $8, %r8
	mov %r8, var_here
	NEXT

# ---------------------------------------------------------------------------
# Memory access and the dictionary pointer. Addresses are raw pointers; the
# dictionary grows up through dict_space, tracked by `here` (var_here).

h_FETCH: .quad h_UNTIL
	.byte 1
	.ascii "@"
FETCH:	.quad code_FETCH		# ( addr -- x )
code_FETCH:
	pop %rax
	mov (%rax), %rax
	push %rax
	NEXT

h_STORE: .quad h_FETCH
	.byte 1
	.ascii "!"
STORE:	.quad code_STORE		# ( x addr -- )
code_STORE:
	pop %rax			# addr
	pop %rdx			# x
	mov %rdx, (%rax)
	NEXT

h_CFETCH: .quad h_STORE
	.byte 2
	.ascii "c@"
CFETCH:	.quad code_CFETCH		# ( addr -- byte )
code_CFETCH:
	pop %rax
	movzbq (%rax), %rax
	push %rax
	NEXT

h_CSTORE: .quad h_CFETCH
	.byte 2
	.ascii "c!"
CSTORE:	.quad code_CSTORE		# ( byte addr -- )
code_CSTORE:
	pop %rax			# addr
	pop %rdx			# byte
	mov %dl, (%rax)
	NEXT

h_HERE:	.quad h_CSTORE
	.byte 4
	.ascii "here"
HERE:	.quad code_HERE			# ( -- addr )  the dictionary pointer
code_HERE:
	mov var_here, %rax
	push %rax
	NEXT

h_ALLOT: .quad h_HERE
	.byte 5
	.ascii "allot"
ALLOT:	.quad code_ALLOT		# ( n -- )  reserve n bytes
code_ALLOT:
	pop %rax
	add %rax, var_here
	NEXT

# variable / constant — create named storage. Both build a header via _create,
# then set a codeword (dovar/doconst) and the data cell.

h_VARIABLE: .quad h_ALLOT
	.byte 8
	.ascii "variable"
VARIABLE: .quad code_VARIABLE		# ( -- )  `variable foo` -> foo pushes its addr
code_VARIABLE:
	call _word			# rdi/rcx = name
	call _create			# r9 = CFA slot
	movq $dovar, (%r9)
	add $8, %r9
	movq $0, (%r9)			# one zero-initialised data cell
	add $8, %r9
	mov %r9, var_here
	NEXT

h_CONSTANT: .quad h_VARIABLE
	.byte 8
	.ascii "constant"
CONSTANT: .quad code_CONSTANT		# ( n -- )  `42 constant answer` -> answer pushes 42
code_CONSTANT:
	call _word			# value stays on the data stack beneath the retaddr
	call _create
	pop %rdx			# now take the value (stack is clean again)
	movq $doconst, (%r9)
	add $8, %r9
	mov %rdx, (%r9)			# store the constant
	add $8, %r9
	mov %r9, var_here
	NEXT

# ---------------------------------------------------------------------------
# Parsing, string compare, and text output — the toolkit anvil.fr will use to
# read source tokens, match names, and print a report. `word`/`find`/`number`
# expose the internal helpers; addr/len pairs point into the input buffer, so
# consume a token before the next refill.

h_WORD:	.quad h_CONSTANT
	.byte 4
	.ascii "word"
WORD:	.quad code_WORD			# ( -- addr len )  parse the next token
code_WORD:
	call _word			# rdi = ptr, rcx = len
	push %rdi
	push %rcx
	NEXT

h_FIND:	.quad h_WORD
	.byte 4
	.ascii "find"
FIND:	.quad code_FIND			# ( addr len -- cfa | 0 )  look up in the dictionary
code_FIND:
	pop %rcx			# len
	pop %rdi			# addr
	call _find			# rax = header or 0  (rdi,rcx preserved)
	test %rax, %rax
	jz .find_zero
	lea 9(%rax), %rdx		# header + 9 + len = CFA
	add %rcx, %rdx
	push %rdx
	NEXT
.find_zero:
	push %rax			# 0
	NEXT

h_NUMBER: .quad h_FIND
	.byte 6
	.ascii "number"
NUMBER:	.quad code_NUMBER		# ( addr len -- n flag )  flag = -1 if numeric
code_NUMBER:
	pop %rcx			# len
	pop %rdi			# addr
	call _number			# rax = value, rdx = 0 if ok
	push %rax			# n
	test %rdx, %rdx
	setz %al
	movzbq %al, %rax
	neg %rax			# -1 if parsed, 0 if not a number
	push %rax
	NEXT

h_SEQ:	.quad h_NUMBER
	.byte 2
	.ascii "s="
SEQ:	.quad code_SEQ			# ( a1 n1 a2 n2 -- flag )  string equality
code_SEQ:
	pop %r11			# n2
	pop %r10			# a2
	pop %rcx			# n1
	pop %rdi			# a1
	cmp %rcx, %r11
	jne .seq_false			# different lengths
.seq_loop:
	test %rcx, %rcx
	jz .seq_true
	movb (%rdi), %al
	movb (%r10), %dl
	cmp %al, %dl
	jne .seq_false
	inc %rdi
	inc %r10
	dec %rcx
	jmp .seq_loop
.seq_true:
	mov $-1, %rax
	push %rax
	NEXT
.seq_false:
	xor %rax, %rax
	push %rax
	NEXT

h_BCHAR: .quad h_SEQ
	.byte 0x86			# IMMEDIATE | len 6
	.ascii "[char]"
BCHAR:	.quad code_BCHAR		# compile-time: compile LIT <char>
code_BCHAR:
	call _word
	movzbq (%rdi), %rax
	mov var_here, %r8
	movq $LIT, (%r8)
	add $8, %r8
	mov %rax, (%r8)
	add $8, %r8
	mov %r8, var_here
	NEXT

h_EMIT:	.quad h_BCHAR
	.byte 4
	.ascii "emit"
EMIT:	.quad code_EMIT			# ( c -- )  write one byte to stdout
code_EMIT:
	pop %rax
	mov %al, emitbuf
	push %rsi			# save IP (write uses %rsi)
	mov $emitbuf, %rsi
	mov $1, %rdx
	mov $1, %rdi
	mov $1, %rax
	syscall
	pop %rsi
	NEXT

h_TYPE:	.quad h_EMIT
	.byte 4
	.ascii "type"
TYPE:	.quad code_TYPE			# ( addr len -- )  write a string to stdout
code_TYPE:
	pop %rdx			# len
	pop %rax			# addr
	push %rsi			# save IP
	mov %rax, %rsi			# buf
	mov $1, %rdi
	mov $1, %rax
	syscall
	pop %rsi
	NEXT

# cr — defined in the language, in terms of emit.
# ---------------------------------------------------------------------------
# Remaining glue primitives. The derivable ones (cr 1+ 1- 2dup 2drop nip and
# the like) now live in prelude.fr, defined in fr — load it for the full vocab.

h_XEXIT: .quad h_TYPE
	.byte 4
	.ascii "exit"
XEXIT:	.quad code_EXIT			# ( -- )  return early from a definition

h_AND:	.quad h_XEXIT
	.byte 3
	.ascii "and"
AND:	.quad code_AND			# ( a b -- a&b )  bitwise
code_AND:
	pop %rax
	and %rax, (%rsp)
	NEXT

h_OR:	.quad h_AND
	.byte 2
	.ascii "or"
OR:	.quad code_OR			# ( a b -- a|b )  bitwise
code_OR:
	pop %rax
	or %rax, (%rsp)
	NEXT

# while/repeat — mid-test loops. `while` is identical to `if` (compile 0branch +
# slot); `repeat` compiles a branch back to the `begin` target and patches the
# `while` 0branch to land just past it.  begin <test> while <body> repeat
h_WHILE: .quad h_OR
	.byte 0x85			# IMMEDIATE | len 5
	.ascii "while"
WHILE:	.quad code_IF			# ( dest -- dest slot )  reuses the if logic

h_REPEAT: .quad h_WHILE
	.byte 0x86			# IMMEDIATE | len 6
	.ascii "repeat"
REPEAT:	.quad code_REPEAT		# ( dest slot -- )
code_REPEAT:
	pop %r10			# slot (the while's 0branch)
	pop %r9				# dest (the begin target)
	mov var_here, %r8
	movq $BRANCH, (%r8)		# compile branch back to dest
	add $8, %r8
	mov %r9, %rax
	sub %r8, %rax			# offset = dest - branch slot
	mov %rax, (%r8)
	add $8, %r8
	mov %r8, var_here		# here = the loop's exit point
	mov var_here, %rax		# patch the while's 0branch to land here
	sub %r10, %rax
	mov %rax, (%r10)
	NEXT

# \ and ( — comments, IMMEDIATE so they also work while compiling. `\` skips to
# end of line; `(` skips to the next `)`. Both just advance the input cursor.
h_BSLASH: .quad h_REPEAT
	.byte 0x81			# IMMEDIATE | len 1
	.ascii "\\"
BSLASH:	.quad code_BSLASH		# ( -- )  skip rest of line
code_BSLASH:
.bslash_loop:
	mov inbuf_pos, %rax
	cmp inbuf_len, %rax
	jb .bslash_have
	call _refill			# comment runs past this chunk: pull more
	test %rax, %rax
	jz .bslash_done			# EOF -> comment ends at end of input
	jmp .bslash_loop
.bslash_have:
	movzbq inbuf(%rax), %rdx
	incq inbuf_pos
	cmp $10, %dl			# newline ends the comment
	jne .bslash_loop
.bslash_done:
	NEXT

h_PAREN: .quad h_BSLASH
	.byte 0x81			# IMMEDIATE | len 1
	.ascii "("
PAREN:	.quad code_PAREN		# ( -- )  skip to the next ')'
code_PAREN:
.paren_loop:
	mov inbuf_pos, %rax
	cmp inbuf_len, %rax
	jb .paren_have
	call _refill			# comment runs past this chunk: pull more
	test %rax, %rax
	jz .paren_done			# EOF -> comment ends at end of input
	jmp .paren_loop
.paren_have:
	movzbq inbuf(%rax), %rdx
	incq inbuf_pos
	cmp $41, %dl			# ')' ends the comment
	jne .paren_loop
.paren_done:
	NEXT

# ---------------------------------------------------------------------------
# Division, and dictionary introspection (for prelude.fr's number printing and
# a future self-hosted `see`).

h_DIV:	.quad h_PAREN
	.byte 1
	.ascii "/"
DIV:	.quad code_DIV			# ( a b -- a/b )  signed
code_DIV:
	pop %rcx
	pop %rax
	cqo				# sign-extend rax into rdx:rax
	idiv %rcx
	push %rax
	NEXT

h_MOD:	.quad h_DIV
	.byte 3
	.ascii "mod"
MOD:	.quad code_MOD			# ( a b -- a mod b )
code_MOD:
	pop %rcx
	pop %rax
	cqo
	idiv %rcx
	push %rdx			# remainder
	NEXT

h_LATEST: .quad h_MOD
	.byte 6
	.ascii "latest"
LATEST:	.quad code_LATEST		# ( -- header )  newest dictionary entry
code_LATEST:
	mov var_latest, %rax
	push %rax
	NEXT

# Return-stack access. These let the prelude define over/rot and let programs
# stash values. Contract: balance >r with r> within a word (don't EXIT with the
# return stack disturbed — it holds the caller's IP).
h_TOR:	.quad h_LATEST
	.byte 2
	.ascii ">r"
TOR:	.quad code_TOR			# ( x -- ) ( R: -- x )
code_TOR:
	pop %rax
	sub $8, %rbp
	mov %rax, (%rbp)
	NEXT

h_FROMR: .quad h_TOR
	.byte 2
	.ascii "r>"
FROMR:	.quad code_FROMR		# ( -- x ) ( R: x -- )
code_FROMR:
	mov (%rbp), %rax
	add $8, %rbp
	push %rax
	NEXT

h_RAT:	.quad h_FROMR
	.byte 2
	.ascii "r@"
RAT:	.quad code_RAT			# ( -- x ) ( R: x -- x )
code_RAT:
	mov (%rbp), %rax
	push %rax
	NEXT

# sys — push the address of a table of the headerless engine CFAs, so a Forth
# `see` can recognise them: [ docol, lit, exit, branch, 0branch ].
h_SYS:	.quad h_RAT
	.byte 3
	.ascii "sys"
SYS:	.quad code_SYS			# ( -- addr )
code_SYS:
	mov $systab, %rax
	push %rax
	NEXT

h_EXECUTE: .quad h_SYS
	.byte 7
	.ascii "execute"
EXECUTE: .quad code_EXECUTE		# ( cfa -- )  run the word with this CFA
code_EXECUTE:
	pop %rax
	jmp *(%rax)			# its NEXT/EXIT returns to our caller

# Data-stack introspection (for `depth` / `.s` / `trace` in the prelude). The
# data stack grows down from data_stack_top; the top item is at %rsp.
h_SPAT:	.quad h_EXECUTE
	.byte 3
	.ascii "sp@"
SPAT:	.quad code_SPAT			# ( -- addr )  address of the top item
code_SPAT:
	mov %rsp, %rax
	push %rax
	NEXT

h_SP0:	.quad h_SPAT
	.byte 3
	.ascii "sp0"
SP0:	.quad code_SP0			# ( -- addr )  the empty-stack base
code_SP0:
	mov $data_stack_top, %rax
	push %rax
	NEXT

# syscall3 — a raw Linux syscall with up to 3 arguments. The one primitive that
# opens the rest of the OS to fr: read/write/ioctl all take <=3 args, so this is
# enough for raw-tty input (ioctl TCGETS/TCSETS) and ANSI output — the unlock for
# a fully self-hosted, interactive ember. (We stop at 3 args because the 4th uses
# %r10 and the 6-arg form is rarely needed; extend the same way if mmap is wanted.)
# %rsi is the Forth IP, so arg2 is parked in %r8 and %rsi saved across the call.
h_SYSCALL3: .quad h_SP0
	.byte 8
	.ascii "syscall3"
SYSCALL3: .quad code_SYSCALL3		# ( a1 a2 a3 n -- ret )  n = syscall number
code_SYSCALL3:
	pop %rax			# syscall number
	pop %rdx			# arg3
	pop %r8				# arg2 (parked: %rsi holds the IP)
	pop %rdi			# arg1
	push %rsi			# save IP across the syscall
	mov %r8, %rsi			# arg2 -> %rsi
	syscall				# clobbers %rcx, %r11; result in %rax
	pop %rsi			# restore IP
	push %rax			# push the return value
	NEXT

# ===========================================================================
# Outer interpreter helpers (register-passing; never touch the data stack).

# _create — build a dictionary header for the name at %rdi/%rcx: link it in,
# update var_latest, copy the name. Returns %r9 = address where the codeword
# cell goes (i.e. the new word's CFA). Caller writes the codeword + any body.
_create:
	mov var_here, %r8		# header starts at HERE
	mov var_latest, %rax
	mov %rax, (%r8)			# link -> previous latest
	mov %r8, var_latest		# this is now the newest word
	mov %cl, 8(%r8)			# length byte (flags = 0)
	lea 9(%r8), %r9			# dest for the name
	mov %rdi, %r10			# src
	mov %rcx, %r11			# count
.create_copy:
	test %r11, %r11
	jz .create_done
	movb (%r10), %al
	movb %al, (%r9)
	inc %r9
	inc %r10
	dec %r11
	jmp .create_copy
.create_done:
	ret				# %r9 = address just past the name = the CFA

# _refill — read a chunk from the current input source into inbuf. The source is
# var_infd, which walks the argv files (argv[1..]) and then stdin (see _next_source).
# Returns %rax = bytes read, or 0 once *every* source is exhausted. The caller
# (_word, the comment words) treats 0 as the true end of input.
_refill:
.refill_again:
	push %rsi			# save Forth IP (read uses %rsi as buf)
	mov var_infd, %rdi		# fd of the current source
	mov $inbuf, %rsi
	mov $inbuf_size, %rdx
	xor %rax, %rax			# sys_read
	syscall
	pop %rsi
	test %rax, %rax
	jg .refill_ok			# >0 bytes read
	call _next_source		# EOF/error on this source -> move to the next
	test %rax, %rax
	jnz .refill_again		# a new source opened -> read it
	xor %rax, %rax			# nothing left anywhere
	mov %rax, inbuf_len
	mov %rax, inbuf_pos
	ret
.refill_ok:
	mov %rax, inbuf_len
	movq $0, inbuf_pos
	ret

# _next_source — close the current input (if it's a file) and open the next source:
# the argv files in order (argv[1..argc-1]), then stdin once. Returns %rax = 1 if a
# source is now open, 0 if all are exhausted. Preserves %rsi (the IP) across syscalls.
# This is what makes `./fr a.fr b.fr` load files and then drop to the stdin REPL.
_next_source:
	push %rsi			# protect the Forth IP across close/open
	mov var_infd, %rax
	cmp $2, %rax			# close real files only (skip -1 / 0 / 1 / 2)
	jle .ns_pick
	mov %rax, %rdi
	mov $3, %rax			# sys_close(fd)
	syscall
.ns_pick:
	mov var_argi, %rax
	cmp var_argc, %rax
	jae .ns_stdin			# no argv entries left -> stdin
	mov var_argv, %rdx
	mov (%rdx,%rax,8), %rdi		# filename = argv[argi]
	incq var_argi
	mov $2, %rax			# sys_open(name, O_RDONLY, 0)
	xor %rsi, %rsi			# flags = O_RDONLY (0)
	xor %rdx, %rdx			# mode (ignored)
	syscall				# %rax = fd or -errno
	test %rax, %rax
	js .ns_pick			# open failed: skip this file, try the next
	mov %rax, var_infd
	pop %rsi
	mov $1, %rax
	ret
.ns_stdin:
	mov var_stdin_used, %rax
	test %rax, %rax
	jnz .ns_none			# already consumed stdin -> truly done
	movq $1, var_stdin_used
	movq $0, var_infd		# fd 0 = stdin
	pop %rsi
	mov $1, %rax
	ret
.ns_none:
	pop %rsi
	xor %rax, %rax			# every source exhausted
	ret

# _word — parse the next whitespace-delimited token, copying it into `wordbuf`.
#   out: %rdi = pointer to the token (in wordbuf), %rcx = length (> 0)
# Copying means a token may straddle as many input refills as it likes — `inbuf`
# can be read in any chunk size (a pipe, a pty, a short read) without splitting a
# token. EOF while skipping whitespace is the normal end of input: exit(0).
_word:
.word_skip:
	mov inbuf_pos, %rax
	cmp inbuf_len, %rax
	jb .word_have
	call _refill
	test %rax, %rax
	jz .word_eof			# nothing left to read -> done
	jmp .word_skip
.word_have:
	movzbq inbuf(%rax), %rdx
	cmp $' ', %dl
	je .word_eat
	cmp $9, %dl			# tab
	je .word_eat
	cmp $10, %dl			# LF
	je .word_eat
	cmp $13, %dl			# CR
	je .word_eat
	jmp .word_start
.word_eat:
	incq inbuf_pos
	jmp .word_skip
.word_start:
	xor %rcx, %rcx			# token length (also the wordbuf write index)
.word_take:
	mov inbuf_pos, %rax
	cmp inbuf_len, %rax
	jb .word_char
	push %rcx			# preserve the token length: syscall clobbers %rcx
	call _refill			# ran out mid-token: pull the next chunk and continue
	pop %rcx
	test %rax, %rax
	jz .word_done			# EOF -> the token ends here
	jmp .word_take
.word_char:
	movzbq inbuf(%rax), %rdx
	cmp $' ', %dl
	je .word_done
	cmp $9, %dl
	je .word_done
	cmp $10, %dl
	je .word_done
	cmp $13, %dl
	je .word_done
	mov %dl, wordbuf(%rcx)		# copy the byte into the holding buffer
	incq inbuf_pos
	inc %rcx
	cmp $wordbuf_size, %rcx		# stop if the token is pathologically long
	jb .word_take
.word_done:
	mov $wordbuf, %rdi		# token now lives in wordbuf (survives refills)
	ret
.word_eof:
	mov $60, %rax			# input exhausted: exit(0)
	xor %rdi, %rdi
	syscall

# _find — look up a token in the dictionary.
#   in:  %rdi = token ptr, %rcx = length      (both preserved)
#   out: %rax = header address if found, else 0
_find:
	mov var_latest, %r8
.find_loop:
	test %r8, %r8
	jz .find_no
	movzbq 8(%r8), %rax		# name length (+ flags)
	and $0x7f, %al
	cmp %rax, %rcx
	jne .find_next
	lea 9(%r8), %r9			# dict name ptr
	mov %rdi, %r10			# token ptr
	mov %rcx, %r11			# count
.find_cmp:
	test %r11, %r11
	jz .find_match
	movb (%r9), %al
	movb (%r10), %dl
	cmp %al, %dl
	jne .find_next
	inc %r9
	inc %r10
	dec %r11
	jmp .find_cmp
.find_match:
	mov %r8, %rax			# return the header address
	ret
.find_next:
	mov (%r8), %r8			# follow link to previous entry
	jmp .find_loop
.find_no:
	xor %rax, %rax
	ret

# _number — parse a token as a signed decimal.
#   in:  %rdi = ptr, %rcx = length            (both preserved)
#   out: %rax = value, %rdx = 0 on success (nonzero = not a number)
_number:
	xor %rax, %rax
	test %rcx, %rcx
	jz .num_fail
	mov %rdi, %r8			# ptr
	mov %rcx, %r9			# remaining
	xor %r10, %r10			# negative flag
	movb (%r8), %dl
	cmp $'-', %dl
	jne .num_loop
	cmp $1, %r9			# bare "-" is not a number
	je .num_fail
	mov $1, %r10
	inc %r8
	dec %r9
.num_loop:
	movzbq (%r8), %rdx
	sub $'0', %rdx
	cmp $9, %rdx			# unsigned: >9 means not a digit
	ja .num_fail
	imul $10, %rax, %rax
	add %rdx, %rax
	inc %r8
	dec %r9
	jnz .num_loop
	test %r10, %r10
	jz .num_ok
	neg %rax
.num_ok:
	xor %rdx, %rdx
	ret
.num_fail:
	mov $1, %rdx
	ret

# INTERPRET — process exactly one token, then continue the QUIT loop.
INTERPRET: .quad code_INTERPRET
code_INTERPRET:
	call _word			# rdi=ptr, rcx=len  (EOF exits inside _refill)
	call _find			# rax = header or 0  (rdi,rcx preserved)
	test %rax, %rax
	jz .interp_num
	movzbq 8(%rax), %rdx		# flags+len byte
	mov %rdx, %r8
	and $0x7f, %r8			# name length
	lea 9(%rax), %r9
	add %r8, %r9			# r9 = CFA (header + 9 + len)
	mov var_state, %r10
	test %r10, %r10
	jz .interp_run			# interpret mode -> execute
	test $0x80, %dl			# compile mode: immediate words still execute
	jnz .interp_run
	mov var_here, %r11		# otherwise compile the CFA into the definition
	mov %r9, (%r11)
	add $8, %r11
	mov %r11, var_here
	NEXT
.interp_run:
	mov %r9, %rax
	jmp *(%rax)			# EXECUTE: the word's own NEXT/EXIT returns to QUIT
.interp_num:
	call _number			# rax=value, rdx=0 if ok
	test %rdx, %rdx
	jnz .interp_err
	mov var_state, %r10
	test %r10, %r10
	jz .interp_push
	mov var_here, %r11		# compile mode: compile  LIT <value>
	movq $LIT, (%r11)
	mov %rax, 8(%r11)
	add $16, %r11
	mov %r11, var_here
	NEXT
.interp_push:
	push %rax			# interpret mode: push the literal
	NEXT
.interp_err:
	push %rsi			# save IP; echo the unknown token + " ?"
	mov %rdi, %rsi			# (rdi/rcx still hold the token)
	mov %rcx, %rdx
	mov $1, %rdi
	mov $1, %rax
	syscall
	mov $errmsg, %rsi
	mov $errmsg_len, %rdx
	mov $1, %rdi
	mov $1, %rax
	syscall
	pop %rsi
	NEXT

# ===========================================================================
# Threaded code: the cold start and the REPL loop.

cold_start:
	.quad QUIT

# QUIT: interpret a token, branch back, forever. (EOF exits via _refill.)
QUIT:	.quad docol
.quit_loop:
	.quad INTERPRET
	.quad BRANCH
	.quad .quit_loop - .		# offset back to .quit_loop

# ===========================================================================
	.section .rodata
errmsg:	.ascii " ?\n"
	.equ errmsg_len, . - errmsg

	.data
var_latest: .quad h_SYSCALL3		# newest dictionary entry (head of FIND)
systab:     .quad docol, LIT, EXIT, BRANCH, ZBRANCH	# headerless engine CFAs (for `see`)
var_state:  .quad 0			# 0 = interpret, 1 = compile
var_here:   .quad dict_space		# next free byte for new definitions
inbuf_len:  .quad 0			# valid bytes currently in inbuf
inbuf_pos:  .quad 0			# parse cursor into inbuf
var_argc:   .quad 0			# argc, captured at _start
var_argv:   .quad 0			# &argv[0], captured at _start
var_argi:   .quad 1			# next argv index to open (argv[0] is the program)
var_stdin_used: .quad 0			# 1 once stdin has been used as a source
var_infd:   .quad -1			# current input fd; -1 = none open yet

	.bss
	.lcomm data_stack, 4096
	.equ   data_stack_top, data_stack + 4096
	.lcomm return_stack, 4096
	.equ   return_stack_top, return_stack + 4096
	.lcomm numbuf, 32
	.lcomm emitbuf, 8		# 1-byte scratch for `emit`
	.equ   inbuf_size, 65536	# stdin read buffer; any chunk size is fine now —
	.lcomm inbuf, inbuf_size	#   _word reassembles tokens that span refills
	.equ   wordbuf_size, 256	# holding buffer for one parsed token (copied out of inbuf)
	.lcomm wordbuf, wordbuf_size
	.equ   dict_size, 65536		# room for definitions created at runtime
	.lcomm dict_space, dict_size
