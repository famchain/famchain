.equ	UART_BASE,		0x10000000
.equ	UART_LSR,		5
.equ	UART_WR_MASK,		0x20

.equ	VIRTIO_NET_BASE,	0x10001000
.equ	VIRT_MAGIC,		0x74726976
.equ	VIO_NET_ID,		1		# Device ID for Network is 1
.equ	VIO_MAGIC,		0x000
.equ	VIO_DEVICE_ID,		0x008
.equ	VIO_STATUS,		0x070
.equ	VIO_QUEUE_SEL,		0x030
.equ	VIO_QUEUE_NUM,		0x038
.equ	VIO_QUEUE_PFN,		0x040
.equ	VIO_GUEST_PAGE_SIZE,	0x028
.equ	VIO_INT_STATUS,		0x060
.equ	VIO_INT_ACK,		0x064

.equ	MTIME,			0x0200BFF8	# CLINT mtime (low 32 bits)
.equ	MTIMECMP,		0x02004000	# CLINT mtimecmp[0]
.equ	TIMER_INTERVAL,		1000000		# ticks between polls (~100ms at 10MHz)

.equ	NET_RX_HEADER,		0		
.equ	NET_RX_BUFFER,		4096
.equ	NET_RX_RING,		8192
.equ	NET_RX_SZ,		12288
.equ	VIO_USED_RING,		0x1000		# Offset from NET_RX_RING

.macro LOAD_ADDRESS reg, label
_base\@:
	# Uses \@ to make a unique constant name for every expansion
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

	LOAD_ADDRESS	s0, data
	li		t0, 4095
	add		s0, s0, t0
	li		t0, -4096
	and		s0, s0, t0
	li		t0, VIRTIO_NET_BASE

	# 1. Verify it's a VirtIO Network Device
	lw		t1, VIO_MAGIC(t0)
	li		t2, VIRT_MAGIC
	bne		t1, t2, error_not_virtio

	# Print VirtIO version as ASCII digit
	lw		t1, 0x004(t0)
	addi		a0, t1, '0'
	jal		write_byte

	lw		t1, VIO_DEVICE_ID(t0)
	li		t2, VIO_NET_ID
	bne		t1, t2, error_not_net

	# 2. Reset and Handshake (Standard VirtIO)
	sw		zero, VIO_STATUS(t0)		# Reset
	li		t1, 1
	sw		t1, VIO_STATUS(t0)		# ACK
	ori		t1, t1, 2
	sw		t1, VIO_STATUS(t0)		# DRIVER

	# (Negotiating "defaults" by setting FEATURES_OK)
	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 8
	sw		t1, VIO_STATUS(t0)

	# 3. Setup Queue 0 (RECEIVE QUEUE)
	sw		zero, VIO_QUEUE_SEL(t0)
	li		t1, 16		# 16 slots
	sw		t1, VIO_QUEUE_NUM(t0)

	li		t1, 4096
	sw		t1, VIO_GUEST_PAGE_SIZE(t0)	# sets guest_page_shift=12 for PFN calculation

	li		t1, NET_RX_RING
	add		t1, t1, s0
	srli		t1, t1, 12			# Convert to PFN
	sw		t1, VIO_QUEUE_PFN(t0)

	# 4. Give the hardware a "Bucket" to catch packets
	# In Networking, we have to provide a Buffer BEFORE a packet arrives.
	#LOAD_ADDRESS t1, net_rx_ring    # Descriptor Table Base
	li		t1, NET_RX_RING
	add		t1, t1, s0

	# Descriptor 0: The Network Header (12 bytes)
	# VirtIO Net needs a small header before the actual data
	#LOAD_ADDRESS t2, net_rx_header
	li		t2, NET_RX_HEADER
	add		t2, t2, s0
	sw		t2, 0(t1)			# Addr low
	sw		zero, 4(t1)			# Addr high
	li		t2, 12
	sw		t2, 8(t1)			# Len
	li		t2, 3				# NEXT | WRITE flags
	sh		t2, 12(t1)			# Flags
	li		t2, 1
	sh		t2, 14(t1)			# Next = 1

	# Descriptor 1: The Data Buffer (Where the packet goes)
	li		t2, NET_RX_BUFFER
	add		t2, t2, s0
	sw		t2, 16(t1)			# Addr low (Table + 16)
	sw		zero, 20(t1)			# Addr high
	li		t2, 1514			# Standard Ethernet Max Size
	sw		t2, 24(t1)			# Len
	li		t2, 2				# WRITE flag (No NEXT, end of chain)
	sh		t2, 28(t1)			# Flags
	sh		zero, 30(t1)

	# 5. Notify the hardware that a "Receive Bucket" is ready
	addi		t3, t1, 256			# Avail Ring offset
	sh		zero, 0(t3)			# flags = 0
	li		t2, 0
	sh		t2, 4(t3)			# ring[0] points to Desc 0
	li		t2, 1
	sh		t2, 2(t3)			# idx = 1 (Ready to receive 1 packet)

	# Kick Queue 0 (RX)
	sw		zero, 0x050(t0)

	# DRIVER_OK: device is fully configured
	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 4
	sw		t1, VIO_STATUS(t0)

	fence	io, rw	# Fence I/O and Memory Read/Write

	# Print status register as hex byte (two nibbles)
	lw		t1, VIO_STATUS(t0)
	srli		a0, t1, 4
	li		t2, 10
	blt		a0, t2, 1f
	addi		a0, a0, 'a' - 10
	j		2f
1:	addi		a0, a0, '0'
2:	jal		write_byte
	andi		a0, t1, 0xf
	li		t2, 10
	blt		a0, t2, 3f
	addi		a0, a0, 'a' - 10
	j		4f
3:	addi		a0, a0, '0'
4:	jal		write_byte

	li		a0, 'x'
	jal		write_byte


	li	a0, 'p'
	jal	write_byte

poll_for_packet:
	li	t0, VIRTIO_NET_BASE
	lw	t1, VIO_INT_STATUS(t0)
	beqz	t1, poll_for_packet
	sw	t1, VIO_INT_ACK(t0)

	li	a0, '!'
	jal	write_byte


park:
	wfi
	j		park

write_byte: 
	li		t4, UART_BASE
103:	lbu		t3, UART_LSR(t4)
	andi		t3, t3, UART_WR_MASK
	beqz		t3, 103b
	sb		a0, 0(t4)
	ret	

error_not_virtio:
	li		a0, 'y'
	jal		write_byte
	j		park

error_not_net:
	li		a0, 'z'
	jal		write_byte
	j		park

error_features_not_supported:
	li		a0, 'q'
	jal		write_byte
	j		park


int_handler:
	# Print '$' to confirm timer handler was entered
	li	t4, UART_BASE
104:	lbu	t3, UART_LSR(t4)
	andi	t3, t3, UART_WR_MASK
	beqz	t3, 104b
	li	t3, '$'
	sb	t3, 0(t4)

	# Check VirtIO ISR for packet received
	li	t0, VIRTIO_NET_BASE
	lw	t1, VIO_INT_STATUS(t0)
	beqz	t1, 1f
	sw	t1, VIO_INT_ACK(t0)		# ack virtio interrupt
	li	s3, 1				# set received flag
1:
	# Re-arm timer: mtimecmp = mtime + TIMER_INTERVAL
	li	t0, MTIME
	lw	t1, 0(t0)
	li	t2, TIMER_INTERVAL
	add	t1, t1, t2
	li	t0, MTIMECMP
	li	t2, -1
	sw	t2, 4(t0)			# prevent spurious during write
	sw	t1, 0(t0)
	sw	zero, 4(t0)
	mret

data:
