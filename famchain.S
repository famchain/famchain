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
.equ	VIRT_QUEUE0,		0x050
.equ	VIO_NET_ID,		1		# Device ID for Network is 1
.equ	VIO_MAGIC,		0x000
.equ	VIO_DEVICE_ID,		0x008
.equ	VIO_QUEUE_PFN,		0x040
.equ	VIO_STATUS,		0x070
.equ	VIRT_MAGIC,		0x74726976

.equ	VIRT_DISK_BUFFER,	0
.equ	VIRT_DESCRIPTOR_TABLE,	512
.equ	VIRT_DISK_STATUS,	8704		# reserve space for 'used ring'
.equ	VIRT_DISK_HEADER,	8706
.equ	LOAD_LOC,		8722



.altmacro
.macro LOAD_ADDRESS reg, label
_base\@:
	# Uses \@ to make a unique constant name for every expansion
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

.macro LOAD_DATA reg tmp
	LOAD_ADDRESS \reg, data
	li \tmp, 4095
	add \reg, \reg, \tmp
	li \tmp, -4096
	and \reg, \reg, \tmp
	li \tmp, 3584
	add \reg, \reg, \tmp
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


.macro QR_STEP a, b, d, tmp, rot
	add	\a, \a, \b
	xor	\d, \d, \a
	slli \tmp, \d, \rot		# tmp = d << rot
	srli \d, \d, (32 - \rot)	# d = d >> (32 - rot)
	or	\d, \d, \tmp		# d = (d << rot) | (d >> (32 - rot))
.endm

# a, b, c, d are the 4 registers you're working on
.macro CHACHA_QR a, b, c, d
	QR_STEP \a, \b, \d, t5, 16		# Step 1: d is rotated
	QR_STEP \c, \d, \b, t5, 12		# Step 2: b is rotated
	QR_STEP \a, \b, \d, t5, 8		# Step 3: d is rotated
	QR_STEP \c, \d, \b, t5, 7		# Step 4: b is rotated
.endm

.macro DOUBLE_ROUND
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
.macro PERMUTE
	DOUBLE_ROUND
	DOUBLE_ROUND
	DOUBLE_ROUND
	DOUBLE_ROUND
	DOUBLE_ROUND
	DOUBLE_ROUND
	DOUBLE_ROUND
	DOUBLE_ROUND
	DOUBLE_ROUND
	DOUBLE_ROUND
.endm

.macro ADD_BACK reg ind
	lw		t5, \ind(a0)
	add		t5, \reg, t5
	sw		t5, \ind(a0)
.endm


.macro COMPRESS
	lw		s0, 0(a0)
	lw		s1, 4(a0)
	lw		s2, 8(a0)
	lw		s3, 12(a0)
	lw		s4, 16(a0)
	lw		s5, 20(a0)
	lw		s6, 24(a0)
	lw		s7, 28(a0)
	lw		s8, 32(a0)
	lw		s9, 36(a0)
	lw		s10, 40(a0)
	lw		t0, 44(a0)
	lw		t1, 48(a0)
	lw		t2, 52(a0)
	lw		t3, 56(a0)
	lw		t4, 60(a0)

	PERMUTE

	ADD_BACK	s0, 0
	ADD_BACK	s1, 4
	ADD_BACK	s2, 8
	ADD_BACK	s3, 12
	ADD_BACK	s4, 16
	ADD_BACK	s5, 20
	ADD_BACK	s6, 24
	ADD_BACK	s7, 28
	ADD_BACK	s8, 32
	ADD_BACK	s9, 36
	ADD_BACK	s10, 40
	ADD_BACK	t0, 44
	ADD_BACK	t1, 48
	ADD_BACK	t2, 52
	ADD_BACK	t3, 56
	ADD_BACK	t4, 60

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

	# Set FEATURES_OK bit (8)
	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 8
	sw		t1, VIO_STATUS(t0)

	# Check if FEATURES_OK was accepted
	lw		t1, VIO_STATUS(t0)
	andi		t2, t1, 8
	beqz		t2, error_features_not_supported



	# Set DRIVER_OK bit (4) - Device is now "Live"
	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 4
	sw		t1, VIO_STATUS(t0)

	# zero the buffer
	mv		t1, gp
	mv		t2, t1
	li		t3, LOAD_LOC
	add		t3, t3, t2

1:
	sb		zero, 0(t2)
	addi		t2, t2, 1
	blt		t2, t3, 1b

	addi	t1, t1, VIRT_DESCRIPTOR_TABLE
	sw	t1, VIO_QUEUE_PFN(t0)
.endm

# a0 = sector
# a1 = counter
.macro READ_BLOCK
	mv		t0, gp
	addi		t1, t0, VIRT_DESCRIPTOR_TABLE	# t1 = Disk table
	li		t2, VIRT_DISK_HEADER		# t2 = Disk header
	add		t2, t2, t0
	li		t3, VIRT_DISK_STATUS
	add		t3, t3, t0		# t3 = Disk status

	sw		a1, 8(t2)

	sw		t2, 0(t1)		# Addr
	sw		zero, 4(t1)
	li		t4, 16
	sw		t4, 8(t1)		# Len
	li		t4, 1		# NEXT flag
	sh		t4, 12(t1)		# Flags
	sh		t4, 14(t1)



	# 2. Setup Descriptor 1 (Data Buffer)
	sw		t0, 16(t1)		# Addr
	sw		zero, 20(t1)

	li		t4, 512
	sw		t4, 24(t1)		# Len
	li		t4, 3		# NEXT | WRITE flags
	sh		t4, 28(t1)		# Flags
	li		t4, 2
	sh		t4, 30(t1)		# Next index = 2


	sw		t3, 32(t1)		# Addr (Table + 32)
	sw		zero, 36(t1)
	li		t4, 1
	sw		t4, 40(t1)		# Len
	li		t4, 2		# WRITE flag
	sh		t4, 44(t1)		# Flags
	sh		zero, 46(t1)		# Next = 0 (End)


	# 4. Notify the Available Ring
	# Available Ring starts at offset 256 (after 16 descriptors)
	addi		t4, t1, 256
	sh		zero, 4(t4)		# Set ring[0] = 0 (Start at Desc 0)
	sh		a0, 2(t4)		# Set idx

	li		t5, 0xFF
	sb		t5, 0(t3)

	# 5. Kick the hardware
	li		t5, VIRTIO_DISK_BASE		# VIRTIO_DISK_BASE
	sw		zero, VIRT_QUEUE0(t5)		# Notify Queue 0

	# 6. Wait for disk_status to change from 0xFF
	li		t5, 0xFF
1:	lbu		t4, 0(t3)
	beq		t4, t5, 1b
.endm


# Main entry point
_start:
	LOAD_DATA	gp, t0
	INIT_DISK

	li		a0, 0
	li		a1, 1
	READ_BLOCK	


	LOAD_ADDRESS	sp, data
	addi		sp, sp, 15
	andi		sp, sp, -16
	li		t0, 0x100000
	add		sp, sp, t0

	lbu		a0, 0(gp)
	jal		print_hex
	li		a0, '\n'
	jal		write_byte


	mv		a0, sp
	addi		sp, sp, -64
	mv		a2, sp
	li		t0, 1
	sw		t0, 0(a0)
	li		t0, 1
	sw		t0, 64(a0)
	li		a1, 65
	jal		hash
	mv		a0, a2
	jal		print_hash
	li		a0, '\n'
	jal		write_byte

1:	wfi
	j		1b

hash:
	.macro ZERO_BLOCK ptr
		.set i, 0
		.rept 16
			sw zero, (i * 4)(\ptr)
			.set i, i + 1
		.endr
	.endm

	.macro XOR_BLOCK state_ptr, input_ptr
		.set i, 0
		.rept 16
			lw	t0, (i * 4)(\state_ptr)
			lw	t1, (i * 4)(\input_ptr)
			xor	t0, t0, t1
			sw	t0, (i * 4)(\state_ptr)
			.set i, i + 1
		.endr
	.endm

	.macro COPY_64 dest, src
		.set i, 0
		.rept 16
			lw	t0, (i * 4)(\src)
			sw	t0, (i * 4)(\dest)
			.set i, i + 1
		.endr
	.endm

	SETUP		s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11
	addi		sp, sp, -64
	mv		s11, a1			# original len

	mv		a3, a0			# a0 is used so copy a0 to a3
	mv		a0, sp
	ZERO_BLOCK	a0

1:	li		t0, 64
	bltu		a1, t0, 2f	
	XOR_BLOCK	a0, a3
	COMPRESS
	addi		a1, a1, -64
	addi		a3, a3, 64
	j		1b
2:
	beqz		a1, 4f			# skip if len % 64 == 0
	mv		t3, a0
3:
	lbu		t0, 0(t3)
	lbu		t1, 0(a3)
	xor		t0, t0, t1
	sb		t0, 0(t3)
	addi		a3, a3, 1
	addi		t3, t3, 1
	addi		a1, a1, -1
	bnez		a1, 3b 
	COMPRESS
4:
 	lw		t0, 0(a0)
	xor		t0, t0, s11		# Mix total length
	sw		t0, 0(a0)
	COMPRESS
	COPY_64		a2, a0

	addi		sp, sp, 64
	RETURN


print_hash:
	.macro PRINT_INDEX ind
		lw		a0,		\ind(s0)
		jal		print_hex
	.endm
	SETUP		s0
	mv		s0, a0
	li		a1, 1
	PRINT_INDEX	0
	PRINT_INDEX	4
	PRINT_INDEX	8
	PRINT_INDEX	12
	PRINT_INDEX	16
	PRINT_INDEX	20
	PRINT_INDEX	24
	PRINT_INDEX	28
	mv		a0, s0
	RETURN
	
write_byte:
	li		t1, UART_BASE
	lbu		t2, UART_LSR(t1)
	andi		t2, t2, UART_WR_MASK
	beqz		t2, write_byte
	sb		a0, 0(t1)
	ret

print_hex:
	SETUP		s0, s1, s2, t0, t1, t2, a0

	mv		s0, a0		# Save original value

	# Print "0x" prefix
	bnez		a1, skip_0x
	li		a0, '0' 
	jal		write_byte
	li		a0, 'x'
	jal		write_byte
skip_0x:

1:	li		s1, 28		# Start at highest nibble
2:	
	srl		t2, s0, s1		# Isolate nibble
	andi		t2, t2, 0xF
	
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

data:
