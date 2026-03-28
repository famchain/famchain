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

# --- System Constants ---
.equ	UART_BASE,		0x10000000
.equ	UART_LSR,		5
.equ	UART_WR_MASK,		0x20
.equ	VIRTIO_DISK_BASE,	0x10001000	
.equ	VIO_MAGIC,		0x000
.equ	VIO_DEVICE_ID,		0x008
.equ	VIO_STATUS,		0x070

.equ	VIO_QUEUE_SEL,		0x030
.equ	VIO_QUEUE_NUM,		0x038
.equ	VIO_QUEUE_PFN,		0x040
.equ	VIRT_QUEUE0,		0x050
.equ	VIRT_MAGIC,		0x74726976
.equ	BIN_SIZE,		97265

.equ	VIRT_DISK_BUFFER,	0
.equ	VIRT_DESCRIPTOR_TABLE,	512
.equ	VIRT_DISK_STATUS,	4608
.equ	VIRT_DISK_HEADER,	4610

.macro LOAD_ADDRESS reg, label
_base\@:
	# Uses \@ to make a unique constant name for every expansion
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

.macro INIT_DISK
	li	t0, VIRTIO_DISK_BASE
	lw	t1, VIO_MAGIC(t0)	# Should be 0x74726976 ("virt")
	li	t2, VIRT_MAGIC
	bne	t1, t2, error_not_virtio

	lw	t1, VIO_DEVICE_ID(t0)	# Should be 2 for Block Device
	li	t2, 2
	bne	t1, t2, error_not_disk

	# 1. Reset the device
	sw	zero, VIO_STATUS(t0)

	# 2. Set ACKNOWLEDGE bit (1)
	li	t1, 1
	sw	t1, VIO_STATUS(t0)

	# 3. Set DRIVER bit (2)
	lw	t1, VIO_STATUS(t0)
	ori	t1, t1, 2
	sw	t1, VIO_STATUS(t0)

	# 4. Set FEATURES_OK bit (8)
	lw	t1, VIO_STATUS(t0)
	ori	t1, t1, 8
	sw	t1, VIO_STATUS(t0)

	# 5. Check if FEATURES_OK was accepted
	lw	t1, VIO_STATUS(t0)
	andi	t2, t1, 8
	beqz	t2, error_features_not_supported

	# 6. Set DRIVER_OK bit (4) - Device is now "Live"
	lw	t1, VIO_STATUS(t0)
	ori	t1, t1, 4
	sw	t1, VIO_STATUS(t0)

	# 1. Select Queue 0
	sw	zero, VIO_QUEUE_SEL(t0)

	# 2. Set Queue Size - 16
	li	t1, 16
	sw	t1, VIO_QUEUE_NUM(t0)

	# 3. Set Page Size (QEMU default is usually 4096)
	LOAD_ADDRESS t1 data

	# Zero the buffer
	li	t2, 0
	li	t3, 5122
1:
	add t4, t2, t1
	sb zero, 0(t4)
	bge t2, t3, 2f
	addi t2, t2, 1
	j 1b
2:
	addi	t1, t1, 512
	sw	t1, VIO_QUEUE_PFN(t0)
.endm


# a0 = sector
# a1 = counter
.macro READ_BLOCK
	LOAD_ADDRESS	t0, data			# t0 = Disk buffer
	addi		t1, t0, VIRT_DESCRIPTOR_TABLE	# t1 = Disk table
	li		t2, VIRT_DISK_HEADER		# t2 = Disk header
	add		t2, t2, t0
	li		t3, VIRT_DISK_STATUS
	add		t3, t3, t0			# t3 = Disk status

	sw		a1, 8(t2)

	sw		t2, 0(t1)			# Addr
	sw		zero, 4(t1)
	li		t4, 16
	sw		t4, 8(t1)			# Len
	li		t4, 1				# NEXT flag
	sh		t4, 12(t1)			# Flags
	sh		t4, 14(t1)



	# 2. Setup Descriptor 1 (Data Buffer)
	sw		t0, 16(t1)			# Addr
	sw		zero, 20(t1)

	li		t4, 512
	sw		t4, 24(t1)			# Len
	li		t4, 3				# NEXT | WRITE flags
	sh		t4, 28(t1)			# Flags
	li		t4, 2
	sh 		t4, 30(t1)			# Next index = 2


	sw		t3, 32(t1)			# Addr (Table + 32)
	sw		zero, 36(t1)
	li		t4, 1
	sw		t4, 40(t1)			# Len
	li		t4, 2				# WRITE flag
	sh		t4, 44(t1)			# Flags
	sh		zero, 46(t1)			# Next = 0 (End)


	# 4. Notify the Available Ring
	# Available Ring starts at offset 256 (after 16 descriptors)
	addi		t4, t1, 256		
	sh		zero, 4(t4)			# Set ring[0] = 0 (Start at Desc 0)
	sh		a0, 2(t4)			# Set idx = 1 (We have 1 chain ready)

	li		t5, 0xFF
	sb		t5, 0(t3)

	# 5. Kick the hardware
	li		t5, VIRTIO_DISK_BASE		# VIRTIO_DISK_BASE
	sw		zero, VIRT_QUEUE0(t5)		# Notify Queue 0

	# 6. Wait for disk_status to change from 0xFF
1:
	lbu		t4, 0(t3)
	li		t5, 0xFF
	beq		t4, t5, 1b
.endm

_start:
	INIT_DISK

	li		s0, BIN_SIZE
	li		s1, 0
	li		s2, 1				# Total requests sent

begin_loop:
	blez		s0, end_loop
	li		s4, 512
	addi		s0, s0, -512

	mv		a1, s1
	mv		a0, s2 
	READ_BLOCK	
	addi		s2, s2, 1


	# Point to disk buffer
	LOAD_ADDRESS	s3, data
1:
	lbu		a0, 0(s3)			# Get next byte
	beqz		a0, 2f
	jal		write_byte			# Print it to the UART
	addi		s3, s3, 1
	addi		s4, s4, -1
	blez		s4, 2f
	j		1b
2:

	li s11, 1
	#bgt s1, s11, end_loop

	addi s1, s1, 1
	j begin_loop
end_loop:

li a0, 'x'
jal write_byte

3:		wfi
		j 3b

error_not_virtio:
		li a0, '0'
		jal write_byte
		li a0, '\n'
100:		wfi	
		j 100b

error_not_disk:
		li a0, '1'
		jal write_byte
		li a0, '\n'
101:		wfi
		j 101b

error_features_not_supported:
		li a0, '2'
		jal write_byte
		li a0, '\n'
102:		wfi
		j 102b

write_byte: 
	li	t1, UART_BASE
103:	lbu	t2, UART_LSR(t1)
	andi	t2, t2, UART_WR_MASK
	beqz	t2, 103b
	sb	a0, 0(t1)
	ret	

data:
