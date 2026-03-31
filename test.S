.equ UART_BASE,	0x10000000
.equ UART_LSR,	5
.equ UART_WR_MASK,	0x20
.equ TX_QUEUE_DATA_OFFSET, 0
.equ RX_QUEUE_DATA_OFFSET, 16384

.macro LOAD_ADDRESS reg, label
_base\@:
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

_start:
	li s0, 0x10002000	# virtio-net MMIO base (virtio-mmio-bus.1)
	sw zero, 0x70(s0)	# Reset device

	li t0, 1
	sw t0, 0x70(s0)		# ACK

	# ACK + DRIVER
	li t0, 3
	sw t0, 0x70(s0)

 	# 4. Feature negotiation (simple: accept what the device offers)
	lw t1, 0x010(s0)	# Read host features (offset 0x10)
	sw t1, 0x020(s0)	# Write them back as guest features (offset 0x20)

	# Set FEATURES_OK bit (8)
	lw t1, 0x070(s0)
	ori t1, t1, 8
	sw t1, 0x070(s0)

	# 5. Set guest page size (required for legacy interface)
	li t0, 4096
	sw t0, 0x028(s0)	# Page size register

	# Manual alignment using 'data'
	LOAD_ADDRESS gp, data
	li t0, 4095
	add gp, gp, t0
	li t0, -4096
	and gp, gp, t0		# gp = 4096-byte aligned base
	li t0, 0x100000
	add sp, gp, t0		# sp = gp + 1MB

	# 6. RX Queue (queue 0 per virtio-net spec)
	li t0, 0
	sw t0, 0x030(s0)	# select queue 0 (RX)
	li t0, 1
	sw t0, 0x038(s0)	# QueueNum = 1
	li t0, 4096
	sw t0, 0x03C(s0)	# QueueAlign = 4096

	# RX PFN (queue 0)
	li t0, RX_QUEUE_DATA_OFFSET
	add t2, gp, t0
	srli t2, t2, 12
	sw t2, 0x040(s0)	# QueuePFN

	# 7. TX Queue (queue 1 per virtio-net spec)
	li t0, 1
	sw t0, 0x030(s0)	# select queue 1 (TX)
	li t0, 1
	sw t0, 0x038(s0)	# QueueNum = 1
	li t0, 4096
	sw t0, 0x03C(s0)	# QueueAlign = 4096

	# TX PFN (queue 1)
	li t0, TX_QUEUE_DATA_OFFSET
	add t2, gp, t0
	srli t2, t2, 12
	sw t2, 0x040(s0)	# QueuePFN

	# Set DRIVER_OK bit (4)
	lw t1, 0x070(s0)
	ori t1, t1, 4
	sw t1, 0x070(s0)

	# === RX BUFFER POST ===
	# RX queue base
	li t0, RX_QUEUE_DATA_OFFSET
	add t3, gp, t0		# t3 = RX queue memory base

	# Descriptor 0 at offset 0 (16 bytes per descriptor)
	addi t4, t3, 512		# buffer address (well past desc+avail rings)
	sw t4, 0(t3)		# desc[0].addr low
	sw zero, 4(t3)		# desc[0].addr high
	li t4, 1536		# buffer length
	sw t4, 8(t3)		# desc[0].len
	li t4, 2		# VIRTQ_DESC_F_WRITE
	sh t4, 12(t3)		# desc[0].flags
	sh zero, 14(t3)		# desc[0].next

	# Available ring starts at offset 16 (1 descriptor × 16 bytes)
	sh zero, 16(t3)		# avail.flags = 0
	li t4, 1
	sh t4, 18(t3)		# avail.idx = 1 (one descriptor posted)
	sh zero, 20(t3)		# avail.ring[0] = descriptor index 0

	# Fence before kick to ensure descriptor/avail ring writes are visible
	fence w, w

	# Kick the RX queue (queue 0)
	li t0, 0
	sw t0, 0x050(s0)


	# RX queue base
	li t0, RX_QUEUE_DATA_OFFSET
	add t3, gp, t0		# t3 = RX queue memory base

	# Used ring is at queue_base + QueueAlign (4096)
	# used.flags: t3+4096, used.idx: t3+4098, used.ring[0].len: t3+4104
	li t0, 4096
	add t4, t3, t0		# t4 = used ring base

	li s1, 0		# s1 = last_used_idx

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
	jal print_hex32
	li a0, '\n'
	jal write_byte

	# Hex dump the packet (virtio_net_hdr + ethernet frame)
	addi a0, t3, 512	# buffer address
	lw a1, 8(t4)		# byte count
	jal hexdump

	# Check if ARP request: ethertype=08:06 at buf+24, opcode=00:01 at buf+32
	lw  t0, 8(t4)			# packet length
	li  t1, 54
	blt t0, t1, not_arp
	lbu t0, 536(t3)			# buf+24: ethertype high
	li  t1, 0x08
	bne t0, t1, not_arp
	lbu t0, 537(t3)			# buf+25: ethertype low
	li  t1, 0x06
	bne t0, t1, not_arp
	lbu t0, 544(t3)			# buf+32: opcode high
	bnez t0, not_arp
	lbu t0, 545(t3)			# buf+33: opcode low
	li  t1, 0x01
	bne t0, t1, not_arp
	jal send_arp_reply
not_arp:

	# Advance last_used_idx
	addi s1, s1, 1
	slli s1, s1, 16
	srli s1, s1, 16		# keep it 16-bit (zero-extend)

	# Re-post descriptor: increment avail.idx so device can use the buffer again
	lhu t5, 18(t3)		# avail.idx
	addi t5, t5, 1
	sh t5, 18(t3)		# avail.idx++
	fence w, w
	sw zero, 0x050(s0)		# kick queue 0

	j poll_loop

write_byte:
	li		t1, UART_BASE
	lbu		t2, UART_LSR(t1)
	andi		t2, t2, UART_WR_MASK
	beqz		t2, write_byte
	sb		a0, 0(t1)
	ret

# a0 = value — prints 8 hex digits, clobbers t0-t2, a0-a1
print_hex32:
	mv		a1, a0			# a1 holds original value; a0 is free for UART polling
	li		t0, 28			# shift starting at highest nibble
1:	srl		t1, a1, t0		# shift from preserved value
	andi		t1, t1, 0xF
	li		t2, 10
	blt		t1, t2, 2f
	addi		t1, t1, 7		# 'A'-'9'-1
2:	addi		t1, t1, '0'
	li		t2, UART_BASE
3:	lbu		a0, UART_LSR(t2)	# a0 = UART status (a1 untouched)
	andi		a0, a0, UART_WR_MASK
	beqz		a0, 3b
	sb		t1, 0(t2)
	addi		t0, t0, -4
	bgez		t0, 1b
	ret

# hexdump: a0=ptr, a1=len — prints "XX XX XX ..." 16 bytes per line
hexdump:
	addi	sp, sp, -32
	sw	ra,  0(sp)
	sw	s2,  4(sp)
	sw	s3,  8(sp)
	sw	s4, 12(sp)
	sw	s5, 16(sp)

	mv	s2, a0		# s2 = ptr
	mv	s3, a1		# s3 = remaining bytes
	li	s4, 0		# s4 = column counter

hexdump_loop:
	beqz	s3, hexdump_done
	lbu	s5, 0(s2)	# s5 = current byte

	srli	a0, s5, 4	# high nibble
	jal	print_nibble
	andi	a0, s5, 0xF	# low nibble
	jal	print_nibble
	li	a0, ' '
	jal	write_byte

	addi	s2, s2, 1
	addi	s3, s3, -1
	addi	s4, s4, 1
	andi	t0, s4, 0xF	# newline every 16 bytes
	bnez	t0, hexdump_loop
	li	a0, '\n'
	jal	write_byte
	j	hexdump_loop

hexdump_done:
	li	a0, '\n'
	jal	write_byte
	lw	ra,  0(sp)
	lw	s2,  4(sp)
	lw	s3,  8(sp)
	lw	s4, 12(sp)
	lw	s5, 16(sp)
	addi	sp, sp, 32
	ret

# print_nibble: a0=nibble (0-15) — prints one hex character, tail-calls write_byte
print_nibble:
	li	t0, 10
	blt	a0, t0, 1f
	addi	a0, a0, 7	# 'A'-'9'-1
1:	addi	a0, a0, '0'
	j	write_byte	# tail call

# Send ARP reply. Reads sender info from RX buffer, writes reply to TX buffer.
# Clobbers: a0, a1, t0, t1, t2. Preserves: t3, t4, s0, s1.
send_arp_reply:
	addi	sp, sp, -4
	sw	ra, 0(sp)

	# a0 = RX buffer (gp + RX_QUEUE_DATA_OFFSET + 512)
	li	a0, RX_QUEUE_DATA_OFFSET + 512
	add	a0, gp, a0

	# a1 = TX buffer (gp + TX_QUEUE_DATA_OFFSET + 512 = gp + 512)
	addi	a1, gp, 512

	# virtio_net_hdr: 12 bytes, all zero
	sw	zero, 0(a1)
	sw	zero, 4(a1)
	sw	zero, 8(a1)

	# Ethernet dest MAC = ARP sender MAC from RX (a0+34..39)
	lbu	t0, 34(a0); sb t0, 12(a1)
	lbu	t0, 35(a0); sb t0, 13(a1)
	lbu	t0, 36(a0); sb t0, 14(a1)
	lbu	t0, 37(a0); sb t0, 15(a1)
	lbu	t0, 38(a0); sb t0, 16(a1)
	lbu	t0, 39(a0); sb t0, 17(a1)

	# Ethernet src MAC = guest MAC (52:54:00:12:34:56)
	li	t0, 0x52; sb t0, 18(a1)
	li	t0, 0x54; sb t0, 19(a1)
	sb	zero,     20(a1)
	li	t0, 0x12; sb t0, 21(a1)
	li	t0, 0x34; sb t0, 22(a1)
	li	t0, 0x56; sb t0, 23(a1)

	# EtherType = 08:06 (ARP)
	li	t0, 0x08; sb t0, 24(a1)
	li	t0, 0x06; sb t0, 25(a1)

	# ARP: hw type=00:01, proto type=08:00, hw size=06, proto size=04
	sb	zero,     26(a1)
	li	t0, 0x01; sb t0, 27(a1)
	li	t0, 0x08; sb t0, 28(a1)
	sb	zero,     29(a1)
	li	t0, 0x06; sb t0, 30(a1)
	li	t0, 0x04; sb t0, 31(a1)

	# ARP opcode = 00:02 (reply)
	sb	zero,     32(a1)
	li	t0, 0x02; sb t0, 33(a1)

	# ARP sender MAC = guest MAC (52:54:00:12:34:56)
	li	t0, 0x52; sb t0, 34(a1)
	li	t0, 0x54; sb t0, 35(a1)
	sb	zero,     36(a1)
	li	t0, 0x12; sb t0, 37(a1)
	li	t0, 0x34; sb t0, 38(a1)
	li	t0, 0x56; sb t0, 39(a1)

	# ARP sender IP = 10.0.2.15 (our guest IP)
	li	t0, 0x0A; sb t0, 40(a1)
	sb	zero,     41(a1)
	li	t0, 0x02; sb t0, 42(a1)
	li	t0, 0x0F; sb t0, 43(a1)

	# ARP target MAC = ARP sender MAC from RX (a0+34..39)
	lbu	t0, 34(a0); sb t0, 44(a1)
	lbu	t0, 35(a0); sb t0, 45(a1)
	lbu	t0, 36(a0); sb t0, 46(a1)
	lbu	t0, 37(a0); sb t0, 47(a1)
	lbu	t0, 38(a0); sb t0, 48(a1)
	lbu	t0, 39(a0); sb t0, 49(a1)

	# ARP target IP = ARP sender IP from RX (a0+40..43)
	lbu	t0, 40(a0); sb t0, 50(a1)
	lbu	t0, 41(a0); sb t0, 51(a1)
	lbu	t0, 42(a0); sb t0, 52(a1)
	lbu	t0, 43(a0); sb t0, 53(a1)

	# TX descriptor at gp (TX queue base, TX_QUEUE_DATA_OFFSET=0)
	sw	a1,   0(gp)		# desc[0].addr low = TX buffer
	sw	zero,  4(gp)		# desc[0].addr high = 0
	li	t0, 54
	sw	t0,    8(gp)		# desc[0].len = 54
	sh	zero, 12(gp)		# desc[0].flags = 0 (device reads, not writes)
	sh	zero, 14(gp)		# desc[0].next = 0

	# TX available ring at gp+16
	sh	zero, 16(gp)		# avail.flags = 0
	lhu	t0,   18(gp)		# read current avail.idx
	addi	t0, t0, 1
	sh	t0,   18(gp)		# avail.idx++
	sh	zero, 20(gp)		# avail.ring[0] = descriptor 0

	fence	w, w
	li	t0, 1
	sw	t0, 0x050(s0)		# kick queue 1 (TX)

	li	a0, 'T'
	jal	write_byte
	li	a0, '\n'
	jal	write_byte

	lw	ra, 0(sp)
	addi	sp, sp, 4
	ret

data:
