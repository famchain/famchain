# MIT License
#
# Copyright (c) 2026 Christopher Gilliard
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# ──────────────────────────────────────────────────────────────────────────────
# famc.S - fam compiler (GNU as src)
# ──────────────────────────────────────────────────────────────────────────────

# System Constants
.equ	EXIT_ADDR,	0x100000
.equ	EXIT_PASS,	0x5555
.equ	UART_BASE,	0x10000000
.equ	UART_RD_MASK,	0x1
.equ	UART_WR_MASK,	0x20
.equ	UART_LSR,	5
.equ	UART_RBR,	0

.macro LOAD_ADDRESS reg, label
_base\@:
	# Uses \@ to make a unique constant name for every expansion
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

.macro ALLOC_STACK	size
	addi		sp, sp, -\size		# Allocate bytes on stack
	blt		sp, gp, stack_panic	# panic if stack overflow
	sd		ra, 0(sp)		# Always store ra
.endm

.macro DEALLOC_STACK size
	ld		ra, 0(sp)		# Restore ra
	addi		sp, sp, \size		# Deallocate bytes on stack
.endm

.macro BUMP_HEAP	size
	addi		gp, gp, \size		# update gp
	bgt		gp, sp, stack_panic	# stack overflow
.endm

.macro PRINT label
	ALLOC_STACK	48
	sd		t0, 8(sp)
	sd		t1, 16(sp)
	sd		t2, 24(sp)
	sd		t3, 32(sp)
	sd		a0, 40(sp)

	LOAD_ADDRESS	a0, \label
	jal		print_str

	ld		t0, 8(sp)
	ld		t1, 16(sp)
	ld		t2, 24(sp)
	ld		t3, 32(sp)
	ld		a0, 40(sp)
	DEALLOC_STACK	48
.endm

.macro PRINTLN label
	ALLOC_STACK	48
	sd		t0, 8(sp)
	sd		t1, 16(sp)
	sd		t2, 24(sp)
	sd		t3, 32(sp)
	sd		a0, 40(sp)

	LOAD_ADDRESS	a0, \label
	jal		print_str
	li		a0, '\n'
	jal		write_byte

	ld		t0, 8(sp)
	ld		t1, 16(sp)
	ld		t2, 24(sp)
	ld		t3, 32(sp)
	ld		a0, 40(sp)
	DEALLOC_STACK	48
.endm

_start:
	LOAD_ADDRESS	gp data			# Load heap ptr
	li		sp, 1			# Setup stack pointer
	slli		sp, sp, 26		# 64 MiB
	add		sp, sp, gp		# Init stack at heap + 64 MiB
	andi		sp, sp, -16		# Align stack to 16 bytes
	mv		tp, sp			# Use tp for output buffer

	jal		read_data
	jal		parse
	jal		write_data
	j		exit


.macro PIC_STRING label, text
    \label:
        .asciz "\text" # 2. The string + null terminator (\0)
    x_\label:
	.asciz "\text"
.endm

PIC_STRING vx "ab cde"


parse:
	ALLOC_STACK	32
	sd		t0, 8(sp)
	sd		t1, 16(sp)
	sd		t2, 24(sp)

	mv		t0, a0
	mv		t1, a1
	mv		t2, tp

1:
	beq		t0, t1, 2f
	lbu		t3, 0(t0)
	sb		t3, 0(t2)

	PRINTLN vx

	addi		t2, t2, 1
	addi		t0, t0, 1
	j		1b

2:	mv a0, tp 
	mv a1, t2 

	ld		t0, 8(sp)
	ld		t1, 16(sp)
	ld		t2, 24(sp)
	DEALLOC_STACK	32
	ret

read_data:
	ALLOC_STACK	16
	sd		s0, 8(sp)		# store s0

	mv		s0, gp			# set s0 to gp
1:	jal		read_byte		# read next byte
	li		t0, 4			# load EOT
	beq		a0, t0, 2f		# if EOT exit loop
	sb		a0, 0(gp)		# store byte
	BUMP_HEAP	1			# increment heap
	j		1b			# repeat
2:	mv		a0, s0			# save start of input
	mv		a1, gp			# save end of input

	ld		s0, 8(sp)		# restore s0
	DEALLOC_STACK	16
	ret

write_nop:
	ALLOC_STACK	16
	li		a0, 0x13
	jal		write_byte
	li		a0, 0x00
	jal		write_byte
	jal		write_byte
	jal		write_byte
	DEALLOC_STACK	16
	ret

write_data:
	ALLOC_STACK	32
	sd		s0, 8(sp)
	sd		s1, 16(sp)

	mv		s0, a0
	mv		s1, a1
	jal		write_nop
	
1:
	beq		s0, s1, 2f
	lbu		a0, 0(s0)
	jal		write_byte
	addi		s0, s0, 1
	j		1b
2:
	ld		s0, 8(sp)
	ld		s1, 16(sp)
	
	DEALLOC_STACK	32
	ret

stack_panic:		
	LOAD_ADDRESS	a0 msg_stack_overflow
	jal		print_str
	li		a0, '\n'
	jal		write_byte
	j		exit


print_str:
	li		t3, UART_BASE
	mv		t1, a0
1:	lbu		t0, 0(t1)
	beqz		t0, 2f
	lbu		t2, UART_LSR(t3)	# check status
	andi		t2, t2, UART_WR_MASK	# mask
	beqz		t2, 1b			# retry
	sb		t0, UART_RBR(t3)	# send to UART
	addi		t1, t1, 1		# Next char
	j		1b			# Loop back
2:
	ret 

read_byte:
	li		t0, UART_BASE		
1:	
	lbu		t1, UART_LSR(t0)	# Read from UART
	andi		t1, t1, UART_RD_MASK	# mask
	beqz		t1, 1b			# if not ready read again
	lbu		a0, UART_RBR(t0)	# Get current char, store x30
	ret	

write_byte:
	li		t0, UART_BASE
1:	lbu		t1, UART_LSR(t0)
	andi		t1, t1, UART_WR_MASK	# mask
	beqz		t1, 1b			# retry
	sb		a0, UART_RBR(t0)	# send to UART
	ret

exit:	
	li		t0, EXIT_ADDR		# load exit addr
	li		t1, EXIT_PASS		# shutdown command
	sw		t1, UART_RBR(t0)
1:	wfi
	j		1b

msg_stack_overflow: .string "stack overflow!"
msg: .string "Hello world!"
data:
