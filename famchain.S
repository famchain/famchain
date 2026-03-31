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

.equ	UART_BASE,		0x10000000
.equ	UART_LSR,		5
.equ	UART_WR_MASK,		0x20

.altmacro
.macro LOAD_ADDRESS reg, label
_base\@:
	# Uses \@ to make a unique constant name for every expansion
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

.set _macro_depth, 0

.macro _def_restore_macro depth, sz, regs:vararg
	.macro _do_tear_down_\depth
	.ifnc "\regs", ""
		.set _off, 4
		.irp reg, \regs
		lw \reg, _off(sp)
		.set _off, _off + 4
		.endr
	.endif
	lw ra, 0(sp)
	addi sp, sp, \sz
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


	addi sp, sp, -_sz
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
	LOAD_ADDRESS	gp, data
	li		t0, 4095
	add		gp, gp, t0
	li		t0, -4096
	and		gp, gp, t0
	li		t0, 0x100000
	add		sp, gp, t0

	addi		a0, sp,	-64
	li		a1, 3
	addi		a2, sp, -128
	addi		sp, sp, -128
	li		t0, 'a'
	sb		t0, 0(a0)
	li		t0, 'b'
	sb		t0, 1(a0)
	li		t0, 'c'
	sb		t0, 2(a0)
	jal		blake2s

	addi		a0, sp, -128
	lw		a0, 0(a0)
	jal		print_hex
	li		a0, ' '
	jal		write_byte

	addi		a0, sp, -128
	lw		a0, 4(a0)
	jal		print_hex
	li		a0, ' '
	jal		write_byte

	addi		a0, sp, -128
	lw		a0, 8(a0)
	jal		print_hex
	li		a0, ' '
	jal		write_byte

	addi		a0, sp, -128
	lw		a0, 12(a0)
	jal		print_hex
	li		a0, ' '
	jal		write_byte

	addi		a0, sp, -128
	lw		a0, 16(a0)
	jal		print_hex
	li		a0, ' '
	jal		write_byte

	addi		a0, sp, -128
	lw		a0, 20(a0)
	jal		print_hex
	li		a0, ' '
	jal		write_byte

	addi		a0, sp, -128
	lw		a0, 24(a0)
	jal		print_hex
	li		a0, ' '
	jal		write_byte

	addi		a0, sp, -128
	lw		a0, 28(a0)
	jal		print_hex

	li		a0, '\n'
	jal		write_byte





1:	wfi
	j		1b


print_hex:
	SETUP		s0, s1, s2, t0, t1, t2, a0

	mv		s0, a0		# Save original value

	# Print "0x" prefix
	bnez		a1, 0f
	li		a0, '0' 
	jal		write_byte
	li		a0, 'x'
	jal		write_byte
0:

1:	li		s1, 28		# Start at highest nibble
2:
	srl		t2, s0, s1	# Isolate nibble
	andi		t2, t2, 0xF

	# Convert nibble to ASCII
	li		a0, 10
	blt		t2, a0, 4f	# If 0-9
	addi		t2, t2, 7	# Adjust for A-F
4:	addi		a0, t2, 48	# ASCII '0'
	jal		write_byte

	addi		s1, s1, -4	# Move to next 4 bits
	bgez		s1, 2b

	RETURN

write_byte:
	li		t1, UART_BASE
	lbu		t2, UART_LSR(t1)
	andi		t2, t2, UART_WR_MASK
	beqz		t2, write_byte
	sb		a0, 0(t1)
	ret

# G mixing function (RFC 7693 §3.1)
# a0=va, a1=vb, a2=vc, a3=vd, a4=mx, a5=my
# Returns updated va,vb,vc,vd in a0,a1,a2,a3
# Leaf function — no SETUP needed; clobbers t0,t1 only
b2s_g:
	add	a0, a0, a1
	add	a0, a0, a4		# va = va + vb + mx
	xor	a3, a3, a0
	srli	t0, a3, 16
	slli	t1, a3, 16
	or	a3, t0, t1		# vd = ROTR32(vd, 16)
	add	a2, a2, a3		# vc = vc + vd
	xor	a1, a1, a2
	srli	t0, a1, 12
	slli	t1, a1, 20
	or	a1, t0, t1		# vb = ROTR32(vb, 12)
	add	a0, a0, a1
	add	a0, a0, a5		# va = va + vb + my
	xor	a3, a3, a0
	srli	t0, a3, 8
	slli	t1, a3, 24
	or	a3, t0, t1		# vd = ROTR32(vd, 8)
	add	a2, a2, a3		# vc = vc + vd
	xor	a1, a1, a2
	srli	t0, a1, 7
	slli	t1, a1, 25
	or	a1, t0, t1		# vb = ROTR32(vb, 7)
	ret

# Blake2s compression (RFC 7693 §3.2)
# a0 = h_ptr   (pointer to h[0..7], 8 × u32, modified in place)
# a1 = m_ptr   (pointer to 64-byte message block)
# a2 = t_lo    (low 32 bits of byte counter)
# a3 = t_hi    (high 32 bits of byte counter)
# a4 = f0      (0 normally; 0xFFFFFFFF for last block)
b2s_compress:
	SETUP	s0, s1, s2, s3, s4, s5, s6

	mv	s0, a0			# s0 = h_ptr
	mv	s1, a1			# s1 = m_ptr

	# Allocate v[0..15] on stack (64 bytes)
	addi	sp, sp, -64
	mv	s2, sp			# s2 = v_base

	# v[0..7] = h[0..7]
	.set	_i, 0
	.rept	8
	lw	t0, (_i * 4)(s0)
	sw	t0, (_i * 4)(s2)
	.set	_i, _i + 1
	.endr

	# Load IV base
	LOAD_ADDRESS t1, b2s_iv

	# v[8..11] = IV[0..3]
	.set	_i, 0
	.rept	4
	lw	t0, (_i * 4)(t1)
	sw	t0, ((_i + 8) * 4)(s2)
	.set	_i, _i + 1
	.endr

	# v[12] = t_lo ^ IV[4]
	lw	t0, 16(t1)
	xor	t0, t0, a2
	sw	t0, 48(s2)

	# v[13] = t_hi ^ IV[5]
	lw	t0, 20(t1)
	xor	t0, t0, a3
	sw	t0, 52(s2)

	# v[14] = f0 ^ IV[6]
	lw	t0, 24(t1)
	xor	t0, t0, a4
	sw	t0, 56(s2)

	# v[15] = IV[7]
	lw	t0, 28(t1)
	sw	t0, 60(s2)

	# Table pointers
	LOAD_ADDRESS s3, b2s_sigma
	LOAD_ADDRESS s4, b2s_g_idx

	# Round loop: s5 = round (0..9)
	li	s5, 0
_b2s_round:
	li	t0, 10
	bge	s5, t0, _b2s_round_done

	# G-call loop: s6 = call index (0..7)
	li	s6, 0
_b2s_gcall:
	li	t0, 8
	bge	s6, t0, _b2s_gcall_done

	# a,b,c,d indices from b2s_g_idx[s6]
	slli	t0, s6, 2
	add	t0, t0, s4
	lbu	t3, 0(t0)		# ai
	lbu	t4, 1(t0)		# bi
	lbu	t5, 2(t0)		# ci
	lbu	t6, 3(t0)		# di

	# Message word indices: sigma[s5 * 16 + s6 * 2]
	slli	t0, s5, 4
	slli	t1, s6, 1
	add	t0, t0, t1
	add	t0, t0, s3
	lbu	t1, 0(t0)		# mx_idx
	lbu	t2, 1(t0)		# my_idx

	# mx = m[mx_idx], my = m[my_idx]
	slli	t1, t1, 2
	add	t1, t1, s1
	lw	a4, 0(t1)

	slli	t2, t2, 2
	add	t2, t2, s1
	lw	a5, 0(t2)

	# Load v[ai..di]
	slli	t0, t3, 2
	add	t0, t0, s2
	lw	a0, 0(t0)

	slli	t0, t4, 2
	add	t0, t0, s2
	lw	a1, 0(t0)

	slli	t0, t5, 2
	add	t0, t0, s2
	lw	a2, 0(t0)

	slli	t0, t6, 2
	add	t0, t0, s2
	lw	a3, 0(t0)

	# Spill index regs (caller-saved) across b2s_g call
	addi	sp, sp, -16
	sw	t3, 0(sp)
	sw	t4, 4(sp)
	sw	t5, 8(sp)
	sw	t6, 12(sp)

	jal	b2s_g

	lw	t3, 0(sp)
	lw	t4, 4(sp)
	lw	t5, 8(sp)
	lw	t6, 12(sp)
	addi	sp, sp, 16

	# Store updated va..vd back into v[]
	slli	t0, t3, 2
	add	t0, t0, s2
	sw	a0, 0(t0)

	slli	t0, t4, 2
	add	t0, t0, s2
	sw	a1, 0(t0)

	slli	t0, t5, 2
	add	t0, t0, s2
	sw	a2, 0(t0)

	slli	t0, t6, 2
	add	t0, t0, s2
	sw	a3, 0(t0)

	addi	s6, s6, 1
	j	_b2s_gcall

_b2s_gcall_done:
	addi	s5, s5, 1
	j	_b2s_round

_b2s_round_done:
	# h[i] ^= v[i] ^ v[i+8]  for i = 0..7
	.set	_i, 0
	.rept	8
	lw	t0, (_i * 4)(s2)
	lw	t1, ((_i + 8) * 4)(s2)
	xor	t0, t0, t1
	lw	t1, (_i * 4)(s0)
	xor	t0, t0, t1
	sw	t0, (_i * 4)(s0)
	.set	_i, _i + 1
	.endr

	addi	sp, sp, 64
	RETURN

# blake2s: hash a0 bytes with 32-byte output
# a0 = input_ptr
# a1 = input_len  (bytes)
# a2 = output_ptr (must point to 32 writable bytes)
blake2s:
	SETUP	s0, s1, s2, s3, s4, s5, s6

	mv	s0, a0			# s0 = input_ptr
	mv	s1, a1			# s1 = remaining bytes
	mv	s2, a2			# s2 = output_ptr

	# Allocate h[0..7] (32 bytes) + last-block buffer (64 bytes)
	addi	sp, sp, -96
	mv	s3, sp			# s3 = h_ptr  (offsets  0..31)
	addi	s4, sp, 32		# s4 = buf_ptr (offsets 32..95)

	# h[0..7] = IV[0..7]
	LOAD_ADDRESS t0, b2s_iv
	.set	_i, 0
	.rept	8
	lw	t1, (_i * 4)(t0)
	sw	t1, (_i * 4)(s3)
	.set	_i, _i + 1
	.endr

	# h[0] ^= 0x01010020  (outlen=32, fanout=1, depth=1)
	lw	t0, 0(s3)
	li	t1, 0x01010020
	xor	t0, t0, t1
	sw	t0, 0(s3)

	# Byte counter (lo, hi)
	li	s5, 0
	li	s6, 0

	# Process all complete blocks except the last
_b2s_block:
	li	t0, 64
	ble	s1, t0, _b2s_last	# ≤ 64 bytes remaining → last block

	add	s5, s5, t0		# counter_lo += 64
	mv	a0, s3
	mv	a1, s0
	mv	a2, s5
	mv	a3, s6
	li	a4, 0
	jal	b2s_compress

	addi	s0, s0, 64
	addi	s1, s1, -64
	j	_b2s_block

_b2s_last:
	# Zero the 64-byte buffer (4 iterations × 16 bytes)
	li	t0, 4
	mv	t1, s4
_b2s_zero:
	sw	zero,	0(t1)
	sw	zero,	4(t1)
	sw	zero,	8(t1)
	sw	zero, 12(t1)
	addi	t1, t1, 16
	addi	t0, t0, -1
	bnez	t0, _b2s_zero

	# Copy remaining bytes into buffer
	mv	t0, s0
	mv	t1, s4
	mv	t2, s1
_b2s_copy:
	beqz	t2, _b2s_copy_done
	lbu	t3, 0(t0)
	sb	t3, 0(t1)
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	_b2s_copy
_b2s_copy_done:

	add	s5, s5, s1		# counter += remaining

	mv	a0, s3
	mv	a1, s4
	mv	a2, s5
	mv	a3, s6
	li	a4, -1			# f0 = 0xFFFFFFFF (last block)
	jal	b2s_compress

	# Copy h[0..7] → output
	.set	_i, 0
	.rept	8
	lw	t0, (_i * 4)(s3)
	sw	t0, (_i * 4)(s2)
	.set	_i, _i + 1
	.endr

	addi	sp, sp, 96
	RETURN

# IV = SHA-256 fractional parts of sqrt of first 8 primes
b2s_iv:
	.word	0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A
	.word	0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19

# Sigma permutation table (10 rounds × 16 indices)
b2s_sigma:
	.byte	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
	.byte	14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3
	.byte	11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4
	.byte	7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8
	.byte	9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13
	.byte	2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9
	.byte	12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11
	.byte	13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10
	.byte	6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5
	.byte	10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0

# v[] indices (a, b, c, d) for each of the 8 G calls per round
b2s_g_idx:
	.byte	0,	4,	8,	12	# column 0
	.byte	1,	5,	9,	13	# column 1
	.byte	2,	6,	10,	14	# column 2
	.byte	3,	7,	11,	15	# column 3
	.byte	0,	5,	10,	15	# diagonal 0
	.byte	1,	6,	11,	12	# diagonal 1
	.byte	2,	7,	8,	13	# diagonal 2
	.byte	3,	4,	9,	14	# diagonal 3

data:
