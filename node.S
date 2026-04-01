.equ	UART_BASE,		0x10000000
.equ	UART_LSR,		5
.equ	UART_WR_MASK,		0x20

.equ	VIRT_MAGIC,		0x74726976
.equ	VIO_MAGIC,		0x000
.equ	VIRTIO_DISK_BASE,	0x10001000
.equ	VIRTIO_NET_BASE,	0x10002000
.equ	VIRT_QUEUE0,		0x050
.equ	VIO_DEVICE_ID,		0x008
.equ	VIO_DEVICE_FEATURES,	0x010
.equ	VIO_DRIVER_FEATURES,	0x020
.equ	VIO_GUEST_PAGE_SIZE,	0x028
.equ	VIO_QUEUE_SEL,		0x030
.equ	VIO_QUEUE_NUM,		0x038
.equ	VIO_QUEUE_ALIGN,	0x03C
.equ	VIO_QUEUE_PFN,		0x040
.equ	VIO_STATUS,		0x070

.equ	RX_QUEUE_DATA_OFFSET,	0		# net RX queue base (page-aligned)
.equ	TX_QUEUE_DATA_OFFSET,	8192		# net TX queue base (page-aligned)
.equ	DISK_DATA_BUFFER,	16384		# disk read/write buffer (512 bytes)
.equ	VIRT_DESCRIPTOR_TABLE,	20480		# disk descriptor table (page-aligned: 5×4096)
.equ	VIRT_DISK_STATUS,	25088		# after disk used ring (20480+4096+512)
.equ	VIRT_DISK_HEADER,	25090
.equ	HOST_TABLE,		25120		# Store 6 byte host entries (32 spaces)
.equ	LOAD_LOC,		25312		# binary load location (unlimited headroom)

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

.equ	CLIENT_PORT,		1234

.equ	MAX_HOSTS,		16
.equ	HOST_ENTRY_SZ,		6		# 4 bytes IP + 2 bytes port (big endian)


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

.macro INIT_NET 
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
	srli		t1, t1, 12		# PFN = address >> 12
	sw		t1, VIO_QUEUE_PFN(t0)

	# Set DRIVER_OK bit (4) - Device is now "Live"
	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 4
	sw		t1, VIO_STATUS(t0)
.endm



_start:
	csrr		tp, mhartid
	bnez		tp, secondary_park

	LOAD_ADDRESS	gp, data
	li		t0, 4095
	add		gp, gp, t0
	li		t0, -4096
	and		gp, gp, t0
	li		t0, 0x100000
	add		sp, gp, t0

	# zero gp+0 through gp+LOAD_LOC (covers net queues + disk structures)
	mv		t2, gp
	li		t3, LOAD_LOC
	add		t3, gp, t3
1:	sw		zero, 0(t2)
	addi		t2, t2, 4
	bltu		t2, t3, 1b

	INIT_DISK
	INIT_NET

	jal		read_hosts

	li		s0, VIRTIO_NET_BASE
	mv		t3, gp				# t3 = RX queue base
	li		t0, 4096
	add		t4, t3, t0			# t4 = used ring base
	li		s1, 0				# s1 = last_used_idx
	li		s3, 0				# s3 = chunks_received

poll_loop:
	fence		r, r
	lhu		t5, 2(t4)
	beq		t5, s1, poll_loop

	li		a0, 'p'
	jal		write_byte

	# ARP? ethertype=08:06 at t3+536, opcode=00:01 at t3+544
	lw		t0, 8(t4)		# packet length
	li		t1, 54
	blt		t0, t1, not_arp
	lbu		t0, 536(t3)
	li		t1, 0x08
	bne		t0, t1, not_arp
	lbu		t0, 537(t3)
	li		t1, 0x06
	bne		t0, t1, not_arp
	lbu		t0, 544(t3)
	bnez		t0, not_arp
	lbu		t0, 545(t3)
	li		t1, 0x01
	bne		t0, t1, not_arp

	li		a0, 'x'
	jal		write_byte
	jal		send_arp_reply
	li		a0, 'z'
	jal		write_byte
not_arp:
	# advance last_used_idx
	addi		s1, s1, 1
	slli		s1, s1, 16
	srli		s1, s1, 16

	# re-post RX descriptor
	lhu		t5, 18(t3)
	addi		t5, t5, 1
	sh		t5, 18(t3)
	fence		w, w
	sw		zero, VIRT_QUEUE0(s0)


	j		poll_loop

1:	wfi
	j		1b

# Send ARP reply. Reads sender info from RX buffer, writes reply to TX buffer.
# Clobbers: a0, a1, t0, t2. Preserves: t3, t4, s1.
send_arp_reply:
	SETUP		s0 

	li		s0, VIRTIO_NET_BASE

	# a0 = RX buffer (gp + RX_QUEUE_DATA_OFFSET + 512 = gp + 512)
	addi		a0, gp, 512

	# a1 = TX buffer (gp + TX_QUEUE_DATA_OFFSET + 512)
	li		a1, TX_QUEUE_DATA_OFFSET + 512
	add		a1, gp, a1

	# virtio_net_hdr: 12 bytes, all zero
	sw		zero, 0(a1)
	sw		zero, 4(a1)
	sw		zero, 8(a1)

	# Ethernet dst MAC = ARP sender MAC from RX (same bytes reused for ARP target MAC below)
	lbu		t0, 34(a0)
	sb		t0, 12(a1)
	lbu		t0, 35(a0)
	sb		t0, 13(a1)
	lbu		t0, 36(a0)
	sb		t0, 14(a1)
	lbu		t0, 37(a0)
	sb		t0, 15(a1)
	lbu		t0, 38(a0)
	sb		t0, 16(a1)
	lbu		t0, 39(a0)
	sb		t0, 17(a1)

	# Ethernet src MAC = guest MAC
	mv		t2, a0
	addi		a0, a1, 18
	jal		write_guest_mac
	mv		a0, t2

	# EtherType = 08:06 (ARP)
	li		t0, 0x08
	sb		t0, 24(a1)
	li		t0, 0x06
	sb		t0, 25(a1)

	# ARP: hw type=00:01, proto type=08:00, hw size=06, proto size=04
	sb		zero, 26(a1)
	li		t0, 0x01
	sb		t0, 27(a1)
	li		t0, 0x08
	sb		t0, 28(a1)
	sb		zero, 29(a1)
	li		t0, 0x06
	sb		t0, 30(a1)
	li		t0, 0x04
	sb		t0, 31(a1)

	# ARP opcode = 00:02 (reply)
	sb		zero, 32(a1)
	li		t0, 0x02
	sb		t0, 33(a1)

	# ARP sender MAC = guest MAC
	mv		t2, a0
	addi		a0, a1, 34
	jal		write_guest_mac
	mv		a0, t2

	# ARP sender IP = guest IP
	li		t0, GUEST_IP_0
	sb		t0, 40(a1)
	li		t0, GUEST_IP_1
	sb		t0, 41(a1)
	li		t0, GUEST_IP_2
	sb		t0, 42(a1)
	li		t0, GUEST_IP_3
	sb		t0, 43(a1)

	# ARP target MAC = ARP sender MAC from RX (same source as Ethernet dst above)
	lbu		t0, 34(a0)
	sb		t0, 44(a1)
	lbu		t0, 35(a0)
	sb		t0, 45(a1)
	lbu		t0, 36(a0)
	sb		t0, 46(a1)
	lbu		t0, 37(a0)
	sb		t0, 47(a1)
	lbu		t0, 38(a0)
	sb		t0, 48(a1)
	lbu		t0, 39(a0)
	sb		t0, 49(a1)

	# ARP target IP = ARP sender IP from RX
	lbu		t0, 40(a0)
	sb		t0, 50(a1)
	lbu		t0, 41(a0)
	sb		t0, 51(a1)
	lbu		t0, 42(a0)
	sb		t0, 52(a1)
	lbu		t0, 43(a0)
	sb		t0, 53(a1)

	mv		a0, a1
	li		a1, 54
	jal		tx_kick

	RETURN

# write_guest_mac: write 6-byte guest MAC to address in a0. Clobbers t0.
write_guest_mac:
	li		t0, GUEST_MAC_0
	sb		t0, 0(a0)
	li		t0, GUEST_MAC_1
	sb		t0, 1(a0)
	li		t0, GUEST_MAC_2
	sb		t0, 2(a0)
	li		t0, GUEST_MAC_3
	sb		t0, 3(a0)
	li		t0, GUEST_MAC_4
	sb		t0, 4(a0)
	li		t0, GUEST_MAC_5
	sb		t0, 5(a0)
	ret	

# tx_kick: post TX descriptor and kick virtio-net TX queue
# a0 = buffer address, a1 = packet length. Leaf, clobbers t0-t2.
tx_kick:
	li		t2, TX_QUEUE_DATA_OFFSET
	add		t2, gp, t2
	sw		a0, 0(t2)
	sw		zero, 4(t2)
	sw		a1, 8(t2)		
	sh		zero, 12(t2)
	sh		zero, 14(t2)		
	sh		zero, 16(t2)
	lhu		t0, 18(t2)
	addi		t0, t0, 1
	sh		t0, 18(t2)
	sh		zero, 20(t2)
	fence		w, w
	li		t0, VIRTIO_NET_BASE
	li		t1, 1
	sw		t1, VIRT_QUEUE0(t0)
	ret	

read_hosts:
	SETUP		s0, s1, s2
	li		s0, HOST_TABLE
	add		s0, s0, gp			# s0 = HOST_TABLE


parse_loop:
	li		t0, UART_BASE
1:	lbu		t1, UART_LSR(t0)
	andi		t1, t1, 0x01
	beqz		t1, 1b
	lbu		s1, 0(t0)


	mv		a0, s1
	jal		write_byte

	li		t0, 4
	beq		s1, t0, end_loop
	j		parse_loop
end_loop:

	RETURN

secondary_park:
	LOAD_ADDRESS	t1, hart_jump
1:	fence		r, r
	lw		t0, 0(t1)
	beqz		t0, 1b
	jr		t0

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


error_not_virtio:
error_not_disk:		
error_features_not_supported:
	li	a0, 'Z'
# fatal: print char in a0 + '!', then halt
fatal:
	jal	write_byte	
	li	a0, '!'
	jal	write_byte
1:	wfi		
	j	1b

hart_jump:
	.word	0
data:

