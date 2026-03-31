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

.equ	VIRTIO_DISK_BASE,	0x10001000
.equ	VIRTIO_NET_BASE,	0x10002000
.equ	VIRT_QUEUE0,		0x050
.equ	VIO_NET_ID,		1		# Device ID for Network is 1
.equ	VIO_MAGIC,		0x000
.equ	VIO_DEVICE_ID,		0x008
.equ	VIO_DEVICE_FEATURES,	0x010
.equ	VIO_DRIVER_FEATURES,	0x020
.equ	VIO_GUEST_PAGE_SIZE,	0x028
.equ	VIO_QUEUE_SEL,		0x030
.equ	VIO_QUEUE_NUM,		0x038
.equ	VIO_QUEUE_ALIGN,	0x03C
.equ	VIO_QUEUE_PFN,		0x040
.equ	VIO_STATUS,		0x070
.equ	VIRT_MAGIC,		0x74726976

.equ	GUEST_MAC_0,		0x52
.equ	GUEST_MAC_1,		0x54
.equ	GUEST_MAC_2,		0x00
.equ	GUEST_MAC_3,		0x12
.equ	GUEST_MAC_4,		0x34
.equ	GUEST_MAC_5,		0x56
.equ	GUEST_IP_0,		10
.equ	GUEST_IP_1,		0
.equ	GUEST_IP_2,		2
.equ	GUEST_IP_3,		15

.equ	RX_QUEUE_DATA_OFFSET,	0		# net RX queue base (page-aligned)
.equ	TX_QUEUE_DATA_OFFSET,	8192		# net TX queue base (page-aligned)
.equ	DISK_DATA_BUFFER,	16384		# disk read/write buffer (512 bytes)
.equ	VIRT_DESCRIPTOR_TABLE,	20480		# disk descriptor table (page-aligned: 5×4096)
.equ	VIRT_DISK_STATUS,	25088		# after disk used ring (20480+4096+512)
.equ	VIRT_DISK_HEADER,	25090
.equ	LOAD_LOC,		25106		# binary load location (unlimited headroom)

# Size and Hash of Program 
# Program hash is: 0x0615555B 0x0615555B 0x0615555B 0x0615555B 0x32214BDD 0x32214BDD 0xCB4F2064 0x60741073
# Change BIN_HASH0 to exercise the 'hash_mismatch' logic
.equ	BIN_SIZE,		1296
.equ	BIN_HASH0,		0x0615555B
.equ	BIN_HASH1,		0x21032136
.equ	BIN_HASH2,		0x53CB174E
.equ	BIN_HASH3,		0xA7D9AD58
.equ	BIN_HASH4,		0x32214BDD
.equ	BIN_HASH5,		0x47BC5AF3
.equ	BIN_HASH6,		0xCB4F2064
.equ	BIN_HASH7,		0x60741073

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

.macro INIT_DISK
	li		t0, VIRTIO_DISK_BASE
	lw		t1, VIO_MAGIC(t0)		# Should be 0x74726976 ("virt")
	li		t2, VIRT_MAGIC
	bne		t1, t2, error_not_virtio

	lw		t1, VIO_DEVICE_ID(t0)		# Should be 2 for Block Device
	li		t2, 2
	bne		t1, t2, error_not_disk

	# Reset the device
	sw		zero, VIO_STATUS(t0)

	# Set ACKNOWLEDGE bit (1)
	li		t1, 1
	sw		t1, VIO_STATUS(t0)

	# Set DRIVER bit (2)
	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 2
	sw		t1, VIO_STATUS(t0)

	# Feature negotiation: read device features, accept none
	lw		t1, VIO_DEVICE_FEATURES(t0)
	sw		zero, VIO_DRIVER_FEATURES(t0)

	# Set FEATURES_OK bit (8)
	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 8
	sw		t1, VIO_STATUS(t0)

	# Check if FEATURES_OK was accepted
	lw		t1, VIO_STATUS(t0)
	andi		t2, t1, 8
	beqz		t2, error_features_not_supported

	# zero the disk region (gp+DISK_DATA_BUFFER..gp+LOAD_LOC)
	li		t2, DISK_DATA_BUFFER
	add		t2, gp, t2
	li		t3, LOAD_LOC
	add		t3, gp, t3

1:
	sb		zero, 0(t2)
	addi		t2, t2, 1
	bltu		t2, t3, 1b

	li		t1, 4096
	sw		t1, VIO_GUEST_PAGE_SIZE(t0)	# GuestPageSize = 4096

	# Queue setup
	sw		zero, VIO_QUEUE_SEL(t0)		# QueueSel = 0
	li		t1, 16
	sw		t1, VIO_QUEUE_NUM(t0)		# QueueNum = 16
	li		t1, 4096
	sw		t1, VIO_QUEUE_ALIGN(t0)		# QueueAlign = 4096

	mv		t1, gp
	li		t5, VIRT_DESCRIPTOR_TABLE
	add		t1, t1, t5
	srli		t1, t1, 12			# PFN = address >> 12
	sw		t1, VIO_QUEUE_PFN(t0)

	# Set DRIVER_OK bit (4) - Device is now "Live"
	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 4
	sw		t1, VIO_STATUS(t0)
.endm


# a0 = sector
# a1 = counter
.macro READ_BLOCK
	mv		t0, gp
	li		t5, VIRT_DESCRIPTOR_TABLE
	add		t1, t0, t5			# t1 = descriptor table
	li		t2, VIRT_DISK_HEADER
	add		t2, t2, t0			# t2 = request header
	li		t3, VIRT_DISK_STATUS
	add		t3, t3, t0			# t3 = status byte

	sw		zero, 0(t2)			# type = VIRTIO_BLK_T_IN (read)
	sw		a0, 8(t2)			# sector

	# desc[0]: request header
	sw		t2, 0(t1)			# addr
	sw		zero, 4(t1)
	li		t4, 16
	sw		t4, 8(t1)			# len = 16
	li		t4, 1				# NEXT flag
	sh		t4, 12(t1)			# flags
	sh		t4, 14(t1)			# next = 1

	# desc[1]: data buffer
	li		t5, DISK_DATA_BUFFER
	add		t5, gp, t5
	sw		t5, 16(t1)			# addr = gp + DISK_DATA_BUFFER
	sw		zero, 20(t1)
	li		t4, 512
	sw		t4, 24(t1)			# len = 512
	li		t4, 3				# NEXT | WRITE flags
	sh		t4, 28(t1)			# flags
	li		t4, 2
	sh		t4, 30(t1)			# next = 2

	# desc[2]: status byte
	sw		t3, 32(t1)			# addr = status
	sw		zero, 36(t1)
	li		t4, 1
	sw		t4, 40(t1)			# len = 1
	li		t4, 2				# WRITE flag
	sh		t4, 44(t1)			# flags
	sh		zero, 46(t1)			# next = 0 (end)

	# Notify the Available Ring (starts at offset 256, after 16 descriptors)
	addi		t4, t1, 256
	sh		zero, 4(t4)			# ring[0] = 0
	li		t5, 0xFF
	sb		t5, 0(t3)			# status sentinel = 0xFF
	sh		a1, 2(t4)			# avail.idx

	# Kick the hardware
	fence		w, w				# ensure all writes visible
	li		t5, VIRTIO_DISK_BASE
	sw		zero, VIRT_QUEUE0(t5)		# notify queue 0

	# Wait for disk_status to change from 0xFF
	li		t5, 0xFF
1:	lbu		t4, 0(t3)
	beq		t4, t5, 1b
	fence		r, r
.endm

.macro INIT_NET
	# zero net region (gp+0..gp+DISK_DATA_BUFFER)
	mv	t2, gp
	li	t3, DISK_DATA_BUFFER
	add	t3, gp, t3
1:
	sw	zero, 0(t2)
	addi t2, t2, 4
	bltu t2, t3, 1b

	li	s0, VIRTIO_NET_BASE
	sw	zero, VIO_STATUS(s0)		# Reset device

	li	t0, 1
	sw	t0, VIO_STATUS(s0)		# ACK

	li	t0, 3
	sw	t0, VIO_STATUS(s0)		# ACK + DRIVER

	# Feature negotiation: accept what the device offers
	lw	t1, VIO_DEVICE_FEATURES(s0)
	sw	t1, VIO_DRIVER_FEATURES(s0)

	# Set FEATURES_OK bit (8)
	lw	t1, VIO_STATUS(s0)
	ori	t1, t1, 8
	sw	t1, VIO_STATUS(s0)

	# Set guest page size (required for legacy interface)
	li	t0, 4096
	sw	t0, VIO_GUEST_PAGE_SIZE(s0)

	# RX Queue (queue 0 per virtio-net spec)
	sw	zero, VIO_QUEUE_SEL(s0)		# select queue 0 (RX)
	li	t0, 1
	sw	t0, VIO_QUEUE_NUM(s0)		# QueueNum = 1
	li	t0, 4096
	sw	t0, VIO_QUEUE_ALIGN(s0)		# QueueAlign = 4096
	li	t0, RX_QUEUE_DATA_OFFSET
	add	t2, gp, t0
	srli	t2, t2, 12
	sw	t2, VIO_QUEUE_PFN(s0)		# RX QueuePFN

	# TX Queue (queue 1 per virtio-net spec)
	li	t0, 1
	sw	t0, VIO_QUEUE_SEL(s0)		# select queue 1 (TX)
	sw	t0, VIO_QUEUE_NUM(s0)		# QueueNum = 1
	li	t0, 4096
	sw	t0, VIO_QUEUE_ALIGN(s0)		# QueueAlign = 4096
	li	t0, TX_QUEUE_DATA_OFFSET
	add	t2, gp, t0
	srli	t2, t2, 12
	sw	t2, VIO_QUEUE_PFN(s0)		# TX QueuePFN

	# Set DRIVER_OK bit (4)
	lw	t1, VIO_STATUS(s0)
	ori	t1, t1, 4
	sw	t1, VIO_STATUS(s0)

	# === RX BUFFER POST ===
	mv	t3, gp				# t3 = RX queue base (RX_QUEUE_DATA_OFFSET = 0)
	addi	t4, t3, 512			# RX buffer at queue_base + 512
	sw	t4, 0(t3)			# desc[0].addr low
	sw	zero, 4(t3)			# desc[0].addr high
	li	t4, 1536
	sw	t4, 8(t3)			# desc[0].len
	li	t4, 2				# VIRTQ_DESC_F_WRITE
	sh	t4, 12(t3)			# desc[0].flags
	sh	zero, 14(t3)			# desc[0].next

	# Available ring at queue_base + 16 (1 descriptor × 16 bytes)
	sh	zero, 16(t3)			# avail.flags = 0
	li	t4, 1
	sh	t4, 18(t3)			# avail.idx = 1
	sh	zero, 20(t3)			# avail.ring[0] = descriptor 0

	fence	w, w
	sw	zero, VIRT_QUEUE0(s0)		# kick queue 0 (RX)
.endm

_start:
	LOAD_ADDRESS	gp, data
	li		t0, 4095
	add		gp, gp, t0
	li		t0, -4096
	and		gp, gp, t0
	li		t0, 0x100000
	add		sp, gp, t0

	INIT_DISK
	INIT_NET

	li		s2, LOAD_LOC
	add		s2, s2, gp
	li		s3, 0		# counter
	li		s5, BIN_SIZE

start_block:
	mv		a0, s3		# counter
	addi		s3, s3, 1
	mv		a1, s3		# idx = counter + 1
	READ_BLOCK

	li		t0, DISK_DATA_BUFFER
	add		s0, gp, t0	# data lands at gp+DISK_DATA_BUFFER
	addi		s1, s0, 512
1:
	lbu		a0, 0(s0)
	sb		a0, 0(s2)
	addi		s5, s5, -1
	beqz		s5, 2f
	addi		s2, s2, 1
	addi		s0, s0, 1
	bne		s0, s1, 1b
	j		start_block
2:

	li		s0, LOAD_LOC
	add		s0, s0, gp

	# Check hash
	addi		sp, sp, -32
	mv		a0, s0
	li		a1, BIN_SIZE
	mv		a2, sp
	jal		blake2s

	lw		t0, 0(sp)
	li		t1, BIN_HASH0
	bne		t0, t1, hash_mismatch
	lw		t0, 4(sp)
	li		t1, BIN_HASH1
	bne		t0, t1, hash_mismatch
	lw		t0, 8(sp)
	li		t1, BIN_HASH2
	bne		t0, t1, hash_mismatch
	lw		t0, 12(sp)
	li		t1, BIN_HASH3
	bne		t0, t1, hash_mismatch
	lw		t0, 16(sp)
	li		t1, BIN_HASH4
	bne		t0, t1, hash_mismatch
	lw		t0, 20(sp)
	li		t1, BIN_HASH5
	bne		t0, t1, hash_mismatch
	lw		t0, 24(sp)
	li		t1, BIN_HASH6
	bne		t0, t1, hash_mismatch
	lw		t0, 28(sp)
	li		t1, BIN_HASH7
	bne		t0, t1, hash_mismatch

	li		s0, LOAD_LOC
	add		s0, s0, gp
	jr		s0

1:	wfi
	j		1b


print_hex:
	SETUP		s0, s1, s2, t0, t1, t2, a0

	mv		s0, a0		# Save original value

	# Print "0x" prefix
	bnez		a1, 1f
	li		a0, '0' 
	jal		write_byte
	li		a0, 'x'
	jal		write_byte


1:	li		s1, 28		# Start at highest nibble
2:
	srl		t2, s0, s1	# Isolate nibble
	andi		t2, t2, 0xF

	# Convert nibble to ASCII
	li		a0, 10
	blt		t2, a0, 3f	# If 0-9
	addi		t2, t2, 7	# Adjust for A-F
3:	addi		a0, t2, 48	# ASCII '0'
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

# hexdump: a0=ptr, a1=len — prints "XX XX XX ..." 16 bytes per line
hexdump:
        SETUP   s2, s3, s4, s5

        mv      s2, a0          # s2 = ptr
        mv      s3, a1          # s3 = remaining bytes
        li      s4, 0           # s4 = column counter

hexdump_loop:
        beqz    s3, hexdump_done
        lbu     s5, 0(s2)       # s5 = current byte

        srli    a0, s5, 4       # high nibble
        jal     print_nibble
        andi    a0, s5, 0xF     # low nibble
        jal     print_nibble
        li      a0, ' '
        jal     write_byte

        addi    s2, s2, 1
        addi    s3, s3, -1
        addi    s4, s4, 1
        andi    t0, s4, 0xF     # newline every 16 bytes
        bnez    t0, hexdump_loop
        li      a0, '\n'
        jal     write_byte
        j       hexdump_loop

hexdump_done:
        li      a0, '\n'
        jal     write_byte
        RETURN

# print_nibble: a0=nibble (0-15) — prints one hex character, tail-calls write_byte
print_nibble:
        li      t0, 10
        blt     a0, t0, 1f
        addi    a0, a0, 7       # 'A'-'9'-1
1:      addi    a0, a0, '0'
        j       write_byte      # tail call

# Send ARP reply. Reads sender info from RX buffer, writes reply to TX buffer.
# Clobbers: a0, a1, t0, t2. Preserves: t3, t4, s1.
send_arp_reply:
        SETUP   s0

        li      s0, VIRTIO_NET_BASE

        # a0 = RX buffer (gp + RX_QUEUE_DATA_OFFSET + 512 = gp + 512)
        addi    a0, gp, 512

        # a1 = TX buffer (gp + TX_QUEUE_DATA_OFFSET + 512)
        li      a1, TX_QUEUE_DATA_OFFSET + 512
        add     a1, gp, a1

        # virtio_net_hdr: 12 bytes, all zero
        sw      zero, 0(a1)
        sw      zero, 4(a1)
        sw      zero, 8(a1)

        # Ethernet dst MAC = ARP sender MAC from RX (same bytes reused for ARP target MAC below)
        lbu     t0, 34(a0); sb t0, 12(a1)
        lbu     t0, 35(a0); sb t0, 13(a1)
        lbu     t0, 36(a0); sb t0, 14(a1)
        lbu     t0, 37(a0); sb t0, 15(a1)
        lbu     t0, 38(a0); sb t0, 16(a1)
        lbu     t0, 39(a0); sb t0, 17(a1)

        # Ethernet src MAC = guest MAC
        li      t0, GUEST_MAC_0; sb t0, 18(a1)
        li      t0, GUEST_MAC_1; sb t0, 19(a1)
        li      t0, GUEST_MAC_2; sb t0, 20(a1)
        li      t0, GUEST_MAC_3; sb t0, 21(a1)
        li      t0, GUEST_MAC_4; sb t0, 22(a1)
        li      t0, GUEST_MAC_5; sb t0, 23(a1)

        # EtherType = 08:06 (ARP)
        li      t0, 0x08; sb t0, 24(a1)
        li      t0, 0x06; sb t0, 25(a1)

        # ARP: hw type=00:01, proto type=08:00, hw size=06, proto size=04
        sb      zero,     26(a1)
        li      t0, 0x01; sb t0, 27(a1)
        li      t0, 0x08; sb t0, 28(a1)
        sb      zero,     29(a1)
        li      t0, 0x06; sb t0, 30(a1)
        li      t0, 0x04; sb t0, 31(a1)

        # ARP opcode = 00:02 (reply)
        sb      zero,     32(a1)
        li      t0, 0x02; sb t0, 33(a1)

        # ARP sender MAC = guest MAC
        li      t0, GUEST_MAC_0; sb t0, 34(a1)
        li      t0, GUEST_MAC_1; sb t0, 35(a1)
        li      t0, GUEST_MAC_2; sb t0, 36(a1)
        li      t0, GUEST_MAC_3; sb t0, 37(a1)
        li      t0, GUEST_MAC_4; sb t0, 38(a1)
        li      t0, GUEST_MAC_5; sb t0, 39(a1)

        # ARP sender IP = guest IP
        li      t0, GUEST_IP_0; sb t0, 40(a1)
        li      t0, GUEST_IP_1; sb t0, 41(a1)
        li      t0, GUEST_IP_2; sb t0, 42(a1)
        li      t0, GUEST_IP_3; sb t0, 43(a1)

        # ARP target MAC = ARP sender MAC from RX (same source as Ethernet dst above)
        lbu     t0, 34(a0); sb t0, 44(a1)
        lbu     t0, 35(a0); sb t0, 45(a1)
        lbu     t0, 36(a0); sb t0, 46(a1)
        lbu     t0, 37(a0); sb t0, 47(a1)
        lbu     t0, 38(a0); sb t0, 48(a1)
        lbu     t0, 39(a0); sb t0, 49(a1)

        # ARP target IP = ARP sender IP from RX
        lbu     t0, 40(a0); sb t0, 50(a1)
        lbu     t0, 41(a0); sb t0, 51(a1)
        lbu     t0, 42(a0); sb t0, 52(a1)
        lbu     t0, 43(a0); sb t0, 53(a1)

        # t2 = TX queue base
        li      t2, TX_QUEUE_DATA_OFFSET
        add     t2, gp, t2

        sw      a1,   0(t2)             # desc[0].addr low = TX buffer
        sw      zero,  4(t2)            # desc[0].addr high = 0
        li      t0, 54
        sw      t0,    8(t2)            # desc[0].len = 54
        sh      zero, 12(t2)            # desc[0].flags = 0 (device reads)
        sh      zero, 14(t2)            # desc[0].next = 0

        sh      zero, 16(t2)            # avail.flags = 0
        lhu     t0,   18(t2)            # avail.idx++
        addi    t0, t0, 1
        sh      t0,   18(t2)
        sh      zero, 20(t2)            # avail.ring[0] = descriptor 0

        fence   w, w
        li      t0, 1
        sw      t0, VIRT_QUEUE0(s0)     # kick queue 1 (TX)

        li      a0, 'T'
        jal     write_byte
        li      a0, '\n'
        jal     write_byte

        RETURN



hash_mismatch:
	li		a0, 'm'
	jal		write_byte

	# Re-establish net state (t3/s0/t4 are stale after disk+blake2s)
	li	s0, VIRTIO_NET_BASE
	li	t0, RX_QUEUE_DATA_OFFSET
	add	t3, gp, t0			# t3 = RX queue base
	li	t0, 4096
	add	t4, t3, t0			# t4 = used ring base (queue_base + QueueAlign)
	li	s1, 0				# s1 = last_used_idx

poll_loop:
	fence r, r

	# Poll used.idx (offset +2 in used ring) — incremented by device on each received packet
	lhu t5, 2(t4)
	beq t5, s1, poll_loop	# spin until used.idx != last_used_idx

	# Packet received — print length from used.ring[0].len
	# ring[last_used_idx % QueueNum] — with QueueNum=1 this is always ring[0] at offset +8
	li a0, 'P'
	jal write_byte
	li a0, '='
	jal write_byte
	li a0, '0'
	jal write_byte
	li a0, 'x'
	jal write_byte
	lw a0, 8(t4)		# used.ring[0].len
	jal print_hex
	li a0, '\n'
	jal write_byte

	# Hex dump the packet (virtio_net_hdr + ethernet frame)
	addi a0, t3, 512	# buffer address
	lw a1, 8(t4)		# byte count
	jal hexdump

	# Check if ARP request: ethertype=08:06 at buf+24, opcode=00:01 at buf+32
	lw	t0, 8(t4)		# packet length
	li	t1, 54
	blt t0, t1, not_arp
	lbu t0, 536(t3)		# buf+24: ethertype high
	li	t1, 0x08
	bne t0, t1, not_arp
	lbu t0, 537(t3)		# buf+25: ethertype low
	li	t1, 0x06
	bne t0, t1, not_arp
	lbu t0, 544(t3)		# buf+32: opcode high
	bnez t0, not_arp
	lbu t0, 545(t3)		# buf+33: opcode low
	li	t1, 0x01
	bne t0, t1, not_arp
	jal send_arp_reply
not_arp:

	# Advance last_used_idx
	addi s1, s1, 1
	slli s1, s1, 16
	srli s1, s1, 16			# keep it 16-bit (zero-extend)

	# Re-post descriptor: increment avail.idx so device can use the buffer again
	lhu t5, 18(t3)			# avail.idx
	addi t5, t5, 1
	sh t5, 18(t3)			# avail.idx++
	fence w, w
	sw zero, VIRT_QUEUE0(s0)	# kick queue 0 (RX)

	j poll_loop

1:	wfi
	j		1b

error_not_virtio:
error_not_disk:
error_features_not_supported:
	li		a0, 'z' 
	jal		write_byte
1:	wfi
	j		1b



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
