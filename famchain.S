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
.equ	MAX_HARTS,		4
.equ	STACK_SHIFT, 17		# 2^17 = 128 KiB
.equ	STACK_SIZE,	(1 << STACK_SHIFT)

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

.macro DECR_STACK	size
	addi sp, sp, -\size
	blt		sp, s11, stack_panic
.endm

.macro INCR_STACK	size
	addi		sp, sp, \size
.endm

.set _macro_depth, 0

.macro _def_restore_macro depth, sz, regs:vararg
	.macro _do_tear_down_\depth
	.ifnc "\regs", ""
		.set _off, 8
		.irp reg, \regs
		lw \reg, _off(sp)
		.set _off, _off + 8
		.endr
	.endif
	lw ra, 0(sp)
	INCR_STACK \sz
	.endm
.endm

.macro _exec_tear_down depth
	_do_tear_down_\depth
.endm

.macro _kill_tear_down depth
	.purgem _do_tear_down_\depth
.endm

# Macro to setup list of registers. Save all to stack
.macro SETUP regs:vararg
	.set _macro_depth, _macro_depth + 1

	.set _cnt, 1
	.ifnc "\regs", ""
	.irp item, \regs
		.set _cnt, _cnt + 1
	.endr
	.endif
	.set _sz, ((_cnt * 4) + 15) & -16

	_def_restore_macro %_macro_depth, %_sz, \regs


	DECR_STACK _sz
	sw	ra, 0(sp)
	.ifnc "\regs", ""
	.set _off, 4
	.irp reg, \regs
		sw \reg, _off(sp)
		.set _off, _off + 4
	.endr
	.endif
.endm

# Tear down the stack (LIFO order for stack frames)
.macro TEAR_DOWN
	_exec_tear_down %_macro_depth
	_kill_tear_down %_macro_depth
	.set _macro_depth, _macro_depth - 1
.endm

.macro RETURN
	TEAR_DOWN
	ret
.endm


_start:
j	main

mm_complete: .word		0x0

trap_handler:
	DECR_STACK	128
	sw		t0, 0(sp)
	sw		t1, 4(sp)
	csrr		t0, mcause
	li		t1, IPI_CAUSE
	beq		t0, t1, ipi_handler

	csrr		t0, mepc
	addi		t0, t0, 4
	sw		t0, 8(sp)
	csrr		t0, mstatus
	sw		t0, 12(sp)

	jal             proc_exception

	j		end_trap
ipi_handler:
	csrr            t0, mepc
        sw              t0, 8(sp)
	csrr		t0, mstatus
	sw		t0, 12(sp)

	jal		proc_ipi

end_trap:
	lw              t0, 8(sp)
	csrw		mepc, t0
	lw		t0, 12(sp)
	csrw		mstatus, t0
	lw		t0, 0(sp)
	lw		t1, 4(sp)
	INCR_STACK	128
	mret

trap_handler1:
	SETUP		t0, t1, t2, t3, t4, t5, t6, a0, a1, a2, a3, a4, a5, a6, a7, s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10
	DECR_STACK	16
	csrr		t0, mepc 
	csrr		t1, mcause
	li		t2, IPI_CAUSE
	beq		t1, t2, 1f
	addi		t0, t0, 4
1:
	sw		t0, 0(sp)

	csrr		t0, mcause
	li		t1, IPI_CAUSE		# IPI
	beq		t0, t1, ipi_handler


	jal		proc_exception
	j		end_trap

ipi_handler1:
	li		t0, IPI_BASE		# base
	slli		t1, tp, 2		# multiply by 4
	add		t0, t0, t1		# add to base
	sw		zero, 0(t0)		# zero the interrupt

	jal		proc_ipi

end_trap1:
	lw	t0, 0(sp)
	csrw	mepc, t0
	INCR_STACK	16
	TEAR_DOWN
	mret

proc_exception:
	mv t6, ra
	li a0, 'x'
	jal write_byte
	li a0, '0'
	add a0, a0, tp
	jal write_byte
	mv ra, t6
	ret

proc_ipi:
	li a0, 'y'
	jal write_byte
	li a0, '0'
	add a0, a0, tp
	jal write_byte
	ret

print_hex:
	SETUP		s0, s1, s2, t0, t1, t2, a0
	
	mv		s0, a0		# Save original value
	li		s2, 0		# flag = 0 (skipping leading)

	# Print "0x" prefix 
	li		a0, '0' 
	jal		write_byte
	li		a0, 'x'
	jal		write_byte	
	
	# Special Case: If value is 0, just print '0' and exit
	bnez		s0, 1f
	li		a0, '0'
	jal		write_byte
	j		4f

1:	li		s1, 28		# Start at highest nibble
2:
	srl		t2, s0, s1		# Isolate nibble
	andi		t2, t2, 0xF

	# Skip leading zeros logic
	bnez		t2, 3f		# If nibble != 0, start
	bnez		s2, 3f		# If already started, print
	j		next_nibble		# Otherwise, skip

3:	li		s2, 1		# Flip "started" flag

	# Convert nibble to ASCII
	li		a0, 10
	blt		t2, a0, 5f		# If 0-9
	addi		t2, t2, 7		# Adjust for A-F
5:	addi		a0, t2, 48		# ASCII '0'
	jal		write_byte

next_nibble:
	addi		s1, s1, -4		# Move to next 4 bits
	bgez		s1, 2b

4:	RETURN


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
	csrr		tp, mhartid
	li		t0, MAX_HARTS
	bge		tp, t0, park
	LOAD_ADDRESS	sp, data
	addi		sp, sp, 15
	andi		sp, sp, -16
	addi		t0, tp, 1
	slli		t0, t0, STACK_SHIFT
	add		sp, sp, t0
	li		s11, STACK_SIZE
	sub		s11, sp, s11

	li		a0, 't'
	jal		write_byte

	LOAD_ADDRESS	t0, trap_handler
	csrw		mtvec, t0
	slli		t1, tp, 12
	li		t0, PLIC_MTHRESH
	add		t0, t0, t1
	sw		zero, 0(t0)
	li		t0, L_INTERS
	csrs		mie, t0
	li		t0, MIE_GLOBAL
	csrs		mstatus, t0

	ebreak
	ebreak

park:
1:	wfi
	j		1b

data:
