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


# -----------------------------------------------------------------------------
# CORE PRIMITIVES for chacha20
# -----------------------------------------------------------------------------

# a, b, d: registers holding the state words
# n: rotation amount (immediate)
.macro QR_STEP a, b, d, n
	addw	\a, \a, \b		# a += b
	xor	\d, \d, \a		# d ^= a
	.option push
	.option arch, +zbb
	roriw	\d, \d, (32-\n) 	# Rotate Right Word Immediate
	.option pop
.endm

# a, b, c, d are the 4 registers you're working on
.macro CHACHA_QR a, b, c, d
	QR_STEP \a, \b, \d, 16		# Step 1: d is rotated
	QR_STEP \c, \d, \b, 12		# Step 2: b is rotated
	QR_STEP \a, \b, \d, 8		# Step 3: d is rotated
	QR_STEP \c, \d, \b, 7		# Step 4: b is rotated
.endm

.macro CHACHA_ROUND
	# --- Column Rounds ---
	#           a   b   c   d
	CHACHA_QR	s0, s4, s8, t1	# Column 0: x[0], x[4], x[8], x[12]
	CHACHA_QR	s1, s5, s9, t2	# Column 1: x[1], x[5], x[9], x[13]
	CHACHA_QR	s2, s6, s10, t3 # Column 2: x[2], x[6], x[10], x[14]
	CHACHA_QR	s3, s7, t0, t4	# Column 3: x[3], x[7], x[11], x[15]

	# --- Diagonal Rounds ---
	#           a   b   c   d
	CHACHA_QR	s0, s5, s10, t4 # Diag 1: x[0], x[5], x[10], x[15]
	CHACHA_QR	s1, s6, t0, t1	# Diag 2: x[1], x[6], x[11], x[12]
	CHACHA_QR	s2, s7, s8, t2	# Diag 3: x[2], x[7], x[8],  x[13]
	CHACHA_QR	s3, s4, s9, t3	# Diag 4: x[3], x[4], x[9],  x[14]
.endm

# x[0-10] = s0-s10, x[11-15] = t0-t4
.macro CHACHA_ROUNDS
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
.endm

# in_reg:  Register containing pointer to input uint32_t[16]
# out_reg: Register containing pointer to output uint8_t[64]
.macro CHACHA20_BLOCK in, out
	lw s0, 0(\in)
	lw s1, 4(\in)
	lw s2, 8(\in)
	lw s3, 12(\in)
	lw s4, 16(\in)
	lw s5, 20(\in)
	lw s6, 24(\in)
	lw s7, 28(\in)
	lw s8, 32(\in)
	lw s9, 36(\in)
	lw s10, 40(\in)
	lw t0, 44(\in)
	lw t1, 48(\in)
	lw t2, 52(\in)
	lw t3, 56(\in)
	lw t4, 60(\in)

	CHACHA_ROUNDS
	.macro ADD_STEP reg, offset, in_ptr, out_ptr
		lw	t5, \offset(\in_ptr)	# Load original
		addw \reg, \reg, t5		# 32-bit addition
		sw	\reg, \offset(\out_ptr)# Store to output
	.endm

	ADD_STEP s0, 0, \in, \out
	ADD_STEP s1, 4, \in, \out
	ADD_STEP s2, 8, \in, \out
	ADD_STEP s3, 12, \in, \out
	ADD_STEP s4, 16, \in, \out
	ADD_STEP s5, 20, \in, \out
	ADD_STEP s6, 24, \in, \out
	ADD_STEP s7, 28, \in, \out
	ADD_STEP s8, 32, \in, \out
	ADD_STEP s9, 36, \in, \out
	ADD_STEP s10, 40, \in, \out
	ADD_STEP t0, 44, \in, \out
	ADD_STEP t1, 48, \in, \out
	ADD_STEP t2, 52, \in, \out
	ADD_STEP t3, 56, \in, \out
	ADD_STEP t4, 60, \in, \out
.endm

# Define the ChaCha20 Initialization Macro
# Usage: CHACHA20_INIT_STATE reg_base, key_ptr, counter_reg, nonce_ptr
# This assumes key_ptr and nonce_ptr are registers holding memory addresses.
.macro CHACHA20_INIT_STATE key_ptr, counter, nonce_ptr
	# 1. Load the "expand 32-byte k" constants
	li s0, 0x61707865
	li s1, 0x3320646e
	li s2, 0x79622d32
	li s3, 0x6b206574

	# 2. Load the 32-byte Key from memory (8 words)
	lw s4, 0(\key_ptr)
	lw s5, 4(\key_ptr)
	lw s6, 8(\key_ptr)
	lw s7, 12(\key_ptr)
	lw s8, 16(\key_ptr)
	lw s9, 20(\key_ptr)
	lw s10, 24(\key_ptr)
	lw t0, 28(\key_ptr)

	# 3. Set the Counter (from a register)
	mv t1, \counter

	# 4. Load the 12-byte Nonce from memory (3 words)
	lw t2, 0(\nonce_ptr)
	lw t3, 4(\nonce_ptr)
	lw t4, 8(\nonce_ptr)
.endm


# .macro ChaCha20XOR key, counter, nonce, in_ptr, out_ptr, in_len
# Parameters:
#   key:      Register holding the 32-byte key pointer
#   counter:  Register holding the 32-bit counter value
#   nonce:    Register holding the 12-byte nonce pointer
#   in_ptr:   Register holding the input buffer pointer
#   out_ptr:  Register holding the output buffer pointer
#   in_len:   Register holding the length in bytes

.macro ChaCha20XOR key, counter, nonce, in_ptr, out_ptr, in_len
	# 0. Setup Stack Frame (64-byte scratchpad for the original state)
	DECR_STACK 64

	# 1. Initialize the pinned state (s0-s10, t0-t4)
	CHACHA20_INIT_STATE \key, \counter, \nonce

	# Exit immediately if length is 0
	blez \in_len, 2f

1:	# Main 64-byte Block Loop
	# 2. Store current "un-permuted" state to scratchpad (Original State)
	# This is required for the final add-back after the rounds.
	sw s0, 0(sp)
	sw s1, 4(sp)
	sw s2, 8(sp)
	sw s3, 12(sp)
	sw s4, 16(sp)
	sw s5, 20(sp)
	sw s6, 24(sp)
	sw s7, 28(sp)
	sw s8, 32(sp)
	sw s9, 36(sp)
	sw s10, 40(sp)
	sw t0, 44(sp)
	sw t1, 48(sp)
	sw t2, 52(sp)
	sw t3, 56(sp)
	sw t4, 60(sp)

	# 3. Run the 20 Rounds (The Permutation)
	# This macro modifies s0-t4 in-place
	CHACHA_ROUNDS

	# 4. Final Add and XOR
	# Using t5 and t6 as the only available scratch registers.
	# We unroll this manually for all 16 words.
	
	.macro _XOR_STEP_INNER reg, offset, in_reg, out_reg
	lw	t5, \offset(sp)	# Load original state word
	addw \reg, \reg, t5	# s = s + original
	lw	t6, \offset(\in_reg)	# Load plaintext word
	xor	\reg, \reg, t6	# XOR with keystream
	sw	\reg, \offset(\out_reg) # Store ciphertext word
	.endm

	_XOR_STEP_INNER s0, 0,	\in_ptr, \out_ptr
	_XOR_STEP_INNER s1, 4,	\in_ptr, \out_ptr
	_XOR_STEP_INNER s2, 8,	\in_ptr, \out_ptr
	_XOR_STEP_INNER s3, 12, \in_ptr, \out_ptr
	_XOR_STEP_INNER s4, 16, \in_ptr, \out_ptr
	_XOR_STEP_INNER s5, 20, \in_ptr, \out_ptr
	_XOR_STEP_INNER s6, 24, \in_ptr, \out_ptr
	_XOR_STEP_INNER s7, 28, \in_ptr, \out_ptr
	_XOR_STEP_INNER s8, 32, \in_ptr, \out_ptr
	_XOR_STEP_INNER s9, 36, \in_ptr, \out_ptr
	_XOR_STEP_INNER s10, 40, \in_ptr, \out_ptr
	_XOR_STEP_INNER t0, 44, \in_ptr, \out_ptr
	_XOR_STEP_INNER t1, 48, \in_ptr, \out_ptr
	_XOR_STEP_INNER t2, 52, \in_ptr, \out_ptr
	_XOR_STEP_INNER t3, 56, \in_ptr, \out_ptr
	_XOR_STEP_INNER t4, 60, \in_ptr, \out_ptr

	# 5. Prepare for the next 64-byte block
	# Restore the state base from the scratchpad so key/nonce/constants are reset
	lw s0, 0(sp)
	lw s1, 4(sp)
	lw s2, 8(sp)
	lw s3, 12(sp)
	lw s4, 16(sp)
	lw s5, 20(sp)
	lw s6, 24(sp)
	lw s7, 28(sp)
	lw s8, 32(sp)
	lw s9, 36(sp)
	lw s10, 40(sp)
	lw t0, 44(sp)
	
	# Reload and increment the pinned counter (t1) specifically
	lw t1, 48(sp)
	addi t1, t1, 1 
	sw t1, 48(sp)
	
	lw t2, 52(sp)
	lw t3, 56(sp)
	lw t4, 60(sp)

	# 6. Update Pointers and Length
	addi \in_ptr, \in_ptr, 64
	addi \out_ptr, \out_ptr, 64
	addi \in_len, \in_len, -64
	bgtz \in_len, 1b

2:	# Cleanup
	INCR_STACK 64
.endm

# a0 = in_ptr, a1 = in_len, a2 = output (32 bytes required)
.macro CHACHA20_HASH
	SETUP s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10
	# 1. INITIALIZE STATE
	mv a3, a1			# Stash original length for Finalization
	li s0,	4294967291
	li s1,	4294967279
	li s2,	4294967231
	li s3,	4294967197
	li s4,	4294967189
	li s5,	4294967161
	li s6,	4294967147
	li s7,	4294967129
	li s8,	4294967087
	li s9,	4294967029
	li s10, 4294966999
	li t0,	4294966981
	li t1,	4294966943
	li t2,	4294966937
	li t3,	4294966931
	li t4,	4294966913

	# --- ALLOCATE SCRATCHPAD ONCE ---
	# 0(sp) to 63(sp)  : Davies-Meyer Stash
	# 64(sp) to 127(sp): tmp[64] buffer
	DECR_STACK 128

	# 2. PROCESSING LOOP
1:
	# --- Step A: Zero the tmp buffer (at 64(sp)) ---
	li t5, 0
	.set i, 64
	.rept 16
	sw t5, i(sp)
	.set i, i + 4
	.endr

	# --- Step B: Fill tmp buffer (memcpy) ---
	li t6, 64
	blt a1, t6, 2f
	li t6, 64
	j 3f
2:
	mv t6, a1
3:
	beqz t6, 5f		
	addi t5, sp, 64		
4:
	lbu a4, 0(a0)
	sb a4, 0(t5)
	addi a0, a0, 1
	addi t5, t5, 1
	addi a1, a1, -1
	addi t6, t6, -1
	bnez t6, 4b

5:
	# --- Step C: COMPRESS (Davies-Meyer) ---
	# Stash state into 0(sp)
	sw s0, 0(sp)
	sw s1, 4(sp)
	sw s2, 8(sp)
	sw s3, 12(sp)
	sw s4, 16(sp)
	sw s5, 20(sp)
	sw s6, 24(sp)
	sw s7, 28(sp)
	sw s8, 32(sp)
	sw s9, 36(sp)
	sw s10, 40(sp)
	sw t0, 44(sp)
	sw t1, 48(sp)
	sw t2, 52(sp)
	sw t3, 56(sp)
	sw t4, 60(sp)

	# XOR tmp[64] buffer into registers
	addi t5, sp, 64
	lw a4, 0(t5)
	xor s0, s0, a4
	lw a4, 4(t5)
	xor s1, s1, a4
	lw a4, 8(t5)
	xor s2, s2, a4
	lw a4, 12(t5)
	xor s3, s3, a4
	lw a4, 16(t5)
	xor s4, s4, a4
	lw a4, 20(t5)
	xor s5, s5, a4
	lw a4, 24(t5)
	xor s6, s6, a4
	lw a4, 28(t5)
	xor s7, s7, a4
	lw a4, 32(t5)
	xor s8, s8, a4
	lw a4, 36(t5)
	xor s9, s9, a4
	lw a4, 40(t5)
	xor s10, s10, a4
	lw a4, 44(t5)
	xor t0, t0, a4
	lw a4, 48(t5)
	xor t1, t1, a4
	lw a4, 52(t5)
	xor t2, t2, a4
	lw a4, 56(t5)
	xor t3, t3, a4
	lw a4, 60(t5)
	xor t4, t4, a4

	CHACHA_ROUNDS

	# Final ADD (registers += stashed_state at 0(sp))
	lw a4, 0(sp)
	addw s0, s0, a4
	lw a4, 4(sp)
	addw s1, s1, a4
	lw a4, 8(sp)
	addw s2, s2, a4
	lw a4, 12(sp)
	addw s3, s3, a4
	lw a4, 16(sp)
	addw s4, s4, a4
	lw a4, 20(sp)
	addw s5, s5, a4
	lw a4, 24(sp)
	addw s6, s6, a4
	lw a4, 28(sp)
	addw s7, s7, a4
	lw a4, 32(sp)
	addw s8, s8, a4
	lw a4, 36(sp)
	addw s9, s9, a4
	lw a4, 40(sp)
	addw s10, s10, a4
	lw a4, 44(sp)
	addw t0, t0, a4
	lw a4, 48(sp)
	addw t1, t1, a4
	lw a4, 52(sp)
	addw t2, t2, a4
	lw a4, 56(sp)
	addw t3, t3, a4
	lw a4, 60(sp)
	addw t4, t4, a4

	# Loop if more data remains
	bnez a1, 1b

	# --- DEALLOCATE SCRATCHPAD ---
	INCR_STACK 128

	# 3. FINALIZATION (Domain Separation)
	xor t1, t1, a3
	srli a4, a3, 32
	xor t2, t2, a4
	li a4, 1
	xor t4, t4, a4

	CHACHA_ROUNDS

	# 4. STORE DIGEST
	sw s0, 0(a2)
	sw s1, 4(a2)
	sw s2, 8(a2)
	sw s3, 12(a2)
	sw s4, 16(a2)
	sw s5, 20(a2)
	sw s6, 24(a2)
	sw s7, 28(a2)
	TEAR_DOWN
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

	mv		t1, sp			# Buffer start
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

	mv		s0, a0			# Save original value
	li		s2, 0			# flag = 0 (skipping leading)

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

1:	li		s1, 60			# Start at highest nibble
2:	
	srl		t2, s0, s1		# Isolate nibble
	andi		t2, t2, 0xF

	# Skip leading zeros logic
	bnez		t2, 3f			# If nibble != 0, start
	bnez		s2, 3f			# If already started, print
	j		next_nibble		# Otherwise, skip

3:	li		s2, 1			# Flip "started" flag

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

	DECR_STACK 32

	LOAD_ADDRESS a0, in_ptr
	li a1, 5
	mv a2, sp
	CHACHA20_HASH
	mv s6, a2
	li s4, 32

1:
	lbu	a0, 0(s6)
	jal print_hex
	li	a0, '\n'
	jal write_byte
	addi s4, s4, -1
	addi s6, s6, 1
	bnez s4, 1b

	li a0, 'q'
	jal write_byte

	INCR_STACK 32
skip1:
1:	wfi
	j		1b

in_ptr: .asciz			"hello"

data:
