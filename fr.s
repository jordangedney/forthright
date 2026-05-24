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
	mov $return_stack_top, %rbp
	mov $data_stack_top, %rsp
	mov $cold_start, %rsi		# IP -> the cold-start thread (QUIT)
	NEXT

# docol — run by every colon definition: save caller's IP, enter this body.
docol:
	sub $8, %rbp
	mov %rsi, (%rbp)		# push IP onto return stack
	add $8, %rax			# W -> codeword; body begins one cell later
	mov %rax, %rsi
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

# : SQUARE  DUP * ;   — a colon definition, in threaded form.
h_SQUARE: .quad h_BYE
	.byte 6
	.ascii "square"
SQUARE:	.quad docol			# ( n -- n*n )
	.quad DUP
	.quad STAR
	.quad EXIT

# : ( -- )  read the next token as a name, build a dictionary header for it at
# HERE, and switch to compile mode. INTERPRET then compiles the body until ';'.
h_COLON: .quad h_SQUARE
	.byte 1
	.ascii ":"
COLON:	.quad code_COLON
code_COLON:
	call _word			# rdi = name ptr, rcx = len
	mov var_here, %r8		# new header starts at HERE
	mov var_latest, %rax
	mov %rax, (%r8)			# link -> previous latest
	mov %r8, var_latest		# this is now the newest word
	mov %cl, 8(%r8)			# length byte (flags = 0)
	lea 9(%r8), %r9			# copy the name: dest
	mov %rdi, %r10			# src
	mov %rcx, %r11			# count
.colon_copy:
	test %r11, %r11
	jz .colon_done
	movb (%r10), %al
	movb %al, (%r9)
	inc %r9
	inc %r10
	dec %r11
	jmp .colon_copy
.colon_done:
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
# Stack + comparison primitives (Forth truth is -1 = all bits set, false = 0).

h_OVER:	.quad h_SEMI
	.byte 4
	.ascii "over"
OVER:	.quad code_OVER			# ( a b -- a b a )
code_OVER:
	mov 8(%rsp), %rax
	push %rax
	NEXT

h_NEGATE: .quad h_OVER
	.byte 6
	.ascii "negate"
NEGATE:	.quad code_NEGATE		# ( n -- -n )
code_NEGATE:
	negq (%rsp)
	NEXT

h_EQ:	.quad h_NEGATE
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

h_GT:	.quad h_LT
	.byte 1
	.ascii ">"
GT:	.quad code_GT			# ( a b -- flag )  signed a > b
code_GT:
	pop %rax
	pop %rdx
	cmp %rax, %rdx
	setg %al
	movzbq %al, %rax
	neg %rax
	push %rax
	NEXT

h_ZEQ:	.quad h_GT
	.byte 2
	.ascii "0="
ZEQ:	.quad code_ZEQ			# ( n -- flag )
code_ZEQ:
	pop %rax
	test %rax, %rax
	setz %al
	movzbq %al, %rax
	neg %rax
	push %rax
	NEXT

# ---------------------------------------------------------------------------
# Control flow. These are IMMEDIATE: they run during compilation, emitting
# branches and back-patching offsets, using the data stack to remember slots.
# Compiled layout, e.g.  if T then  ->  <0branch off> <T> ;  off skips T when
# the flag is false.  if T else E then  ->  <0branch o1> <T> <branch o2> <E> .

h_IF:	.quad h_ZEQ
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

# ===========================================================================
# Outer interpreter helpers (register-passing; never touch the data stack).

# _refill — read a chunk of stdin into inbuf. On EOF, exit(0).
_refill:
	push %rsi			# save Forth IP (read uses %rsi as buf)
	xor %rdi, %rdi			# fd = stdin
	mov $inbuf, %rsi
	mov $inbuf_size, %rdx
	xor %rax, %rax			# sys_read
	syscall
	pop %rsi
	test %rax, %rax
	jle .refill_eof			# 0 = EOF, <0 = error
	mov %rax, inbuf_len
	movq $0, inbuf_pos
	ret
.refill_eof:
	mov $60, %rax
	xor %rdi, %rdi
	syscall

# _word — parse the next whitespace-delimited token.
#   out: %rdi = pointer to token bytes (inside inbuf), %rcx = length (> 0)
# Note: a token is assumed not to straddle a refill (fine for line input).
_word:
.word_skip:
	mov inbuf_pos, %rax
	cmp inbuf_len, %rax
	jb .word_have
	call _refill
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
	mov inbuf_pos, %rax
	lea inbuf(%rax), %rdi		# token pointer
	xor %rcx, %rcx			# length
.word_take:
	mov inbuf_pos, %rax
	cmp inbuf_len, %rax
	jae .word_done
	movzbq inbuf(%rax), %rdx
	cmp $' ', %dl
	je .word_done
	cmp $9, %dl
	je .word_done
	cmp $10, %dl
	je .word_done
	cmp $13, %dl
	je .word_done
	incq inbuf_pos
	inc %rcx
	jmp .word_take
.word_done:
	ret

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
var_latest: .quad h_UNTIL		# newest dictionary entry (head of FIND)
var_state:  .quad 0			# 0 = interpret, 1 = compile
var_here:   .quad dict_space		# next free byte for new definitions
inbuf_len:  .quad 0			# valid bytes currently in inbuf
inbuf_pos:  .quad 0			# parse cursor into inbuf

	.bss
	.lcomm data_stack, 4096
	.equ   data_stack_top, data_stack + 4096
	.lcomm return_stack, 4096
	.equ   return_stack_top, return_stack + 4096
	.lcomm numbuf, 32
	.equ   inbuf_size, 4096
	.lcomm inbuf, inbuf_size
	.equ   dict_size, 65536		# room for definitions created at runtime
	.lcomm dict_space, dict_size
