# test_all.S — Unit tests for all libraries

.equ	EXIT_ADDR,		0x100000
.equ	EXIT_PASS,		0x5555
.equ	UART_BASE,		0x10000000
.equ	UART_LSR,		5
.equ	UART_WR_MASK,		0x20

# Virtio disk (for PoW table caching)
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
.equ	DISK_DATA_BUFFER,	0
.equ	VIRT_DESCRIPTOR_TABLE,	4096
.equ	VIRT_DISK_STATUS,	4096 + 4096 + 512
.equ	VIRT_DISK_HEADER,	4096 + 4096 + 512 + 2

# PoW table
.equ	POW_TABLE_SIZE,		(16 * 1024 * 1024)
.equ	POW_TABLE_MASK,		(POW_TABLE_SIZE / 32 - 1)
.equ	POW_TABLE_ADDR,		0x82000000
.equ	POW_DISK_MAGIC,		0x42494246

.include "lib_includes.inc"

# ──────────────────────────────────────────────────────────────────────────────
# Test macros
# ──────────────────────────────────────────────────────────────────────────────
.macro RUN_TEST label
	LOAD_ADDRESS a0, \label
	jal	print_str
.endm

.macro PASS_TEST
	LOAD_ADDRESS a0, _str_pass
	jal	print_str
.endm

# Memory layout in data region (from gp):
.equ	SK_OFF,		0
.equ	PK_OFF,		576
.equ	SIG_OFF,	1152
.equ	MSG_OFF,	1728
.equ	SEED_OFF,	1760

_start:
	# gp region: disk structures + test workspace
	# Separate from code/data since disk virtio needs page-aligned gp
	LOAD_ADDRESS	gp, _gp_base
	li		t0, 4095
	add		gp, gp, t0
	li		t0, -4096
	and		gp, gp, t0
	li		sp, 0x90000000

	# Zero disk structures at gp
	mv	t0, gp
	li	t1, VIRT_DISK_HEADER + 18
	add	t1, gp, t1
1:	sw	zero, 0(t0)
	addi	t0, t0, 4
	bltu	t0, t1, 1b

	# Init virtio disk
	li	t0, VIRTIO_DISK_BASE
	lw	t1, VIO_MAGIC(t0)
	li	t2, VIRT_MAGIC
	bne	t1, t2, _skip_disk		# no disk attached → skip init
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
_skip_disk:

	# ══════════════════════════════════════════════════
	# Blake2s
	# ══════════════════════════════════════════════════

	RUN_TEST tn_b2s_empty
	LOAD_ADDRESS	a0, tv_b2s_empty
	li		a1, 0
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv_b2s_empty_hash
	mv		a0, sp
	jal		check_hash_32
	addi		sp, sp, 32
	PASS_TEST

	RUN_TEST tn_b2s_abc
	LOAD_ADDRESS	a0, tv_b2s_abc
	li		a1, 3
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv_b2s_abc_hash
	mv		a0, sp
	jal		check_hash_32
	addi		sp, sp, 32
	PASS_TEST

	RUN_TEST tn_b2s_64
	LOAD_ADDRESS	a0, tv_b2s_64
	li		a1, 64
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv_b2s_64_hash
	mv		a0, sp
	jal		check_hash_32
	addi		sp, sp, 32
	PASS_TEST

	RUN_TEST tn_b2s_65
	LOAD_ADDRESS	a0, tv_b2s_65
	li		a1, 65
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv_b2s_65_hash
	mv		a0, sp
	jal		check_hash_32
	addi		sp, sp, 32
	PASS_TEST

	RUN_TEST tn_b2s_opt
	LOAD_ADDRESS	a0, tv_b2s_64
	addi		sp, sp, -32
	mv		a1, sp
	jal		blake2s_64
	LOAD_ADDRESS	t0, tv_b2s_64_hash
	mv		a0, sp
	jal		check_hash_32
	addi		sp, sp, 32
	PASS_TEST

	# ══════════════════════════════════════════════════
	# WOTS+
	# ══════════════════════════════════════════════════

	# Setup seed (0xAA * 32)
	li		t0, SEED_OFF
	add		t0, gp, t0
	li		t1, 0xAAAAAAAA
	.set	_i, 0
	.rept	8
	sw		t1, (_i * 4)(t0)
	.set	_i, _i + 1
	.endr

	RUN_TEST tn_wots_hash
	LOAD_ADDRESS	a0, tv_wots_msg_text
	li		a1, 21
	li		t0, MSG_OFF
	add		a2, gp, t0
	jal		blake2s
	li		t0, MSG_OFF
	add		a0, gp, t0
	LOAD_ADDRESS	t0, tv_wots_msg_hash
	jal		check_hash_32
	PASS_TEST

	RUN_TEST tn_wots_keygen
	li		t0, SEED_OFF
	add		a0, gp, t0
	li		t0, PK_OFF
	add		a1, gp, t0
	li		t0, SK_OFF
	add		a2, gp, t0
	jal		wots_keyfrom
	mv		a0, gp
	LOAD_ADDRESS	t0, tv_wots_sk0
	jal		check_hash_32
	PASS_TEST

	RUN_TEST tn_wots_sign
	li		t0, SK_OFF
	add		a0, gp, t0
	li		t0, MSG_OFF
	add		a1, gp, t0
	li		t0, SIG_OFF
	add		a2, gp, t0
	jal		wots_sign
	PASS_TEST

	RUN_TEST tn_wots_verify
	li		t0, PK_OFF
	add		a0, gp, t0
	li		t0, SIG_OFF
	add		a1, gp, t0
	li		t0, MSG_OFF
	add		a2, gp, t0
	jal		wots_verify
	bnez		a0, test_fail
	PASS_TEST

	RUN_TEST tn_wots_tmsg
	li		t0, MSG_OFF
	add		a0, gp, t0
	li		a1, 32
	jal		check_tamper
	PASS_TEST

	RUN_TEST tn_wots_tsig
	li		t0, SIG_OFF
	add		a0, gp, t0
	li		a1, 32
	jal		check_tamper
	PASS_TEST

	RUN_TEST tn_wots_tpk
	li		t0, PK_OFF
	add		a0, gp, t0
	li		a1, 32
	jal		check_tamper
	PASS_TEST

	# ══════════════════════════════════════════════════
	# Compression
	# ══════════════════════════════════════════════════

	RUN_TEST tn_cz_rt
	LOAD_ADDRESS	a0, tv_cz_repeat
	li	a1, 24
	jal	check_roundtrip
	PASS_TEST

	RUN_TEST tn_cz_short
	LOAD_ADDRESS	a0, tv_cz_short
	li	a1, 5
	jal	check_roundtrip
	PASS_TEST

	RUN_TEST tn_cz_large
	LOAD_ADDRESS	a0, tv_cz_large
	LOAD_ADDRESS	a1, tv_cz_large_end
	sub	a1, a1, a0
	jal	check_roundtrip
	PASS_TEST

	RUN_TEST tn_cz_mozilla
	LOAD_ADDRESS	s0, tv_cz_mozilla
	LOAD_ADDRESS	s1, tv_cz_mozilla_end
	sub	s1, s1, s0
	li	s2, 0x82000000
	li	s3, 0x82100000
	li	s4, 0x82800000
	mv	a0, s0
	mv	a1, s1
	mv	a2, s2
	mv	a3, s3
	jal	compress_block
	blez	a0, test_fail
	# compressed must be < 80% of input (sanity: actual compression happened)
	srli	t0, s1, 1			# input / 2
	srli	t1, s1, 2			# input / 4
	add	t0, t0, t1			# input * 3/4 ≈ 75%
	bge	a0, t0, test_fail
	mv	s5, a0
	mv	a0, s2
	mv	a1, s5
	mv	a2, s4
	li	a3, 0x00200000
	jal	decompress_block
	bne	a0, s1, test_fail
	mv	t0, s0
	mv	t1, s4
	mv	t2, s1
_cz_moz_cmp:
	beqz	t2, _cz_moz_ok
	lbu	t3, 0(t0)
	lbu	t4, 0(t1)
	bne	t3, t4, test_fail
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	_cz_moz_cmp
_cz_moz_ok:
	PASS_TEST

	RUN_TEST tn_cz_bible
	LOAD_ADDRESS	s0, tv_cz_bible
	LOAD_ADDRESS	s1, tv_cz_bible_end
	sub	s1, s1, s0			# input len

	# buffers at absolute addresses (within default 128MB QEMU RAM)
	li	s2, 0x82000000			# output (~4.5MB space)
	li	s3, 0x83000000			# match_array (~17.6MB)
	li	s4, 0x85000000			# decompress output (~4.5MB)

	# compress
	mv	a0, s0
	mv	a1, s1
	mv	a2, s2
	mv	a3, s3
	jal	compress_block
	blez	a0, test_fail
	# compressed must be < 75% of input
	srli	t0, s1, 1
	srli	t1, s1, 2
	add	t0, t0, t1
	bge	a0, t0, test_fail
	mv	s5, a0				# compressed size

	# decompress
	mv	a0, s2
	mv	a1, s5
	mv	a2, s4
	li	a3, 0x00500000			# 5MB capacity
	jal	decompress_block
	bne	a0, s1, test_fail

	# byte compare
	mv	t0, s0
	mv	t1, s4
	mv	t2, s1
_cz_bible_cmp:
	beqz	t2, _cz_bible_ok
	lbu	t3, 0(t0)
	lbu	t4, 0(t1)
	bne	t3, t4, test_fail
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	_cz_bible_cmp
_cz_bible_ok:
	PASS_TEST

	# ── Negative: corrupt compressed bible data at several positions ──
	# s2 = compressed bible data, s5 = compressed size, s1 = original size
	RUN_TEST tn_cz_corrupt
	li	s6, 4				# skip 4-byte header
_corrupt_loop:
	bge	s6, s5, _corrupt_done
	# flip byte
	add	t0, s2, s6
	lbu	t1, 0(t0)
	xori	t1, t1, 0xFF
	sb	t1, 0(t0)
	# try decompress (small gp-relative buffers, small capacity)
	mv	a0, s2
	mv	a1, s5
	li	t0, 0x40000
	add	a2, gp, t0			# decompress output
	li	a3, 4096			# small capacity
	jal	decompress_block
	mv	t5, a0
	# restore byte
	add	t0, s2, s6
	lbu	t1, 0(t0)
	xori	t1, t1, 0xFF
	sb	t1, 0(t0)
	# with 4096 capacity, result must differ from original 4.4MB size
	beq	t5, s1, test_fail
_corrupt_next:
	# step by compressed_size / 16 to test ~16 positions
	srli	t0, s5, 4
	li	t1, 1
	bge	t0, t1, _corrupt_step_ok
	mv	t0, t1
_corrupt_step_ok:
	add	s6, s6, t0
	j	_corrupt_loop
_corrupt_done:
	PASS_TEST

	# ── Fuzz: random data, varied sizes ──
	RUN_TEST tn_cz_fuzz
	li	s6, 0x12345678			# PRNG seed
	li	s7, 256				# iterations
_fuzz_loop:
	beqz	s7, _fuzz_done
	# fill 1024 bytes with xorshift32 output
	li	t0, 0x40000
	add	t0, gp, t0
	li	t1, 256				# 1024 / 4
	mv	t2, s6
_fuzz_fill:
	beqz	t1, _fuzz_try
	slli	t3, t2, 13
	xor	t2, t2, t3
	srli	t3, t2, 17
	xor	t2, t2, t3
	slli	t3, t2, 5
	xor	t2, t2, t3
	sw	t2, 0(t0)
	addi	t0, t0, 4
	addi	t1, t1, -1
	j	_fuzz_fill
_fuzz_try:
	mv	s6, t2
	# vary input length: 5 + (seed & 0x3FF) → 5..1028 bytes
	andi	a1, s6, 0x3FF
	addi	a1, a1, 5
	li	t0, 0x40000
	add	a0, gp, t0
	li	t0, 0x50000
	add	a2, gp, t0
	li	a3, 4096
	jal	decompress_block
	addi	s7, s7, -1
	j	_fuzz_loop
_fuzz_done:
	PASS_TEST

	# ── Truncation: decompress valid data at progressively shorter lengths ──
	# s2 = compressed bible data, s5 = compressed size
	RUN_TEST tn_cz_trunc
	li	s6, 5				# start at minimum length
_trunc_loop:
	bge	s6, s5, _trunc_done
	mv	a0, s2
	mv	a1, s6				# truncated length
	li	t0, 0x40000
	add	a2, gp, t0
	li	a3, 4096
	jal	decompress_block
	# must not return original size (truncated input can't produce full output)
	beq	a0, s1, test_fail
_trunc_next:
	# step by compressed_size / 64 to test ~64 cut points
	srli	t0, s5, 6
	li	t1, 1
	bge	t0, t1, _trunc_step_ok
	mv	t0, t1
_trunc_step_ok:
	add	s6, s6, t0
	j	_trunc_loop
_trunc_done:
	PASS_TEST

	# ── Edge cases ──
	RUN_TEST tn_cz_edge
	# 0-byte input → must reject
	li	t0, 0x40000
	add	a0, gp, t0
	li	a1, 0
	li	t0, 0x50000
	add	a2, gp, t0
	li	a3, 4096
	jal	decompress_block
	li	t0, -1
	bne	a0, t0, test_fail

	# 4-byte input → must reject (< 5)
	li	t0, 0x40000
	add	a0, gp, t0
	li	a1, 4
	li	t0, 0x50000
	add	a2, gp, t0
	li	a3, 4096
	jal	decompress_block
	li	t0, -1
	bne	a0, t0, test_fail

	# valid compressed data, capacity=0 → must reject
	mv	a0, s2
	mv	a1, s5
	li	t0, 0x40000
	add	a2, gp, t0
	li	a3, 0
	jal	decompress_block
	li	t0, -1
	bne	a0, t0, test_fail

	PASS_TEST

	# ══════════════════════════════════════════════════
	# BabyBear field arithmetic
	# ══════════════════════════════════════════════════

	RUN_TEST tn_fp_add
	li	a0, 1
	li	a1, 2
	jal	fp_add
	li	t0, 3
	bne	a0, t0, test_fail
	# wrap: (p-1) + 1 = 0
	li	a0, FP_P - 1
	li	a1, 1
	jal	fp_add
	bnez	a0, test_fail
	PASS_TEST

	RUN_TEST tn_fp_sub
	li	a0, 5
	li	a1, 3
	jal	fp_sub
	li	t0, 2
	bne	a0, t0, test_fail
	# underflow: 0 - 1 = p-1
	li	a0, 0
	li	a1, 1
	jal	fp_sub
	li	t0, FP_P - 1
	bne	a0, t0, test_fail
	PASS_TEST

	RUN_TEST tn_fp_mul
	li	a0, 3
	li	a1, 7
	jal	fp_mul
	li	t0, 21
	bne	a0, t0, test_fail
	# large: (p-1) * 2 = p-2
	li	a0, FP_P - 1
	li	a1, 2
	jal	fp_mul
	li	t0, FP_P - 2
	bne	a0, t0, test_fail
	PASS_TEST

	RUN_TEST tn_fp_inv
	# inv(1) = 1
	li	a0, 1
	jal	fp_inv
	li	t0, 1
	bne	a0, t0, test_fail
	# 42 * inv(42) = 1
	li	a0, 42
	jal	fp_inv
	mv	a1, a0
	li	a0, 42
	jal	fp_mul
	li	t0, 1
	bne	a0, t0, test_fail
	# (p-1) * inv(p-1) = 1
	li	a0, FP_P - 1
	jal	fp_inv
	mv	a1, a0
	li	a0, FP_P - 1
	jal	fp_mul
	li	t0, 1
	bne	a0, t0, test_fail
	PASS_TEST

	# ══════════════════════════════════════════════════
	# Poseidon2
	# ══════════════════════════════════════════════════

	RUN_TEST tn_p2_perm
	# Test permutation against Plonky3 test vector
	addi	sp, sp, -64
	LOAD_ADDRESS	t0, _p2_tv_input
	mv	t1, sp
	li	t2, 16
_p2t_load:
	lw	t3, 0(t0)
	sw	t3, 0(t1)
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	bnez	t2, _p2t_load
	mv	a0, sp
	jal	poseidon2_perm
	# Compare against expected output
	LOAD_ADDRESS	t0, _p2_tv_output
	mv	t1, sp
	li	t2, 16
_p2t_check:
	beqz	t2, _p2t_ok
	lw	t3, 0(t0)
	lw	t4, 0(t1)
	bne	t3, t4, test_fail
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	j	_p2t_check
_p2t_ok:
	addi	sp, sp, 64
	PASS_TEST

	RUN_TEST tn_p2_determ
	# Same input → same output (deterministic)
	addi	sp, sp, -128			# two 64-byte states
	# Init both to [1,0,...,0]
	li	t0, 32
	mv	t1, sp
_p2t_init2:
	sw	zero, 0(t1)
	addi	t1, t1, 4
	addi	t0, t0, -1
	bnez	t0, _p2t_init2
	li	t0, 1
	sw	t0, 0(sp)
	sw	t0, 64(sp)
	# Permute both
	mv	a0, sp
	jal	poseidon2_perm
	addi	a0, sp, 64
	jal	poseidon2_perm
	# Compare
	li	t2, 16
	mv	t0, sp
	addi	t1, sp, 64
_p2t_cmp:
	beqz	t2, _p2t_det_ok
	lw	t3, 0(t0)
	lw	t4, 0(t1)
	bne	t3, t4, test_fail
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	j	_p2t_cmp
_p2t_det_ok:
	addi	sp, sp, 128
	PASS_TEST

	RUN_TEST tn_p2_hash
	# Hash [1,2,3,4,5,6,7,8] → non-zero 8-element output
	addi	sp, sp, -64			# 32 bytes input + 32 bytes output
	li	t0, 1
	sw	t0, 0(sp)
	li	t0, 2
	sw	t0, 4(sp)
	li	t0, 3
	sw	t0, 8(sp)
	li	t0, 4
	sw	t0, 12(sp)
	li	t0, 5
	sw	t0, 16(sp)
	li	t0, 6
	sw	t0, 20(sp)
	li	t0, 7
	sw	t0, 24(sp)
	li	t0, 8
	sw	t0, 28(sp)
	mv	a0, sp				# input
	li	a1, 8				# num_elements
	addi	a2, sp, 32			# output
	jal	poseidon2_hash
	# Check output non-zero
	lw	t0, 32(sp)
	beqz	t0, test_fail
	addi	sp, sp, 64
	PASS_TEST

	# ══════════════════════════════════════════════════
	# Merkle tree
	# ══════════════════════════════════════════════════

	RUN_TEST tn_mk_build
	# Build a tree with 4 leaves, verify root is non-zero
	# Leaves: [1,0..0], [2,0..0], [3,0..0], [4,0..0]
	# Tree needs 8 nodes × 32 bytes = 256 bytes
	addi	sp, sp, -384			# 128 (leaves) + 256 (tree)
	mv	t0, sp
	li	t1, 96				# zero 384 bytes = 96 words
_mkt_zero:
	sw	zero, 0(t0)
	addi	t0, t0, 4
	addi	t1, t1, -1
	bnez	t1, _mkt_zero
	# Set leaf values
	li	t0, 1
	sw	t0, 0(sp)			# leaf[0][0] = 1
	li	t0, 2
	sw	t0, 32(sp)			# leaf[1][0] = 2
	li	t0, 3
	sw	t0, 64(sp)			# leaf[2][0] = 3
	li	t0, 4
	sw	t0, 96(sp)			# leaf[3][0] = 4
	# Build tree
	mv	a0, sp				# leaves
	li	a1, 4				# num_leaves
	addi	a2, sp, 128			# tree (after leaves)
	jal	merkle_build
	# a0 = root ptr, check non-zero
	lw	t0, 0(a0)
	beqz	t0, test_fail
	PASS_TEST

	RUN_TEST tn_mk_prove
	# Prove leaf 2 and verify
	addi	a0, sp, 128			# tree
	li	a1, 4				# num_leaves
	li	a2, 2				# leaf_index
	# proof needs depth=2 siblings × 32 bytes = 64 bytes
	addi	sp, sp, -64
	mv	a3, sp				# proof
	jal	merkle_prove
	li	t0, 2				# expect depth 2
	bne	a0, t0, test_fail
	PASS_TEST

	RUN_TEST tn_mk_verify
	# Verify the proof we just generated
	# root is at tree + 32
	addi	a0, sp, 64 + 128 + 32		# root = tree_base + 32
	addi	a1, sp, 64 + 64			# leaf[2] = leaves + 2*32
	li	a2, 2				# leaf_index
	mv	a3, sp				# proof
	addi	sp, sp, -4
	li	t0, 2
	sw	t0, 0(sp)			# depth = 2
	jal	merkle_verify
	addi	sp, sp, 4
	bnez	a0, test_fail			# should return 0 (valid)
	PASS_TEST

	RUN_TEST tn_mk_tamper
	# Tamper with the leaf and verify fails
	addi	t0, sp, 64 + 64		# leaf[2]
	lw	t1, 0(t0)
	xori	t1, t1, 1			# flip bit
	sw	t1, 0(t0)
	addi	a0, sp, 64 + 128 + 32		# root
	addi	a1, sp, 64 + 64			# tampered leaf
	li	a2, 2
	mv	a3, sp				# proof
	addi	sp, sp, -4
	li	t0, 2
	sw	t0, 0(sp)
	jal	merkle_verify
	addi	sp, sp, 4
	beqz	a0, test_fail			# should return -1 (invalid)
	# Restore leaf
	addi	t0, sp, 64 + 64
	lw	t1, 0(t0)
	xori	t1, t1, 1
	sw	t1, 0(t0)
	addi	sp, sp, 64 + 384		# cleanup all merkle allocations
	PASS_TEST

	# ══════════════════════════════════════════════════
	# Fiat-Shamir transcript
	# ══════════════════════════════════════════════════

	RUN_TEST tn_ts_basic
	# Init, absorb, squeeze → non-zero challenge
	addi	sp, sp, -TS_SIZE
	mv	a0, sp
	jal	transcript_init
	mv	a0, sp
	li	a1, 42
	jal	transcript_absorb
	mv	a0, sp
	jal	transcript_squeeze
	beqz	a0, test_fail			# challenge should be non-zero
	addi	sp, sp, TS_SIZE
	PASS_TEST

	RUN_TEST tn_ts_determ
	# Same absorptions → same challenge (deterministic)
	addi	sp, sp, -(TS_SIZE * 2)
	# First transcript
	mv	a0, sp
	jal	transcript_init
	mv	a0, sp
	li	a1, 100
	jal	transcript_absorb
	mv	a0, sp
	li	a1, 200
	jal	transcript_absorb
	mv	a0, sp
	jal	transcript_squeeze
	mv	s0, a0				# save challenge 1
	# Second transcript
	addi	a0, sp, TS_SIZE
	jal	transcript_init
	addi	a0, sp, TS_SIZE
	li	a1, 100
	jal	transcript_absorb
	addi	a0, sp, TS_SIZE
	li	a1, 200
	jal	transcript_absorb
	addi	a0, sp, TS_SIZE
	jal	transcript_squeeze
	bne	a0, s0, test_fail		# must match
	addi	sp, sp, TS_SIZE * 2
	PASS_TEST

	RUN_TEST tn_ts_diff
	# Different absorptions → different challenges
	addi	sp, sp, -(TS_SIZE * 2)
	# First: absorb 1
	mv	a0, sp
	jal	transcript_init
	mv	a0, sp
	li	a1, 1
	jal	transcript_absorb
	mv	a0, sp
	jal	transcript_squeeze
	mv	s0, a0
	# Second: absorb 2
	addi	a0, sp, TS_SIZE
	jal	transcript_init
	addi	a0, sp, TS_SIZE
	li	a1, 2
	jal	transcript_absorb
	addi	a0, sp, TS_SIZE
	jal	transcript_squeeze
	beq	a0, s0, test_fail		# must differ
	addi	sp, sp, TS_SIZE * 2
	PASS_TEST

	RUN_TEST tn_ts_multi
	# Multiple squeezes give different values
	addi	sp, sp, -TS_SIZE
	mv	a0, sp
	jal	transcript_init
	mv	a0, sp
	li	a1, 42
	jal	transcript_absorb
	mv	a0, sp
	jal	transcript_squeeze
	mv	s0, a0				# first challenge
	mv	a0, sp
	jal	transcript_squeeze
	beq	a0, s0, test_fail		# second must differ
	addi	sp, sp, TS_SIZE
	PASS_TEST

	# ══════════════════════════════════════════════════
	# FRI
	# ══════════════════════════════════════════════════

	RUN_TEST tn_fp_pow
	# 31^10 mod p = 0x5cde7c78
	li	a0, 31
	li	a1, 10
	jal	fp_pow
	li	t0, 0x5cde7c78
	bne	a0, t0, test_fail
	PASS_TEST

	RUN_TEST tn_fri_domgen
	# Generator of order 2^10 = 0x145e952d
	li	a0, 10
	jal	fri_domain_gen
	li	t0, 0x145e952d
	bne	a0, t0, test_fail
	PASS_TEST

	RUN_TEST tn_fri_evalpt
	# eval_point(gen10, 3, 7) = 0x736c98ee
	li	a0, 0x145e952d			# gen10
	li	a1, 3				# index
	li	a2, 7				# offset
	jal	fri_eval_point
	li	t0, 0x736c98ee
	bne	a0, t0, test_fail
	PASS_TEST

	RUN_TEST tn_fri_fold1
	# fri_fold(6, 2, 0, 1) = 4 (alpha=0 → just even part)
	li	a0, 6
	li	a1, 2
	li	a2, 0				# alpha = 0
	li	a3, 1				# x = 1
	jal	fri_fold
	li	t0, 4
	bne	a0, t0, test_fail
	PASS_TEST

	RUN_TEST tn_fri_fold2
	# fri_fold(10, 20, 3, 5) = 12
	li	a0, 10
	li	a1, 20
	li	a2, 3				# alpha
	li	a3, 5				# x
	jal	fri_fold
	li	t0, 12
	bne	a0, t0, test_fail
	PASS_TEST

	# ══════════════════════════════════════════════════
	# AIR constraints
	# ══════════════════════════════════════════════════

	RUN_TEST tn_air_add_ok
	# 5 + 7 = 12 → constraint = 0
	li	a0, 5
	li	a1, 7
	li	a2, 12
	jal	air_eval_add
	bnez	a0, test_fail
	PASS_TEST

	RUN_TEST tn_air_add_bad
	# 5 + 7 ≠ 15 → constraint = 3
	li	a0, 5
	li	a1, 7
	li	a2, 15
	jal	air_eval_add
	li	t0, 3
	bne	a0, t0, test_fail
	PASS_TEST

	RUN_TEST tn_air_vanish
	# Z(3, log=3, offset=1) = 3^8 - 1 = 6560
	li	a0, 3
	li	a1, 3
	li	a2, 1
	jal	air_eval_vanishing
	li	t0, 6560
	bne	a0, t0, test_fail
	# Z(5, log=2, offset=2) = 5^4 - 2^4 = 609
	li	a0, 5
	li	a1, 2
	li	a2, 2
	jal	air_eval_vanishing
	li	t0, 609
	bne	a0, t0, test_fail
	PASS_TEST

	RUN_TEST tn_air_quot
	# 10 == 2 * 5 → valid
	li	a0, 10
	li	a1, 5
	li	a2, 2
	jal	air_check_quotient
	bnez	a0, test_fail
	# 10 != 3 * 5 → invalid
	li	a0, 10
	li	a1, 5
	li	a2, 3
	jal	air_check_quotient
	li	t0, -1
	bne	a0, t0, test_fail
	PASS_TEST

	RUN_TEST tn_air_combine
	# combine([3, 7, 11], 3, 2) = 3 + 2*7 + 4*11 = 61
	addi	sp, sp, -12
	li	t0, 3
	sw	t0, 0(sp)
	li	t0, 7
	sw	t0, 4(sp)
	li	t0, 11
	sw	t0, 8(sp)
	mv	a0, sp
	li	a1, 3
	li	a2, 2
	jal	air_combine
	addi	sp, sp, 12
	li	t0, 61
	bne	a0, t0, test_fail
	PASS_TEST

	# ══════════════════════════════════════════════════
	# STARK verifier
	# ══════════════════════════════════════════════════

	RUN_TEST tn_stark_verify
	# Verify the proof generated by tools/stark_prover.py
	LOAD_ADDRESS	a0, _test_stark_proof
	jal	stark_verify
	bnez	a0, test_fail
	PASS_TEST

	# ══════════════════════════════════════════════════
	# PoW (requires disk for 16MB table cache)
	# ══════════════════════════════════════════════════

	# s8 = disk avail_idx counter
	li	s8, 0

	# Check if table is cached on disk
	li	a0, 0
	addi	s8, s8, 1
	mv	a1, s8
	jal	disk_read
	li	t0, DISK_DATA_BUFFER
	add	t0, gp, t0
	lw	t0, 0(t0)
	li	t1, POW_DISK_MAGIC
	beq	t0, t1, _pow_load

	# ── Generate table ──
	LOAD_ADDRESS	a0, _lbl_pow_gen
	jal	print_str

	LOAD_ADDRESS	s0, tv_pow_bible
	LOAD_ADDRESS	s1, tv_pow_bible_end
	sub	s1, s1, s0
	li	s2, POW_TABLE_ADDR

	# Copy compressed data
	mv	t0, s0
	mv	t1, s2
	srli	t2, s1, 2
_pow_copy:
	beqz	t2, _pow_copy_done
	lw	t3, 0(t0)
	sw	t3, 0(t1)
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	j	_pow_copy
_pow_copy_done:
	andi	t2, s1, 3
_pow_copy_tail:
	beqz	t2, _pow_copy_all
	lbu	t3, 0(t0)
	sb	t3, 0(t1)
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	_pow_copy_tail
_pow_copy_all:
	andi	t0, s1, 31
	beqz	t0, _pow_aligned
	li	t1, 32
	sub	t0, t1, t0
	add	t1, s2, s1
_pow_pad:
	beqz	t0, _pow_aligned
	sb	zero, 0(t1)
	addi	t1, t1, 1
	addi	t0, t0, -1
	j	_pow_pad
_pow_aligned:
	# blake2s chain
	addi	s3, s1, 31
	li	t0, -32
	and	s3, s3, t0
	li	s4, POW_TABLE_SIZE
	addi	sp, sp, -32
	mv	s5, sp
	li	s6, 0
_pow_gen_loop:
	bgeu	s3, s4, _pow_gen_done
	andi	t0, s6, 0x7FF
	bnez	t0, _pow_gen_no_dot
	li	a0, '.'
	jal	write_byte
_pow_gen_no_dot:
	addi	a0, s3, -32
	add	a0, s2, a0
	li	s8, POW_BLAKE2S_ITERS
_pow_gen_iter:
	beqz	s8, _pow_gen_iter_done
	li	a1, 32
	mv	a2, s5
	jal	blake2s
	mv	a0, s5
	addi	s8, s8, -1
	j	_pow_gen_iter
_pow_gen_iter_done:
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
	j	_pow_gen_loop
_pow_gen_done:
	addi	sp, sp, 32
	li	a0, '\n'
	jal	write_byte

	# Write magic + table to disk
	li	s8, 1
	li	t0, DISK_DATA_BUFFER
	add	t0, gp, t0
	li	t1, POW_DISK_MAGIC
	sw	t1, 0(t0)
	li	a0, 0
	addi	s8, s8, 1
	mv	a1, s8
	jal	disk_write
	li	s0, 0
	li	s1, 1
	li	s2, POW_TABLE_SIZE
_pow_write:
	bgeu	s0, s2, _pow_write_done
	li	t0, DISK_DATA_BUFFER
	add	t0, gp, t0
	li	t1, POW_TABLE_ADDR
	add	t1, t1, s0
	li	t2, 128
_pow_wcopy:
	lw	t3, 0(t1)
	sw	t3, 0(t0)
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	bnez	t2, _pow_wcopy
	mv	a0, s1
	addi	s8, s8, 1
	mv	a1, s8
	jal	disk_write
	addi	s0, s0, 512
	addi	s1, s1, 1
	andi	t0, s1, 0x3FF
	bnez	t0, _pow_write
	li	a0, '.'
	jal	write_byte
	j	_pow_write
_pow_write_done:
	LOAD_ADDRESS	a0, _lbl_pow_saved
	jal	print_str
	# Fall through to load — verifies load path even on first run

_pow_load:
	LOAD_ADDRESS	a0, _lbl_pow_load
	jal	print_str
	li	s0, 0
	li	s1, 1
	li	s2, POW_TABLE_SIZE
_pow_read:
	bgeu	s0, s2, _pow_read_done
	mv	a0, s1
	addi	s8, s8, 1
	mv	a1, s8
	jal	disk_read
	li	t0, DISK_DATA_BUFFER
	add	t0, gp, t0
	li	t1, POW_TABLE_ADDR
	add	t1, t1, s0
	li	t2, 128
_pow_rcopy:
	lw	t3, 0(t0)
	sw	t3, 0(t1)
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	bnez	t2, _pow_rcopy
	addi	s0, s0, 512
	addi	s1, s1, 1
	j	_pow_read
_pow_read_done:
	LOAD_ADDRESS	a0, _lbl_pow_loaded
	jal	print_str

_pow_tests:
	# Test bible_expand library function with 2MB table (exercises blake2s chain)
	RUN_TEST tn_pow_expand
	LOAD_ADDRESS	a0, tv_pow_bible
	LOAD_ADDRESS	a1, tv_pow_bible_end
	sub	a1, a1, a0
	li	a2, POW_TABLE_ADDR		# reuse table buffer
	li	a3, 0x200000			# 2MB
	jal	bible_expand
	bltz	a0, test_fail
	PASS_TEST

	RUN_TEST tn_pow_hash
	li	a0, POW_TABLE_ADDR
	li	a1, POW_TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	addi	sp, sp, -32
	mv	a3, sp
	jal	pow_hash_full
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

	RUN_TEST tn_pow_determ
	addi	sp, sp, -64
	li	a0, POW_TABLE_ADDR
	li	a1, POW_TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	mv	a3, sp
	jal	pow_hash_full
	li	a0, POW_TABLE_ADDR
	li	a1, POW_TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	addi	a3, sp, 32
	jal	pow_hash_full
	li	t2, 8
	mv	t0, sp
	addi	t1, sp, 32
_pow_det_cmp:
	beqz	t2, _pow_det_ok
	lw	t3, 0(t0)
	lw	t4, 0(t1)
	bne	t3, t4, test_fail
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	j	_pow_det_cmp
_pow_det_ok:
	addi	sp, sp, 64
	PASS_TEST

	RUN_TEST tn_pow_diff
	addi	sp, sp, -64
	li	a0, POW_TABLE_ADDR
	li	a1, POW_TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	mv	a3, sp
	jal	pow_hash_full
	LOAD_ADDRESS	t0, _test_header
	li	t1, 1
	sw	t1, POW_NONCE_OFFSET(t0)
	li	a0, POW_TABLE_ADDR
	li	a1, POW_TABLE_MASK
	mv	a2, t0
	addi	a3, sp, 32
	jal	pow_hash_full
	LOAD_ADDRESS	t0, _test_header
	sw	zero, POW_NONCE_OFFSET(t0)
	li	t2, 8
	mv	t0, sp
	addi	t1, sp, 32
	li	t5, 0
_pow_diff_cmp:
	beqz	t2, _pow_diff_check
	lw	t3, 0(t0)
	lw	t4, 0(t1)
	beq	t3, t4, _pow_diff_next
	addi	t5, t5, 1
_pow_diff_next:
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	j	_pow_diff_cmp
_pow_diff_check:
	beqz	t5, test_fail
	addi	sp, sp, 64
	PASS_TEST

	RUN_TEST tn_pow_mine_easy
	addi	sp, sp, -32
	mv	t0, sp
	addi	sp, sp, -8
	sw	t0, 0(sp)
	li	t0, 100
	sw	t0, 4(sp)
	li	a0, POW_TABLE_ADDR
	li	a1, POW_TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	LOAD_ADDRESS	a3, _target_easy
	jal	mine_block
	addi	sp, sp, 40
	bltz	a0, test_fail
	PASS_TEST

	RUN_TEST tn_pow_mine_fail
	addi	sp, sp, -32
	mv	t0, sp
	addi	sp, sp, -8
	sw	t0, 0(sp)
	li	t0, 10
	sw	t0, 4(sp)
	li	a0, POW_TABLE_ADDR
	li	a1, POW_TABLE_MASK
	LOAD_ADDRESS	a2, _test_header
	LOAD_ADDRESS	a3, _target_impossible
	jal	mine_block
	addi	sp, sp, 40
	li	t0, -1
	bne	a0, t0, test_fail
	PASS_TEST

	# ══════════════════════════════════════════════════
	# NTT tests
	# ══════════════════════════════════════════════════

	RUN_TEST tn_ntt_identity
	# NTT([1,0,0,0]) with omega_4 should give [1,1,1,1]
	addi	sp, sp, -16
	li	t0, 1
	sw	t0, 0(sp)
	sw	zero, 4(sp)
	sw	zero, 8(sp)
	sw	zero, 12(sp)
	mv	a0, sp
	li	a1, 4
	li	a2, 0x67055c21			# omega_4
	jal	ntt_forward
	lw	t0, 0(sp)
	li	t1, 1
	bne	t0, t1, test_fail
	lw	t0, 4(sp)
	bne	t0, t1, test_fail
	lw	t0, 8(sp)
	bne	t0, t1, test_fail
	lw	t0, 12(sp)
	bne	t0, t1, test_fail
	addi	sp, sp, 16
	PASS_TEST

	RUN_TEST tn_ntt_fwd4
	# NTT([1,2,3,4]) with omega_4
	addi	sp, sp, -16
	li	t0, 1
	sw	t0, 0(sp)
	li	t0, 2
	sw	t0, 4(sp)
	li	t0, 3
	sw	t0, 8(sp)
	li	t0, 4
	sw	t0, 12(sp)
	mv	a0, sp
	li	a1, 4
	li	a2, 0x67055c21			# omega_4
	jal	ntt_forward
	lw	t0, 0(sp)
	li	t1, 10
	bne	t0, t1, test_fail
	lw	t0, 4(sp)
	li	t1, 0x21f547be
	bne	t0, t1, test_fail
	lw	t0, 8(sp)
	li	t1, 0x77ffffff
	bne	t0, t1, test_fail
	lw	t0, 12(sp)
	li	t1, 0x560ab83f
	bne	t0, t1, test_fail
	addi	sp, sp, 16
	PASS_TEST

	RUN_TEST tn_ntt_rt4
	# Round-trip: INTT(NTT([1,2,3,4])) == [1,2,3,4]
	addi	sp, sp, -16
	li	t0, 1
	sw	t0, 0(sp)
	li	t0, 2
	sw	t0, 4(sp)
	li	t0, 3
	sw	t0, 8(sp)
	li	t0, 4
	sw	t0, 12(sp)
	mv	a0, sp
	li	a1, 4
	li	a2, 0x67055c21			# omega_4
	jal	ntt_forward
	mv	a0, sp
	li	a1, 4
	li	a2, 0x67055c21
	jal	ntt_inverse
	lw	t0, 0(sp)
	li	t1, 1
	bne	t0, t1, test_fail
	lw	t0, 4(sp)
	li	t1, 2
	bne	t0, t1, test_fail
	lw	t0, 8(sp)
	li	t1, 3
	bne	t0, t1, test_fail
	lw	t0, 12(sp)
	li	t1, 4
	bne	t0, t1, test_fail
	addi	sp, sp, 16
	PASS_TEST

	RUN_TEST tn_ntt_rt8
	# Round-trip size 8: INTT(NTT([1..8])) == [1..8]
	addi	sp, sp, -32
	li	t0, 1
	sw	t0, 0(sp)
	li	t0, 2
	sw	t0, 4(sp)
	li	t0, 3
	sw	t0, 8(sp)
	li	t0, 4
	sw	t0, 12(sp)
	li	t0, 5
	sw	t0, 16(sp)
	li	t0, 6
	sw	t0, 20(sp)
	li	t0, 7
	sw	t0, 24(sp)
	li	t0, 8
	sw	t0, 28(sp)
	mv	a0, sp
	li	a1, 8
	li	a2, 0x5ee99486			# omega_8
	jal	ntt_forward
	mv	a0, sp
	li	a1, 8
	li	a2, 0x5ee99486
	jal	ntt_inverse
	li	t1, 1
	lw	t0, 0(sp)
	bne	t0, t1, test_fail
	li	t1, 2
	lw	t0, 4(sp)
	bne	t0, t1, test_fail
	li	t1, 3
	lw	t0, 8(sp)
	bne	t0, t1, test_fail
	li	t1, 4
	lw	t0, 12(sp)
	bne	t0, t1, test_fail
	li	t1, 5
	lw	t0, 16(sp)
	bne	t0, t1, test_fail
	li	t1, 6
	lw	t0, 20(sp)
	bne	t0, t1, test_fail
	li	t1, 7
	lw	t0, 24(sp)
	bne	t0, t1, test_fail
	li	t1, 8
	lw	t0, 28(sp)
	bne	t0, t1, test_fail
	addi	sp, sp, 32
	PASS_TEST

	# ══════════════════════════════════════════════════
	# All passed
	# ══════════════════════════════════════════════════
	li		t0, EXIT_ADDR
	li		t1, EXIT_PASS
	sw		t1, 0(t0)
1:	wfi
	j		1b

test_fail:
	LOAD_ADDRESS	a0, _str_fail
	jal		print_str
1:	wfi
	j		1b


# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

# check_roundtrip: compress a0/a1, decompress, verify match
# a0 = input ptr, a1 = input len. Jumps to test_fail on error.
check_roundtrip:
	SETUP	s0, s1, s2
	mv	s0, a0				# input
	mv	s1, a1				# len

	# compress
	li	t0, 0x10000
	add	a2, gp, t0			# output
	li	t0, 0x20000
	add	a3, gp, t0			# match_array
	jal	compress_block
	blez	a0, test_fail
	mv	s2, a0				# compressed size

	# decompress
	li	t0, 0x10000
	add	a0, gp, t0
	mv	a1, s2
	li	t0, 0x30000
	add	a2, gp, t0
	li	a3, 0x10000			# 64K capacity
	jal	decompress_block
	bne	a0, s1, test_fail		# size mismatch

	# byte compare
	mv	t0, s0				# original
	li	t1, 0x30000
	add	t1, gp, t1			# decompressed
	mv	t2, s1
1:	beqz	t2, 2f
	lbu	t3, 0(t0)
	lbu	t4, 0(t1)
	bne	t3, t4, test_fail
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	1b
2:	RETURN

# check_tamper: flip bit 0 of each byte in a0[0..a1-1], verify wots_verify rejects
# a0 = target buffer to tamper, a1 = byte count
# Uses PK_OFF/SIG_OFF/MSG_OFF from gp for verify calls.
check_tamper:
	SETUP	s0, s1, s2
	mv	s0, a0				# target ptr
	mv	s1, a1				# byte count
	li	s2, 0				# byte index
1:	bge	s2, s1, 2f
	# flip bit 0
	add	t0, s0, s2
	lbu	t1, 0(t0)
	xori	t1, t1, 1
	sb	t1, 0(t0)
	# verify must reject
	li	t0, PK_OFF
	add	a0, gp, t0
	li	t0, SIG_OFF
	add	a1, gp, t0
	li	t0, MSG_OFF
	add	a2, gp, t0
	jal	wots_verify
	beqz	a0, test_fail
	# restore
	add	t0, s0, s2
	lbu	t1, 0(t0)
	xori	t1, t1, 1
	sb	t1, 0(t0)
	addi	s2, s2, 1
	j	1b
2:	RETURN

# check_hash_32: compare 32 bytes at a0 against expected at t0
check_hash_32:
	SETUP	s0, s1
	mv	s0, a0
	mv	s1, t0
	li	t2, 8
1:	lw	t3, 0(s0)
	lw	t4, 0(s1)
	bne	t3, t4, test_fail
	addi	s0, s0, 4
	addi	s1, s1, 4
	addi	t2, t2, -1
	bnez	t2, 1b
	RETURN

# print_str: print null-terminated string at a0
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


# ──────────────────────────────────────────────────────────────────────────────
disk_read:
	li	t5, VIRT_DESCRIPTOR_TABLE
	add	t1, gp, t5
	li	t3, VIRT_DISK_STATUS
	add	t3, gp, t3
	addi	t2, t3, 2
	sw	zero, 0(t2)
	sw	a0, 8(t2)
	sw	t2, 0(t1)
	sw	zero, 4(t1)
	li	t4, 16
	sw	t4, 8(t1)
	li	t4, 1
	sh	t4, 12(t1)
	sh	t4, 14(t1)
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
	sw	t3, 32(t1)
	sw	zero, 36(t1)
	li	t4, 1
	sw	t4, 40(t1)
	li	t4, 2
	sh	t4, 44(t1)
	sh	zero, 46(t1)
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

disk_write:
	li	t5, VIRT_DESCRIPTOR_TABLE
	add	t1, gp, t5
	li	t3, VIRT_DISK_STATUS
	add	t3, gp, t3
	addi	t2, t3, 2
	li	t4, 1
	sw	t4, 0(t2)
	sw	a0, 8(t2)
	sw	t2, 0(t1)
	sw	zero, 4(t1)
	li	t4, 16
	sw	t4, 8(t1)
	li	t4, 1
	sh	t4, 12(t1)
	sh	t4, 14(t1)
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
	sw	t3, 32(t1)
	sw	zero, 36(t1)
	li	t4, 1
	sw	t4, 40(t1)
	li	t4, 2
	sh	t4, 44(t1)
	sh	zero, 46(t1)
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


.include "lib_defines.inc"


# ══════════════════════════════════════════════════════════════════════════════
# String constants and test vectors
# ══════════════════════════════════════════════════════════════════════════════
	.balign 4

_str_pass:
	.asciz	"PASS\n"
_str_fail:
	.asciz	"FAIL\n"

# ── test names ──

tn_b2s_empty:	.asciz	"blake2s empty       "
tn_b2s_abc:	.asciz	"blake2s abc         "
tn_b2s_64:	.asciz	"blake2s 64 bytes    "
tn_b2s_65:	.asciz	"blake2s 65 bytes    "
tn_b2s_opt:	.asciz	"blake2s_64          "
tn_wots_hash:	.asciz	"wots msg hash       "
tn_wots_keygen:	.asciz	"wots keygen         "
tn_wots_sign:	.asciz	"wots sign           "
tn_wots_verify:	.asciz	"wots verify         "
tn_wots_tmsg:	.asciz	"wots tampered msg   "
tn_wots_tsig:	.asciz	"wots tampered sig   "
tn_wots_tpk:	.asciz	"wots tampered pk    "
tn_cz_rt:	.asciz	"compress round-trip "
tn_cz_short:	.asciz	"compress short      "
tn_cz_large:	.asciz	"compress with match "
tn_cz_mozilla:	.asciz	"compress mozilla     "
tn_cz_bible:	.asciz	"compress bible 4MB  "
tn_cz_corrupt:	.asciz	"decompress corrupt  "
tn_cz_fuzz:	.asciz	"decompress fuzz     "
tn_cz_trunc:	.asciz	"decompress truncate "
tn_cz_edge:	.asciz	"decompress edge     "
tn_fp_add:	.asciz	"fp_add              "
tn_fp_sub:	.asciz	"fp_sub              "
tn_fp_mul:	.asciz	"fp_mul              "
tn_fp_inv:	.asciz	"fp_inv              "
tn_fp_pow:	.asciz	"fp_pow              "
tn_fri_domgen:	.asciz	"fri domain gen      "
tn_fri_evalpt:	.asciz	"fri eval point      "
tn_stark_verify:	.asciz	"stark verify proof  "
tn_air_add_ok:	.asciz	"air add (valid)     "
tn_air_add_bad:	.asciz	"air add (invalid)   "
tn_air_vanish:	.asciz	"air vanishing poly  "
tn_air_quot:	.asciz	"air quotient check  "
tn_air_combine:	.asciz	"air combine (Horner)"
tn_fri_fold1:	.asciz	"fri fold (alpha=0)  "
tn_fri_fold2:	.asciz	"fri fold (alpha=3)  "
tn_ts_basic:	.asciz	"transcript basic    "
tn_ts_determ:	.asciz	"transcript determ   "
tn_ts_diff:	.asciz	"transcript diff     "
tn_ts_multi:	.asciz	"transcript multi sq "
tn_mk_build:	.asciz	"merkle build        "
tn_mk_prove:	.asciz	"merkle prove        "
tn_mk_verify:	.asciz	"merkle verify       "
tn_mk_tamper:	.asciz	"merkle tamper reject"
tn_p2_perm:	.asciz	"poseidon2 perm      "
tn_p2_determ:	.asciz	"poseidon2 determinism"
tn_p2_hash:	.asciz	"poseidon2 hash      "
tn_pow_expand:	.asciz	"bible_expand        "
tn_pow_hash:	.asciz	"pow_hash non-zero   "
tn_pow_determ:	.asciz	"pow_hash determinism"
tn_pow_diff:	.asciz	"pow_hash nonce diff "
tn_pow_mine_easy:	.asciz	"mine_block easy     "
tn_pow_mine_fail:	.asciz	"mine_block fail     "
tn_ntt_identity:	.asciz	"ntt identity        "
tn_ntt_fwd4:		.asciz	"ntt forward len=4   "
tn_ntt_rt4:		.asciz	"ntt round-trip 4    "
tn_ntt_rt8:		.asciz	"ntt round-trip 8    "

# ── blake2s vectors ──

tv_b2s_empty:
	.byte	0
tv_b2s_empty_hash:
	.word	0x307A2169, 0x94809079, 0xD02111E1, 0x7C4A3542
	.word	0x48B6551F, 0x1EA5A12C, 0xFD0D251B, 0xF9EED01E

tv_b2s_abc:
	.ascii	"abc"
	.balign 4
tv_b2s_abc_hash:
	.word	0x8C5E8C50, 0xE2147C32, 0xA32BA7E1, 0x2F45EB4E
	.word	0x208B4537, 0x293AD69E, 0x4C9B994D, 0x82596786

tv_b2s_64:
	.byte  0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15
	.byte 16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
	.byte 32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
	.byte 48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63
tv_b2s_64_hash:
	.word	0x8B4EF356, 0x907E5596, 0x524BF2C1, 0x519DC8D0
	.word	0x1BCF6A08, 0xCF34F600, 0x3392DE1D, 0x3EAAEAB8

tv_b2s_65:
	.byte  0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15
	.byte 16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
	.byte 32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
	.byte 48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63
	.byte 64
	.balign 4
tv_b2s_65_hash:
	.word	0x94EE531B, 0x4B4EF3AA, 0xDE489D15, 0x067F2C35
	.word	0x0EA4D061, 0x0B5AF9DF, 0x09B43916, 0x7244970E

# ── WOTS+ vectors ──

tv_wots_msg_text:
	.ascii	"test message for wots"
	.balign 4
tv_wots_msg_hash:
	.word	0x124F6752, 0xCE245256, 0xF7351839, 0xE575CED0
	.word	0x5FD2F416, 0x266C31B0, 0xB1FA94D6, 0xDE134521
tv_wots_sk0:
	.word	0xA140DE27, 0x4B1070DA, 0xCEB4C263, 0x74D48709
	.word	0xB0ADA4FB, 0x3CC780CA, 0x42923694, 0x116E997A

# ── compress vectors ──

tv_cz_repeat:
	.ascii	"ABCABCABCABCABCABCABCABC"

tv_cz_short:
	.ascii	"Hello"
	.balign 4

# 500 bytes: repeating pattern that triggers LZ77 match finding (needs > 288 bytes)
tv_cz_large:
	.ascii	"The quick brown fox jumps over the lazy dog. "
	.ascii	"The quick brown fox jumps over the lazy dog. "
	.ascii	"The quick brown fox jumps over the lazy dog. "
	.ascii	"The quick brown fox jumps over the lazy dog. "
	.ascii	"The quick brown fox jumps over the lazy dog. "
	.ascii	"The quick brown fox jumps over the lazy dog. "
	.ascii	"The quick brown fox jumps over the lazy dog. "
	.ascii	"The quick brown fox jumps over the lazy dog. "
	.ascii	"The quick brown fox jumps over the lazy dog. "
	.ascii	"The quick brown fox jumps over the lazy dog. "
	.ascii	"The quick brown fox jumps over "
tv_cz_large_end:
	.balign 4

tv_cz_mozilla:
	.incbin "resources/mozilla"
tv_cz_mozilla_end:
	.balign 4

tv_cz_bible:
	.incbin "resources/bible.txt"
tv_cz_bible_end:
	.balign 4

# ── PoW vectors ──

# ── Poseidon2 test vector (from Plonky3) ──

_p2_tv_input:
	.word	894848333, 1437655012, 1200606629, 1690012884
	.word	71131202, 1749206695, 1717947831, 120589055
	.word	19776022, 42382981, 1831865506, 724844064
	.word	171220207, 1299207443, 227047920, 1783754913

_p2_tv_output:
	.word	516096821, 90309867, 1101817252, 1660784290
	.word	360715097, 1789519026, 1788910906, 563338433
	.word	319524748, 1741414159, 1650859320, 894311162
	.word	1121347488, 1692793758, 1052633829, 1344246938

_lbl_pow_gen:	.asciz	"Generating 16MB bible table...\n"
_lbl_pow_saved:	.asciz	"Saved to disk.\n"
_lbl_pow_load:	.asciz	"Loading table from disk...\n"
_lbl_pow_loaded: .asciz	"Loaded.\n"
	.balign 4

_test_header:
	.zero	124
	.word	0				# nonce at offset 124

_target_easy:
	.word	0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
	.word	0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF

_target_impossible:
	.word	0, 0, 0, 0, 0, 0, 0, 0

# ── STARK test proof (generated by tools/stark_prover.py) ──
_test_stark_proof:
	.incbin "tmp/test_proof.bin"
	.balign 4

tv_pow_bible:
	.incbin	"resources/bible.compressed"
tv_pow_bible_end:
	.balign 4

_gp_base:
