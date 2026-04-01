# p.S — full node stub: writes itself to disk, then loops printing status
#
# Memory layout (relative to gp, which points to 'data' label, page-aligned):
#   gp + 0:     disk data buffer (512 bytes)
#   gp + 4096:  disk descriptor table (page-aligned, 16 descs × 16 bytes = 256)
#   gp + 4352:  disk available ring (256 + 6 + 2*16 = 294 bytes)
#   gp + 4608:  disk used ring
#   gp + 5120:  disk status byte
#   gp + 5122:  disk request header (16 bytes)

.equ    EXIT_ADDR,              0x100000
.equ    EXIT_PASS,              0x5555
.equ    UART_BASE,              0x10000000
.equ    UART_RD_MASK,           0x1
.equ    UART_WR_MASK,           0x20
.equ    UART_LSR,               5
.equ    UART_RBR,               0

.equ	VIRTIO_DISK_BASE,	0x10001000
.equ	VIRT_QUEUE0,		0x050
.equ	VIO_DEVICE_FEATURES,	0x010
.equ	VIO_DRIVER_FEATURES,	0x020
.equ	VIO_GUEST_PAGE_SIZE,	0x028
.equ	VIO_QUEUE_SEL,		0x030
.equ	VIO_QUEUE_NUM,		0x038
.equ	VIO_QUEUE_ALIGN,	0x03C
.equ	VIO_QUEUE_PFN,		0x040
.equ	VIO_STATUS,		0x070

# Data region offsets (from gp)
.equ	DISK_BUF,		0		# 512-byte sector buffer
.equ	DESC_TABLE,		4096		# descriptor table (page-aligned)
.equ	DISK_STATUS,		5120		# status byte
.equ	DISK_HEADER,		5122		# virtio_blk request header (16 bytes)


.altmacro
.macro LOAD_ADDRESS reg, label
_base\@:
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

_node_start:
	addi		gp, gp, 1
	# ── setup gp and sp ──
	LOAD_ADDRESS	gp, _node_data
	li		t0, 4095
	add		gp, gp, t0
	li		t0, -4096
	and		gp, gp, t0
	li		t0, 0x10000		# 64KB stack
	add		sp, gp, t0

	# ── zero data region (gp+0 through gp+DISK_HEADER+16) ──
	mv		t0, gp
	li		t1, DISK_HEADER + 16
	add		t1, gp, t1
1:	sw		zero, 0(t0)
	addi		t0, t0, 4
	bltu		t0, t1, 1b

	# ── initialize virtio disk ──
	li		t0, VIRTIO_DISK_BASE
	sw		zero, VIO_STATUS(t0)		# reset

	li		t1, 1
	sw		t1, VIO_STATUS(t0)		# ACK

	li		t1, 3
	sw		t1, VIO_STATUS(t0)		# ACK + DRIVER

	lw		t1, VIO_DEVICE_FEATURES(t0)
	sw		zero, VIO_DRIVER_FEATURES(t0)	# accept none

	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 8
	sw		t1, VIO_STATUS(t0)		# FEATURES_OK

	li		t1, 4096
	sw		t1, VIO_GUEST_PAGE_SIZE(t0)

	sw		zero, VIO_QUEUE_SEL(t0)		# queue 0
	li		t1, 16
	sw		t1, VIO_QUEUE_NUM(t0)
	li		t1, 4096
	sw		t1, VIO_QUEUE_ALIGN(t0)

	li		t1, DESC_TABLE
	add		t1, gp, t1
	srli		t1, t1, 12
	sw		t1, VIO_QUEUE_PFN(t0)		# PFN

	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 4
	sw		t1, VIO_STATUS(t0)		# DRIVER_OK

	# ── write self to disk, sector by sector ──
	li		s0, 0			# sector counter
	LOAD_ADDRESS	s2, _node_start		# source pointer
	LOAD_ADDRESS	s1, _node_data
	sub		s1, s1, s2		# s1 = NODE_SIZE (computed at runtime)
	li		s3, 0			# avail_idx counter

write_loop:
	# bytes this sector = min(512, s1)
	li		s4, 512
	bltu		s1, s4, 1f
	j		2f
1:	mv		s4, s1
2:
	# copy s4 bytes from s2 to DISK_BUF
	li		t0, DISK_BUF
	add		t1, gp, t0
	mv		t2, s4
3:	beqz		t2, 4f
	lbu		t3, 0(s2)
	sb		t3, 0(t1)
	addi		s2, s2, 1
	addi		t1, t1, 1
	addi		t2, t2, -1
	j		3b
4:
	# zero-pad remainder of sector
	li		t2, 512
	sub		t2, t2, s4
5:	beqz		t2, 6f
	sb		zero, 0(t1)
	addi		t1, t1, 1
	addi		t2, t2, -1
	j		5b
6:
	# write sector via disk_write(a0=sector, a1=avail_idx)
	mv		a0, s0
	addi		s3, s3, 1
	mv		a1, s3
	jal		disk_write

	addi		s0, s0, 1
	sub		s1, s1, s4
	bnez		s1, write_loop

	# ── print confirmation ──
	li		a0, 'W'
	jal		write_byte
	li		a0, 'O'
	jal		write_byte
	li		a0, 'K'
	jal		write_byte
	li		a0, '\n'
	jal		write_byte

	jal		exit

1:	wfi
	j		1b


# ──────────────────────────────────────────────────────────────────────────────
# disk_write: write 512 bytes from DISK_BUF to a given sector
# a0 = sector, a1 = avail_idx. Leaf function, clobbers t0-t5.
# ──────────────────────────────────────────────────────────────────────────────
disk_write:
	li	t5, DESC_TABLE
	add	t1, gp, t5			# t1 = descriptor table
	li	t3, DISK_STATUS
	add	t3, gp, t3			# t3 = status byte
	addi	t2, t3, 2			# t2 = request header (status + 2)

	li	t4, 1
	sw	t4, 0(t2)			# type = VIRTIO_BLK_T_OUT (write)
	sw	a0, 8(t2)			# sector

	# desc[0]: request header (device reads)
	sw	t2, 0(t1)
	sw	zero, 4(t1)
	li	t4, 16
	sw	t4, 8(t1)
	li	t4, 1				# NEXT
	sh	t4, 12(t1)
	sh	t4, 14(t1)			# next = 1

	# desc[1]: data buffer (device reads from our buffer: NEXT only)
	li	t5, DISK_BUF
	add	t5, gp, t5
	sw	t5, 16(t1)
	sw	zero, 20(t1)
	li	t4, 512
	sw	t4, 24(t1)
	li	t4, 1				# NEXT (device reads)
	sh	t4, 28(t1)
	li	t4, 2
	sh	t4, 30(t1)			# next = 2

	# desc[2]: status byte (device writes)
	sw	t3, 32(t1)
	sw	zero, 36(t1)
	li	t4, 1
	sw	t4, 40(t1)
	li	t4, 2				# WRITE
	sh	t4, 44(t1)
	sh	zero, 46(t1)

	# notify available ring
	addi	t4, t1, 256
	sh	zero, 4(t4)
	li	t5, 0xFF
	sb	t5, 0(t3)			# status sentinel
	sh	a1, 2(t4)			# avail.idx

	fence	w, w
	li	t5, VIRTIO_DISK_BASE
	sw	zero, VIRT_QUEUE0(t5)

	# wait for completion
	li	t5, 0xFF
1:	lbu	t4, 0(t3)
	beq	t4, t5, 1b
	fence	r, r
	ret


# ──────────────────────────────────────────────────────────────────────────────
write_byte:
	li	t1, UART_BASE
	lbu	t2, UART_LSR(t1)
	andi	t2, t2, UART_WR_MASK
	beqz	t2, write_byte
	sb	a0, 0(t1)
	ret

exit:
        li              t0, EXIT_ADDR           # load exit addr
        li              t1, EXIT_PASS           # shutdown command
        sw              t1, UART_RBR(t0)        # signal UART
1:      wfi                                     # wait for interrupt in loop
        j               1b



_node_data:
