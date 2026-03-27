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
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# ──────────────────────────────────────────────────────────────────────────────
# file: famchain.S - famchain full node
# ──────────────────────────────────────────────────────────────────────────────

.altmacro
.option arch, +zicsr

# System hardware constants
.equ	EXIT_ADDR,		0x100000
.equ	EXIT_PASS,		0x5555
.equ	UART_BASE,		0x10000000
.equ	UART_RD_MASK,		0x1
.equ	UART_WR_MASK,		0x20
.equ	UART_LSR,		5
.equ	UART_RBR,		0
.equ	HEAP_MAX,		0x84000000		# 64MB limit from start of RAM
.equ	MM_HART_ID,		0

.equ	PLIC_BASE,		0x0c000000
.equ	PLIC_PRIO_10,		(PLIC_BASE + 0x28)	# 10 * 4 = 40 (0x28)
.equ	PLIC_MENABLE,		(PLIC_BASE + 0x2000)	# Machine Mode Enable
.equ	PLIC_MTHRESH,		(PLIC_BASE + 0x200000)	# Machine Mode Threshold
.equ	PLIC_MCLAIM,		(PLIC_BASE + 0x200004)	# Claim/Complete Register
.equ	DISK_IRQ,		1
.equ	PLIC_ENABLE_BASE,	0x0c002000
.equ	PLIC_MTHRESH_BASE,	0x0c200000
.equ	L_INTERS,		0x808			# MSIE (8) | MEIE (800)
.equ	MIE_GLOBAL,		0x8			# MIE (Global)
.equ	IPI_CAUSE,		0x80000003		# mcause for an IPI
.equ	EXTERNAL_CAUSE,		0x8000000B		# Machine External Interrupt
.equ	IPI_BASE,		0x02000000		# Base of the IPI memory loc

.macro LOAD_ADDRESS reg, label
_base\@:
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

_start:
j	main

mm_complete: .word		0x0

trap_handler:
	csrr    t0, mcause
        li      t1, IPI_CAUSE           # IPI
	beq	t0, t1, ipi_handler

	csrr		t0, mepc		# get mepc value
	addi		t0, t0, 4		# add 4
	csrw		mepc, t0		# csrw

	li a0, 'x'
	jal write_byte
	mret

ipi_handler:
	li      t0, IPI_BASE            # base
        slli    t1, tp, 2               # multiply by 4
        add     t0, t0, t1              # add to base
        sw      zero, 0(t0)             # zero the interrupt

	li a0, 'y'
	jal write_byte
	j exit
	mret

write_byte:	
	li		t0, UART_BASE		# UART Base
1:	lbu		t1, UART_LSR(t0)	# load state
	andi		t1, t1, UART_WR_MASK	# mask
	beqz		t1, 1b			# retry
	sb		a0, UART_RBR(t0)	# send to UART
	ret

exit:
	li		t0, EXIT_ADDR		# load exit addr
	li		t1, EXIT_PASS		# shutdown command
	sw		t1, UART_RBR(t0)	# signal UART
1:	wfi					# wait for interrupt in loop
	j		1b

main:
	li		sp, 0
	LOAD_ADDRESS	t0, trap_handler
	csrw		mtvec, t0
	csrr		tp, mhartid
	slli		t1, tp, 12
	li		t0, PLIC_MTHRESH
	add		t0, t0, t1
	sw		zero, 0(t0)
	li		t0, L_INTERS
	csrs		mie, t0
	li		t0, MIE_GLOBAL
	csrs		mstatus, t0

	ebreak

	li a0, '0'
	add a0, a0, tp
	jal write_byte

1:	wfi
	j		1b

data:
