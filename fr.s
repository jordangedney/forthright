# forthright — a freestanding indirect-threaded-code Forth for x86-64 Linux.
#
# No libc, no runtime: just raw syscalls and threaded code. The entire system
# between your source and the kernel is in this one file — which is the point.
#
# Threading model (ITC):
#   A "word" is a dictionary entry whose first cell is a *codeword*: the address
#   of the machine code that runs the word. A colon-definition's codeword points
#   at `docol`; a primitive's codeword points at its own code.
#
# Register conventions (the heart of a Forth engine):
#   %rsi  IP   — Forth instruction pointer: points at the next codeword-address
#   %rsp  DSP  — the data (parameter) stack; we use push/pop directly
#   %rbp  RSP  — the return stack (grows down), separate from the data stack
#   %rax  W    — scratch / the "working" register NEXT loads each step
#
# NEXT is the inner interpreter: fetch the next word's codeword address into W,
# then jump through it to the word's code. Everything else is built on this.

	.macro NEXT
	lodsq			# W = *IP ; IP += 8   (the next codeword-field addr)
	jmp *(%rax)		# jump to the code that field points at
	.endm

# ---------------------------------------------------------------------------
	.text
	.global _start
_start:
	cld				# strings ascend: lodsq increments IP
	mov $return_stack_top, %rbp	# init return stack
	mov $data_stack_top, %rsp	# init data stack
	mov $cold_start, %rsi		# point IP at the cold-start thread
	NEXT				# ...and we're off

# docol — the code run by every colon definition. Save the caller's IP on the
# return stack, then dive into this word's body (the cells after the codeword).
docol:
	sub $8, %rbp			# push IP onto return stack
	mov %rsi, (%rbp)
	add $8, %rax			# W -> codeword; body begins one cell later
	mov %rax, %rsi
	NEXT

# ---------------------------------------------------------------------------
# Primitives. Each is [ codeword field ][ code ]; the codeword points at the code.

EXIT:	.quad code_EXIT			# ( -- )  return from a colon definition
code_EXIT:
	mov (%rbp), %rsi		# pop IP off the return stack
	add $8, %rbp
	NEXT

LIT:	.quad code_LIT			# ( -- n )  push the inline literal that follows
code_LIT:
	lodsq				# the next cell in the thread is the value
	push %rax
	NEXT

DUP:	.quad code_DUP			# ( a -- a a )
code_DUP:
	mov (%rsp), %rax
	push %rax
	NEXT

DROP:	.quad code_DROP			# ( a -- )
code_DROP:
	add $8, %rsp
	NEXT

SWAP:	.quad code_SWAP			# ( a b -- b a )
code_SWAP:
	pop %rax
	pop %rdx
	push %rax
	push %rdx
	NEXT

PLUS:	.quad code_PLUS			# ( a b -- a+b )
code_PLUS:
	pop %rax
	add %rax, (%rsp)
	NEXT

STAR:	.quad code_STAR			# ( a b -- a*b )
code_STAR:
	pop %rax
	pop %rdx
	imul %rdx, %rax
	push %rax
	NEXT

# DOT ( n -- )  print the top of stack as an unsigned decimal, then a newline.
# %rsi is the Forth IP, so we save/restore it around the write syscall.
DOT:	.quad code_DOT
code_DOT:
	pop %rax			# n
	mov $numbuf+31, %rdi		# build the string from the end
	movb $10, (%rdi)		# trailing newline
	mov %rdi, %r9			# remember the end of the buffer
	mov $10, %rcx			# divisor
.Ldigit:
	xor %rdx, %rdx
	div %rcx			# rax = rax/10 ; rdx = rax%10
	add $'0', %dl
	dec %rdi
	mov %dl, (%rdi)			# emit one digit (least significant first)
	test %rax, %rax
	jnz .Ldigit
	mov %r9, %rdx			# rdx = length = end - start + 1
	sub %rdi, %rdx
	inc %rdx
	push %rsi			# save Forth IP (we need %rsi for the syscall)
	mov %rdi, %rsi			# buf
	mov $1, %rdi			# fd = stdout
	mov $1, %rax			# sys_write
	syscall
	pop %rsi			# restore Forth IP
	NEXT

BYE:	.quad code_BYE			# ( -- )  exit(0)
code_BYE:
	mov $60, %rax			# sys_exit
	xor %rdi, %rdi
	syscall

# ---------------------------------------------------------------------------
# Threaded code. These are pure data: lists of codeword-field addresses that
# NEXT walks. cold_start is where the engine begins.

cold_start:
	.quad main

# : SQUARE  DUP * ;
SQUARE:
	.quad docol
	.quad DUP
	.quad STAR
	.quad EXIT

# main: prove the engine. "5 SQUARE ." -> 25 ; "2 3 + ." -> 5 ; then exit.
main:
	.quad docol
	.quad LIT, 5
	.quad SQUARE
	.quad DOT
	.quad LIT, 2
	.quad LIT, 3
	.quad PLUS
	.quad DOT
	.quad BYE

# ---------------------------------------------------------------------------
	.bss
	.lcomm data_stack, 4096
	.equ   data_stack_top, data_stack + 4096
	.lcomm return_stack, 4096
	.equ   return_stack_top, return_stack + 4096
	.lcomm numbuf, 32
