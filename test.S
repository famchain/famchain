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

	li s0, 0x10007000	# virtio-net MMIO base
	sw zero, 0x70(s0)

	li a0, 'B'
	jal write_byte

	li t0, 1
	sw t0, 0x70(s0)

		# ACK + DRIVER
		li t0, 3
		sw t0, 0x70(s0)

 	# 4. Feature negotiation (simple: accept what the device offers)
	lw t1, 0x010(s0)	# Read host features (offset 0x10)
	sw t1, 0x020(s0)	# Write them back as guest features (offset 0x20)

	# 5. Set guest page size (required for legacy interface)
	li t0, 4096
	sw t0, 0x028(s0)	# Page size register

	# 6. TX Queue (queue 0)
	li t0, 0
	sw t0, 0x030(s0)		# select queue 0

	# Manual alignment + PFN for TX and RX using 'data'
	LOAD_ADDRESS gp, data
	li t0, 4095
	add gp, gp, t0
	li t0, -4096
	and gp, gp, t0		# gp = 4096-byte aligned base

	# TX PFN
	li t0, TX_QUEUE_DATA_OFFSET
	add t2, gp, t0
	srli t2, t2, 12
	sw t2, 0x03C(s0)

	# RX PFN
	li t0, RX_QUEUE_DATA_OFFSET
	add t2, gp, t0
	srli t2, t2, 12
	sw t2, 0x03C(s0)

	# === RX BUFFER POST (minimal correct version) ===
    # RX queue base
    li t0, RX_QUEUE_DATA_OFFSET
    add t3, gp, t0             # t3 = RX queue memory base

    # Descriptor 0 at offset 0 of RX queue memory
    addi t4, t3, 512           # buffer address (leave space for rings)
    sw t4, 0(t3)               # desc[0].addr low
    sw zero, 4(t3)             # desc[0].addr high

    li t4, 1536                # buffer length
    sw t4, 8(t3)

    li t4, 2                   # VIRTQ_DESC_F_WRITE
    sw t4, 12(t3)              # desc[0].flags

    # Available ring (legacy layout)
    li t4, 0
    sw t4, 0(t3)               # avail.flags = 0
    li t4, 1                   # one descriptor posted
    sw t4, 2(t3)               # avail.idx = 1
    li t4, 0
    sw t4, 4(t3)               # avail.ring[0] = descriptor 0

    # Kick the RX queue
    li t0, 1
    sw t0, 0x050(s0)

    li a0, 'e'
    jal write_byte

    # RX queue base
    li t0, RX_QUEUE_DATA_OFFSET
    add t3, gp, t0             # t3 = RX queue memory base

    li t4, 0                   # last seen used index

poll_loop:
    # Read used.idx (at offset 2 in the used ring for simple layout)
    lw t5, 2(t3)               # used.idx

    bne t5, t4, packet_received   # new packet arrived

    j poll_loop

packet_received:
    li a0, 'P'                 # P = packet received!
    jal write_byte



    # For now, just update the index and keep polling
    mv t4, t5
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

data:
