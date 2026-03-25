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

# System hardware constants
.equ	EXIT_ADDR,	0x100000
.equ	EXIT_PASS,	0x5555
.equ	UART_BASE,	0x10000000
.equ	UART_RD_MASK,	0x1
.equ	UART_WR_MASK,	0x20
.equ	UART_LSR,	5
.equ	UART_RBR,	0
.equ	HEAP_MAX,	0x84000000		# 64MB limit from start of RAM


.macro LOAD_ADDRESS reg, label
_base\@:
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

.macro BUMP_HEAP	size
	LOAD_ADDRESS	t3, global_ptr
	li		t1, 1
	LOAD_ADDRESS	t0, global_lock
1:	amoswap.w.aq	t2, t1, (t0)
	bnez		t2, 1b
	ld		t2, 0(t3)
	li		t4, \size
	mv		a0, t2
	add		t2, t2, t4
	li		t5, HEAP_MAX
	bgeu		t2, t5, heap_panic
	sd		t2, 0(t3)
	amoswap.w.rl	t2, zero, (t0)
.endm

.macro DECR_STACK	size
	li		t6, \size
	sub		sp, sp, t6
	blt		sp, s11, stack_panic
.endm

.macro INCR_STACK	size
	li		t0, \size
	add		sp, sp, t0
.endm

.macro INIT_STACK size
	LOAD_ADDRESS	t0 boot_lock
	li		t1, 1
	amoadd.w.aq	tp, t1, (t0)
	bnez		tp, 1f 
	LOAD_ADDRESS	gp, data
	li		t0, 15
	add		gp, gp, t0	
	li		t0, -16
	and		gp, gp, t0

	LOAD_ADDRESS	t0, global_ptr
	sd		gp, 0(t0)
	li		t1, 1
	LOAD_ADDRESS	t0 complete_lock
	amoadd.w.rl	t1, t1, (t0)
1:
	LOAD_ADDRESS	t0, complete_lock
2:	lw		t1, 0(t0)
	beqz		t1, 2b
	BUMP_HEAP	\size
	li		t0, \size
	add		sp, a0, t0
	addi		s11, a0, 0
.endm

.set _macro_depth, 0

.macro _def_restore_macro depth, sz, regs:vararg
	.macro _do_tear_down_\depth
	.ifnc "\regs", ""
		.set _off, 8
		.irp reg, \regs
		ld \reg, _off(sp)
		.set _off, _off + 8
		.endr
	.endif
	ld ra, 0(sp)
	INCR_STACK \sz
	.endm
.endm

.macro _exec_tear_down depth
	_do_tear_down_\depth
.endm

.macro _kill_tear_down depth
	.purgem _do_tear_down_\depth
.endm

# -----------------------------------------------------------------------------
# CORE PRIMITIVES for chacha20
# -----------------------------------------------------------------------------

.macro rotl32 reg, amount
	slliw	t5, \reg, \amount	# Shift left by immediate
	srliw	t6, \reg, (32 - \amount) # Shift right by (32 - amount)
	or	\reg, t5, t6		# Combine
.endm

# a, b, d: registers holding the state words
# n: rotation amount (immediate)
.macro QR_STEP a, b, d, n
	addw	\a, \a, \b	# a += b
	xor	\d, \d, \a	# d ^= a
	rotl32	\d, \n		# rotl
.endm

# a, b, c, d are the 4 registers you're working on
.macro CHACHA_QR a, b, c, d
	QR_STEP \a, \b, \d, 16	# Step 1: d is rotated
	QR_STEP \c, \d, \b, 12	# Step 2: b is rotated
	QR_STEP \a, \b, \d, 8	# Step 3: d is rotated
	QR_STEP \c, \d, \b, 7	# Step 4: b is rotated
.endm

# x[0-10] = s0-s10, x[11-15] = t0-t4
.macro CHACHA_ROUNDS
	li		a7, 10		# 10 double-rounds = 20 rounds
1:
	# --- Column Rounds ---
	#           a   b   c   d
	CHACHA_QR	s0, s4, s8, t1	# Column 0: x[0], x[4], x[8], x[12]
	CHACHA_QR	s1, s5, s9, t2	# Column 1: x[1], x[5], x[9], x[13]
	CHACHA_QR	s2, s6, s10, t3	# Column 2: x[2], x[6], x[10], x[14]
	CHACHA_QR	s3, s7, t0, t4	# Column 3: x[3], x[7], x[11], x[15]

	# --- Diagonal Rounds ---
	#           a   b   c   d
	CHACHA_QR	s0, s5, s10, t4	# Diag 1: x[0], x[5], x[10], x[15]
	CHACHA_QR	s1, s6, t0, t1	# Diag 2: x[1], x[6], x[11], x[12]
	CHACHA_QR	s2, s7, s8, t2	# Diag 3: x[2], x[7], x[8],  x[13]
	CHACHA_QR	s3, s4, s9, t3	# Diag 4: x[3], x[4], x[9],  x[14]

	addi	a7, a7, -1		# Loop counter i -= 2 (effectively)
	bnez	a7, 1b
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
	.set _sz, ((_cnt * 8) + 15) & -16

	_def_restore_macro %_macro_depth, %_sz, \regs


	DECR_STACK _sz
	sd	ra, 0(sp)
	.ifnc "\regs", ""
	.set _off, 8
	.irp reg, \regs
		sd \reg, _off(sp)
		.set _off, _off + 8
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

.macro PRINT_NUM r
	SETUP		a0, t0, t1, t2
	mv		a0, \r
	jal		print_dec
	TEAR_DOWN
.endm

.macro PRINT_HEX r
	SETUP		a0, t0, t1, t2
	mv		a0, \r
	jal		print_hex
	TEAR_DOWN
.endm

.macro PRINT_LABEL label
	SETUP		t0, t1, t2, t3, a0
	LOAD_ADDRESS	a0, \label
	jal		print_str
	TEAR_DOWN
.endm

.macro PIC_STRING label, text
	\label:
	.asciz "\text"	
	x_\label:
	.asciz "\text"
.endm

.macro PRINT text:vararg
	j	_pic_jump\@
	PIC_STRING _pic_str\@, \text
	_pic_jump\@:
	PRINT_LABEL _pic_str\@
.endm

.macro PANIC text:vararg
	PRINT		<\text>
	PRINT		<\n>
	j		exit
.endm

_start:
	j		main

# Put these here due to alignment requirements
global_ptr: .dword		0x0
boot_lock: .word		0x0
complete_lock: .word		0x0
global_lock: .word		0x0


exit:
	li		t0, EXIT_ADDR		# load exit addr
	li		t1, EXIT_PASS		# shutdown command
	sw		t1, UART_RBR(t0)	# signal UART
1:	wfi					# wait for interrupt in loop
	j		1b


read_byte:	
	li		t0, UART_BASE		# UART Base
1:	lbu		t1, UART_LSR(t0)	# Read from UART
	andi		t1, t1, UART_RD_MASK	# mask
	beqz		t1, 1b			# if not ready read again
	lbu		a0, UART_RBR(t0)	# Get current char, store a0
	ret

write_byte:	
	li		t0, UART_BASE		# UART Base
1:	lbu		t1, UART_LSR(t0)	# load state
	andi		t1, t1, UART_WR_MASK	# mask
	beqz		t1, 1b			# retry
	sb		a0, UART_RBR(t0)	# send to UART
	ret

heap_panic:
	PANIC heap overflow!!

stack_panic:
	li a0, 's'
	jal write_byte
	li a0, 't'
	jal write_byte
	li a0, 'a'
	jal write_byte
	li a0, 'c'
	jal write_byte
	li a0, 'k'
	jal write_byte
	li a0, ' '
	jal write_byte
	li a0, 'o'
	jal write_byte
	li a0, 'v'
	jal write_byte
	li a0, 'e'
	jal write_byte
	li a0, 'r'
	jal write_byte
	li a0, 'f'
	jal write_byte
	li a0, 'l'
	jal write_byte
	li a0, 'o'
	jal write_byte
	li a0, 'w'
	jal write_byte
	li a0, '!'
	jal write_byte
	li a0, '\n'
	jal write_byte
	j exit

print_dec:
	SETUP		s0, s1, s2
	DECR_STACK	32

	mv		s0, a0
	li		s1, 10
	li		s2, 0
	
	# 1. Handle Negative
	bgez		s0, 1f
	li		a0, '-'
	jal		write_byte
	neg		s0, s0

1:	# 2. Special Case: Zero
	bnez		s0, 2f
	li		a0, '0'
	jal		write_byte
	j		4f
	
2:	# 3. Generate Digits (Store at offset 32+)
	remu		t0, s0, s1
	divu		s0, s0, s1
	addi		t0, t0, 48		# Convert to ASCII

	mv		t1, sp		# Buffer start
	add		t1, t1, s2		# Buffer + index
	sb		t0, 0(t1)

	addi		s2, s2, 1
	bnez		s0, 2b

3:	# 4. Print Digits (Reverse)
	addi		s2, s2, -1
	mv		t1, sp
	add		t1, t1, s2
	lbu		a0, 0(t1)
	jal		write_byte
	bnez		s2, 3b

4:
	INCR_STACK	32
	RETURN

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

1:	li		s1, 60		# Start at highest nibble
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

print_str:
	li		t3, UART_BASE		# UART Base
	mv		t1, a0			# mv arg to temp
1:	lbu		t0, 0(t1)		# read nth item
	beqz		t0, 2f			# null terminate
	lbu		t2, UART_LSR(t3)	# check status
	andi		t2, t2, UART_WR_MASK	# mask
	beqz		t2, 1b			# retry
	sb		t0, UART_RBR(t3)	# send to UART
	addi		t1, t1, 1		# Next char
	j		1b			# Loop back
2:	
	ret

main:
	INIT_STACK	0x100000

	li t0, 0
	bne tp, t0, skip1
	mv a0, sp
	jal	print_dec
	li a0, '\n'
	jal write_byte
	mv a0, s11
	jal	print_dec
	li a0, '\n'
	jal write_byte	

	DECR_STACK 0xFFFC0
	mv a0, sp
	jal	print_dec
	li a0, '\n'	
	jal write_byte	
	mv a0, s11
	jal	print_dec
	li a0, '\n'
	jal write_byte

	li s0, 0x1
	li s1, 0x1
	li s2, 0x1	
	li s3, 0x1
	li s4, 0x1
	li s5, 0x1
	li s6, 0x1
	li s7, 0x1
	li s8, 0x1
	li s9, 0x1
	li s10, 0x1
	li t0, 0x1
	li t1, 0x1
	li t2, 0x1
	li t3, 0x1
	li t4, 0x1
	CHACHA_ROUNDS
	mv a4, t0
	mv a5, t1

	# 3. Print the results
	PRINT x[0]=
	mv a0, s0
	jal print_hex

	li a0, '\n'
	jal write_byte


	PRINT x[1]=
	mv a0, s1
	jal print_hex

	li a0, '\n'
	jal write_byte


	PRINT x[2]=
	mv a0, s2
	jal print_hex

 	li a0, '\n'
	jal write_byte


	PRINT x[3]=
	mv a0, s3
	jal print_hex

	li a0, '\n'
	jal write_byte

        PRINT x[4]=
        mv a0, s4
        jal print_hex

        li a0, '\n'
        jal write_byte


        PRINT x[5]=
        mv a0, s5
        jal print_hex

        li a0, '\n'
        jal write_byte

        PRINT x[6]=
        mv a0, s6
        jal print_hex

        li a0, '\n'
        jal write_byte

        PRINT x[7]=
        mv a0, s7
        jal print_hex

        li a0, '\n'
        jal write_byte

        PRINT x[8]=
        mv a0, s8
        jal print_hex

        li a0, '\n'
        jal write_byte

        PRINT x[9]=
        mv a0, s9
        jal print_hex

        li a0, '\n'
        jal write_byte

        PRINT x[10]=
        mv a0, s10
        jal print_hex

        li a0, '\n'
        jal write_byte

        PRINT x[11]=
        mv a0, a4
        jal print_hex

        li a0, '\n'
        jal write_byte

        PRINT x[12]=
        mv a0, a5
        jal print_hex

        li a0, '\n'
        jal write_byte

        PRINT x[13]=
        mv a0, t2
        jal print_hex

        li a0, '\n'
        jal write_byte

        PRINT x[14]=
        mv a0, t3
        jal print_hex

        li a0, '\n'
        jal write_byte

        PRINT x[15]=
        mv a0, t4
        jal print_hex

        li a0, '\n'
        jal write_byte



skip1:

1:	wfi
	j		1b

data:
