# test_pow.S — PoW tests with disk-backed 16MB bible table
#
# Requires: virtio-blk disk (-drive file=tmp/pow_disk.img,...)
# First run generates the table (~3 min), subsequent runs load from disk.

.equ	EXIT_ADDR,		0x100000
.equ	EXIT_PASS,		0x5555
.equ	UART_BASE,		0x10000000
.equ	UART_LSR,		5
.equ	UART_WR_MASK,		0x20

.equ	VIRTIO_DISK_BASE,	0x10001000
.equ	VIRT_QUEUE0,		0x050
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

.equ	DISK_DATA_BUFFER,	0			# first 512 bytes of gp region
.equ	VIRT_DESCRIPTOR_TABLE,	4096			# page-aligned
.equ	VIRT_DISK_STATUS,	4096 + 4096 + 512	# after used ring
.equ	VIRT_DISK_HEADER,	4096 + 4096 + 512 + 2

.equ	TABLE_SIZE,		(16 * 1024 * 1024)	# 16MB
.equ	TABLE_SECTORS,		(TABLE_SIZE / 512)	# 32768
.equ	TABLE_MASK,		(TABLE_SIZE / 32 - 1)	# 0x7FFFF
.equ	MAGIC_WORD,		0x42494246		# "FBIB"
.equ	TABLE_ADDR,		0x82000000		# 16MB table in RAM

.include "macros.inc"
.include "blake2s.inc"
.include "compress.inc"
.include "pow.inc"

.macro RUN_TEST label
	LOAD_ADDRESS a0, \label
	jal	print_str
.endm

.macro PASS_TEST
	LOAD_ADDRESS a0, _str_pass
	jal	print_str
.endm

_start:
	LOAD_ADDRESS	gp, _gp_base
	li		t0, 4095
	add		gp, gp, t0
	li		t0, -4096
	and		gp, gp, t0
	li		sp, 0x90000000

	# Zero disk structures
	mv	t0, gp
	li	t1, VIRT_DISK_HEADER + 18
	add	t1, gp, t1
1:	sw	zero, 0(t0)
	addi	t0, t0, 4
	bltu	t0, t1, 1b

	# Init disk
	li	t0, VIRTIO_DISK_BASE
	lw	t1, VIO_MAGIC(t0)
	li	t2, VIRT_MAGIC
	bne	t1, t2, _fail
	sw	zero, VIO_STATUS(t0)
	li	t1, 1
	sw	t1, VIO_STATUS(t0)
	lw	t1, VIO_STATUS(t0)
	ori	t1, t1, 2
	sw	t1, VIO_STATUS(t0)
	lw	t1, VIO_DEVICE_FEATURES(t0)
	sw	zero, VIO_DRIVER_FEATURES(t0)
	lw	t1, VIO_STATUS(t0)
	ori	t1, t1, 8
	sw	t1, VIO_STATUS(t0)
	li	t1, 4096
	sw	t1, VIO_GUEST_PAGE_SIZE(t0)
	sw	zero, VIO_QUEUE_SEL(t0)
	li	t1, 16
	sw	t1, VIO_QUEUE_NUM(t0)
	li	t1, 4096
	sw	t1, VIO_QUEUE_ALIGN(t0)
	li	t1, VIRT_DESCRIPTOR_TABLE
	add	t1, gp, t1
	srli	t1, t1, 12
	sw	t1, VIO_QUEUE_PFN(t0)
	lw	t1, VIO_STATUS(t0)
	ori	t1, t1, 4
	sw	t1, VIO_STATUS(t0)

	# s8 = avail_idx counter (persists across all disk ops)
	li	s8, 0

	# ── Check disk for cached table ──
	li	a0, 0				# sector 0
	addi	s8, s8, 1
	mv	a1, s8
	jal	disk_read
	li	t0, DISK_DATA_BUFFER
	add	t0, gp, t0
	lw	t0, 0(t0)			# first word
	li	t1, MAGIC_WORD
	beq	t0, t1, _load_table

	# ── Generate table with progress ──
	li	a0, 'G'
	jal	write_byte

	# Phase 1: copy compressed data to table
	LOAD_ADDRESS	s0, _bible_compressed
	LOAD_ADDRESS	s1, _bible_compressed_end
	sub	s1, s1, s0			# compressed_len
	li	s2, TABLE_ADDR

	# Copy compressed data (word-at-a-time for speed)
	mv	t0, s0
	mv	t1, s2
	srli	t2, s1, 2			# word count
_gen_copy:
	beqz	t2, _gen_copy_done
	lw	t3, 0(t0)
	sw	t3, 0(t1)
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	j	_gen_copy
_gen_copy_done:
	# Copy remaining bytes
	andi	t2, s1, 3
_gen_copy_tail:
	beqz	t2, _gen_copy_all
	lbu	t3, 0(t0)
	sb	t3, 0(t1)
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	_gen_copy_tail
_gen_copy_all:
	# Pad to 32-byte boundary
	andi	t0, s1, 31
	beqz	t0, _gen_aligned
	li	t1, 32
	sub	t0, t1, t0
	add	t1, s2, s1
_gen_pad:
	beqz	t0, _gen_aligned
	sb	zero, 0(t1)
	addi	t1, t1, 1
	addi	t0, t0, -1
	j	_gen_pad
_gen_aligned:

	li	a0, 'C'
	jal	write_byte
	# Phase 2: blake2s chain with progress dots
	addi	s3, s1, 31
	li	t0, -32
	and	s3, s3, t0			# first generated offset
	li	s4, TABLE_SIZE
	addi	sp, sp, -32
	mv	s5, sp				# temp buffer
	li	s6, 0				# entry counter (for progress)
	# total_entries for progress
	sub	s7, s4, s3
	srli	s7, s7, 5			# total entries to generate

_gen_loop:
	bgeu	s3, s4, _gen_done

	# Print status every 4096 entries
	andi	t0, s6, 0x7FF			# every 2048 entries
	bnez	t0, _gen_no_dot
	li	a0, '.'
	jal	write_byte
_gen_no_dot:

	# Input: previous 32 bytes in table
	addi	a0, s3, -32
	add	a0, s2, a0

	# 16 rounds of blake2s
	li	s8, POW_BLAKE2S_ITERS
_gen_iter:
	beqz	s8, _gen_iter_done
	li	a1, 32
	mv	a2, s5
	jal	blake2s
	mv	a0, s5
	addi	s8, s8, -1
	j	_gen_iter
_gen_iter_done:

	# Copy to table
	add	t0, s2, s3
	mv	t1, s5
	lw	t3, 0(t1)
	sw	t3, 0(t0)
	lw	t3, 4(t1)
	sw	t3, 4(t0)
	lw	t3, 8(t1)
	sw	t3, 8(t0)
	lw	t3, 12(t1)
	sw	t3, 12(t0)
	lw	t3, 16(t1)
	sw	t3, 16(t0)
	lw	t3, 20(t1)
	sw	t3, 20(t0)
	lw	t3, 24(t1)
	sw	t3, 24(t0)
	lw	t3, 28(t1)
	sw	t3, 28(t0)

	addi	s3, s3, 32
	addi	s6, s6, 1
	j	_gen_loop

_gen_done:
	addi	sp, sp, 32
	li	a0, 'D'
	jal	write_byte

	# Write magic to sector 0
	# Restore avail_idx (s8 was clobbered by generation loop)
	li	s8, 1				# 1 disk_read happened before generation
	li	a0, 'E'
	jal	write_byte
	li	t0, DISK_DATA_BUFFER
	add	t0, gp, t0
	li	t1, MAGIC_WORD
	sw	t1, 0(t0)
	li	a0, 0
	addi	s8, s8, 1
	mv	a1, s8
	jal	disk_write
	li	a0, 'F'
	jal	write_byte

	# Write 16MB table starting at sector 1
	li	s0, 0
	li	s1, 1
	li	s2, TABLE_SIZE
_write_loop:
	bgeu	s0, s2, _write_done
	# Copy 512 bytes from table to disk buffer
	li	t0, DISK_DATA_BUFFER
	add	t0, gp, t0
	li	t1, TABLE_ADDR
	add	t1, t1, s0
	li	t2, 128				# 512 / 4
_wcopy:
	lw	t3, 0(t1)
	sw	t3, 0(t0)
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	bnez	t2, _wcopy
	mv	a0, s1
	addi	s8, s8, 1
	mv	a1, s8
	jal	disk_write
	addi	s0, s0, 512
	addi	s1, s1, 1
	# progress dot every 1024 sectors (~512KB)
	andi	t0, s1, 0x3FF
	bnez	t0, _write_loop
	li	a0, '.'
	jal	write_byte
	j	_write_loop
_write_done:

	LOAD_ADDRESS	a0, _lbl_saved
	jal	print_str
	j	_run_tests

_load_table:
	# Load 16MB from disk (sectors 1..32768)
	LOAD_ADDRESS	a0, _lbl_loading
	jal	print_str

	li	s0, 0				# byte offset
	li	s1, 1				# sector
	li	s2, TABLE_SIZE
_read_loop:
	bgeu	s0, s2, _read_done
	mv	a0, s1
	addi	s8, s8, 1
	mv	a1, s8
	jal	disk_read
	# Copy 512 bytes from disk buffer to table
	li	t0, DISK_DATA_BUFFER
	add	t0, gp, t0
	li	t1, TABLE_ADDR
	add	t1, t1, s0
	li	t2, 128
_rcopy:
	lw	t3, 0(t0)
	sw	t3, 0(t1)
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	bnez	t2, _rcopy
	addi	s0, s0, 512
	addi	s1, s1, 1
	j	_read_loop
_read_done:

	LOAD_ADDRESS	a0, _lbl_loaded
	jal	print_str

_run_tests:
	# ══════════════════════════════════════════════════
	# Test 1: pow_hash produces non-zero output
	# ══════════════════════════════════════════════════
	RUN_TEST tn_pow_hash
	li	a0, TABLE_ADDR
	li	a1, TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	addi	sp, sp, -32
	mv	a3, sp
	jal	pow_hash
	# Verify non-zero
	lw	t0, 0(sp)
	lw	t1, 4(sp)
	or	t0, t0, t1
	lw	t1, 8(sp)
	or	t0, t0, t1
	lw	t1, 12(sp)
	or	t0, t0, t1
	lw	t1, 16(sp)
	or	t0, t0, t1
	lw	t1, 20(sp)
	or	t0, t0, t1
	lw	t1, 24(sp)
	or	t0, t0, t1
	lw	t1, 28(sp)
	or	t0, t0, t1
	beqz	t0, test_fail
	addi	sp, sp, 32
	PASS_TEST

	# ══════════════════════════════════════════════════
	# Test 2: same input → same hash (deterministic)
	# ══════════════════════════════════════════════════
	RUN_TEST tn_pow_determ
	addi	sp, sp, -64			# two 32-byte outputs
	# First hash
	li	a0, TABLE_ADDR
	li	a1, TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	mv	a3, sp
	jal	pow_hash
	# Second hash (same input)
	li	a0, TABLE_ADDR
	li	a1, TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	addi	a3, sp, 32
	jal	pow_hash
	# Compare
	li	t2, 8
	mv	t0, sp
	addi	t1, sp, 32
_det_cmp:
	beqz	t2, _det_ok
	lw	t3, 0(t0)
	lw	t4, 0(t1)
	bne	t3, t4, test_fail
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	j	_det_cmp
_det_ok:
	addi	sp, sp, 64
	PASS_TEST

	# ══════════════════════════════════════════════════
	# Test 3: different nonce → different hash
	# ══════════════════════════════════════════════════
	RUN_TEST tn_pow_diff
	addi	sp, sp, -64
	# Hash with nonce=0
	li	a0, TABLE_ADDR
	li	a1, TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	mv	a3, sp
	jal	pow_hash
	# Hash with nonce=1
	LOAD_ADDRESS	t0, _test_header
	li	t1, 1
	sw	t1, POW_NONCE_OFFSET(t0)	# set nonce=1
	li	a0, TABLE_ADDR
	li	a1, TABLE_MASK
	mv	a2, t0
	addi	a3, sp, 32
	jal	pow_hash
	# Restore nonce=0
	LOAD_ADDRESS	t0, _test_header
	sw	zero, POW_NONCE_OFFSET(t0)
	# Compare — must differ
	li	t2, 8
	mv	t0, sp
	addi	t1, sp, 32
	li	t5, 0				# diff count
_diff_cmp:
	beqz	t2, _diff_check
	lw	t3, 0(t0)
	lw	t4, 0(t1)
	beq	t3, t4, _diff_next
	addi	t5, t5, 1
_diff_next:
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	j	_diff_cmp
_diff_check:
	beqz	t5, test_fail			# all same = bad
	addi	sp, sp, 64
	PASS_TEST

	# ══════════════════════════════════════════════════
	# Test 4: mine_block with easy target
	# ══════════════════════════════════════════════════
	RUN_TEST tn_pow_mine_easy
	# Allocate hash output below, then push args on top
	addi	sp, sp, -32			# hash output
	mv	t0, sp				# out_ptr = hash output area
	addi	sp, sp, -8			# stack args
	sw	t0, 0(sp)			# out_ptr
	li	t0, 100
	sw	t0, 4(sp)			# max_iter
	li	a0, TABLE_ADDR
	li	a1, TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	LOAD_ADDRESS	a3, _target_easy
	jal	mine_block
	addi	sp, sp, 40			# pop args + hash output
	bltz	a0, test_fail			# should find nonce 0
	PASS_TEST

	# ══════════════════════════════════════════════════
	# Test 5: mine_block with impossible target (all zeros)
	# ══════════════════════════════════════════════════
	RUN_TEST tn_pow_mine_fail
	addi	sp, sp, -32
	mv	t0, sp
	addi	sp, sp, -8
	sw	t0, 0(sp)
	li	t0, 10
	sw	t0, 4(sp)			# max_iter = 10
	li	a0, TABLE_ADDR
	li	a1, TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	LOAD_ADDRESS	a3, _target_impossible
	jal	mine_block
	addi	sp, sp, 40
	li	t0, -1
	bne	a0, t0, test_fail		# must return -1
	PASS_TEST

	# ══════════════════════════════════════════════════
	# All passed
	# ══════════════════════════════════════════════════
	li	t0, EXIT_ADDR
	li	t1, EXIT_PASS
	sw	t1, 0(t0)
1:	wfi
	j	1b

test_fail:
	LOAD_ADDRESS	a0, _str_fail
	jal	print_str
1:	wfi
	j	1b


# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

print_str:
	SETUP	s0
	mv	s0, a0
1:	lbu	a0, 0(s0)
	beqz	a0, 2f
	jal	write_byte
	addi	s0, s0, 1
	j	1b
2:	RETURN

write_byte:
	li	t1, UART_BASE
	lbu	t2, UART_LSR(t1)
	andi	t2, t2, UART_WR_MASK
	beqz	t2, write_byte
	sb	a0, 0(t1)
	ret

# disk_read: read sector a0, avail_idx a1
disk_read:
	li	t5, VIRT_DESCRIPTOR_TABLE
	add	t1, gp, t5
	li	t3, VIRT_DISK_STATUS
	add	t3, gp, t3
	addi	t2, t3, 2
	sw	zero, 0(t2)			# type = read
	sw	a0, 8(t2)			# sector
	# desc[0]: header
	sw	t2, 0(t1)
	sw	zero, 4(t1)
	li	t4, 16
	sw	t4, 8(t1)
	li	t4, 1
	sh	t4, 12(t1)
	sh	t4, 14(t1)
	# desc[1]: data buffer (NEXT|WRITE = 3)
	li	t5, DISK_DATA_BUFFER
	add	t5, gp, t5
	sw	t5, 16(t1)
	sw	zero, 20(t1)
	li	t4, 512
	sw	t4, 24(t1)
	li	t4, 3
	sh	t4, 28(t1)
	li	t4, 2
	sh	t4, 30(t1)
	# desc[2]: status
	sw	t3, 32(t1)
	sw	zero, 36(t1)
	li	t4, 1
	sw	t4, 40(t1)
	li	t4, 2
	sh	t4, 44(t1)
	sh	zero, 46(t1)
	# notify
	addi	t4, t1, 256
	sh	zero, 4(t4)
	li	t5, 0xFF
	sb	t5, 0(t3)
	sh	a1, 2(t4)
	fence	w, w
	li	t5, VIRTIO_DISK_BASE
	sw	zero, VIRT_QUEUE0(t5)
	li	t5, 0xFF
1:	lbu	t4, 0(t3)
	beq	t4, t5, 1b
	fence	r, r
	ret

# disk_write: write sector a0, avail_idx a1
disk_write:
	li	t5, VIRT_DESCRIPTOR_TABLE
	add	t1, gp, t5
	li	t3, VIRT_DISK_STATUS
	add	t3, gp, t3
	addi	t2, t3, 2
	li	t4, 1
	sw	t4, 0(t2)			# type = write
	sw	a0, 8(t2)			# sector
	# desc[0]: header
	sw	t2, 0(t1)
	sw	zero, 4(t1)
	li	t4, 16
	sw	t4, 8(t1)
	li	t4, 1
	sh	t4, 12(t1)
	sh	t4, 14(t1)
	# desc[1]: data buffer (NEXT only, no WRITE = 1)
	li	t5, DISK_DATA_BUFFER
	add	t5, gp, t5
	sw	t5, 16(t1)
	sw	zero, 20(t1)
	li	t4, 512
	sw	t4, 24(t1)
	li	t4, 1
	sh	t4, 28(t1)
	li	t4, 2
	sh	t4, 30(t1)
	# desc[2]: status (WRITE = 2)
	sw	t3, 32(t1)
	sw	zero, 36(t1)
	li	t4, 1
	sw	t4, 40(t1)
	li	t4, 2
	sh	t4, 44(t1)
	sh	zero, 46(t1)
	# notify
	addi	t4, t1, 256
	sh	zero, 4(t4)
	li	t5, 0xFF
	sb	t5, 0(t3)
	sh	a1, 2(t4)
	fence	w, w
	li	t5, VIRTIO_DISK_BASE
	sw	zero, VIRT_QUEUE0(t5)
	li	t5, 0xFF
1:	lbu	t4, 0(t3)
	beq	t4, t5, 1b
	fence	r, r
	ret


# ──────────────────────────────────────────────────────────────────────────────
DEFINE_BLAKE2S
DEFINE_COMPRESS
DEFINE_POW


# ──────────────────────────────────────────────────────────────────────────────
# String constants
# ──────────────────────────────────────────────────────────────────────────────
.balign 4
_str_pass:	.asciz	"PASS\n"
_str_fail:	.asciz	"FAIL\n"

_lbl_generating:	.asciz	"Generating 16MB bible table...\n"
_lbl_saved:		.asciz	"Saved to disk.\n"
_lbl_loading:		.asciz	"Loading table from disk...\n"
_lbl_loaded:		.asciz	"Loaded.\n"

tn_pow_hash:		.asciz	"pow_hash non-zero   "
tn_pow_determ:		.asciz	"pow_hash determinism"
tn_pow_diff:		.asciz	"pow_hash nonce diff "
tn_pow_mine_easy:	.asciz	"mine_block easy     "
tn_pow_mine_fail:	.asciz	"mine_block impossible"

# ──────────────────────────────────────────────────────────────────────────────
# Test data
# ──────────────────────────────────────────────────────────────────────────────
.balign 4
_test_header:
	.zero	124
	.word	0				# nonce at offset 124

_target_easy:
	.word	0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
	.word	0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF

_target_impossible:
	.word	0, 0, 0, 0, 0, 0, 0, 0

.balign 4
_bible_compressed:
	.incbin	"resources/bible.compressed"
_bible_compressed_end:

.balign 4
_gp_base:
