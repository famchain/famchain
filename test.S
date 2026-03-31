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
	li a0, 'A'
	jal write_byte

	li s0, 0x10002000	# virtio-net MMIO base (virtio-mmio-bus.1)
	sw zero, 0x70(s0)	# Reset device

	li a0, 'B'
	jal write_byte

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
    add t3, gp, t0             # t3 = RX queue memory base

    # Descriptor 0 at offset 0 (16 bytes per descriptor)
    addi t4, t3, 512           # buffer address (well past desc+avail rings)
    sw t4, 0(t3)               # desc[0].addr low
    sw zero, 4(t3)             # desc[0].addr high
    li t4, 1536                # buffer length
    sw t4, 8(t3)               # desc[0].len
    li t4, 2                   # VIRTQ_DESC_F_WRITE
    sh t4, 12(t3)              # desc[0].flags
    sh zero, 14(t3)            # desc[0].next

    # Available ring starts at offset 16 (1 descriptor × 16 bytes)
    sh zero, 16(t3)            # avail.flags = 0
    li t4, 1
    sh t4, 18(t3)              # avail.idx = 1 (one descriptor posted)
    sh zero, 20(t3)            # avail.ring[0] = descriptor index 0

    # Fence before kick to ensure descriptor/avail ring writes are visible
    fence w, w

    # Kick the RX queue (queue 0)
    li t0, 0
    sw t0, 0x050(s0)


    li a0, 'e'
    jal write_byte

    # RX queue base
    li t0, RX_QUEUE_DATA_OFFSET
    add t3, gp, t0             # t3 = RX queue memory base

    # Used ring is at queue_base + QueueAlign (4096)
    # used.flags: t3+4096, used.idx: t3+4098, used.ring[0].len: t3+4104
    li t0, 4096
    add t4, t3, t0             # t4 = used ring base

    li s1, 0                   # s1 = last_used_idx

poll_loop:
    fence r, r

    # Poll used.idx (offset +2 in used ring) — incremented by device on each received packet
    lhu t5, 2(t4)
    beq t5, s1, poll_loop      # spin until used.idx != last_used_idx

    # Packet received — print length from used.ring[0].len
    # ring[last_used_idx % QueueNum] — with QueueNum=1 this is always ring[0] at offset +8
    li a0, 'P'
    jal write_byte
    lw a0, 8(t4)               # used.ring[0].len
    jal print_hex32

    # Advance last_used_idx
    addi s1, s1, 1
    slli s1, s1, 16
    srli s1, s1, 16            # keep it 16-bit (zero-extend)

    # Re-post descriptor: increment avail.idx so device can use the buffer again
    lhu t5, 18(t3)             # avail.idx
    addi t5, t5, 1
    sh t5, 18(t3)              # avail.idx++
    fence w, w
    sw zero, 0x050(s0)         # kick queue 0

    j poll_loop

	# wait
1:
	wfi
	j	1b

write_byte:
	li		t1, UART_BASE
	lbu		t2, UART_LSR(t1)
	andi		t2, t2, UART_WR_MASK
	beqz		t2, write_byte
	sb		a0, 0(t1)
	ret

# a0 = value — prints 8 hex digits, clobbers t0-t2 a0
print_hex32:
	li		t0, 28			# shift starting at highest nibble
1:	srl		t1, a0, t0
	andi		t1, t1, 0xF
	li		t2, 10
	blt		t1, t2, 2f
	addi		t1, t1, 7		# 'A'-'9'-1
2:	addi		t1, t1, '0'
	mv		a0, t1
	# inline write_byte to avoid clobbering t0
	li		t2, UART_BASE
3:	lbu		a0, UART_LSR(t2)
	andi		a0, a0, UART_WR_MASK
	beqz		a0, 3b
	sb		t1, 0(t2)
	addi		t0, t0, -4
	bgez		t0, 1b
	ret

data:
