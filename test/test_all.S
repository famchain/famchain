# test_all.S — Combined unit tests for all libraries
#
# Runs blake2s + WOTS+ + compress tests in sequence. Single binary, single coverage report.

.equ	EXIT_ADDR,	0x100000
.equ	EXIT_PASS,	0x5555
.equ	UART_BASE,	0x10000000
.equ	UART_LSR,	5
.equ	UART_WR_MASK,	0x20

.include "macros.inc"
.include "blake2s.inc"
.include "wots.inc"
.include "compress.inc"

# Memory layout in data region (from gp):
.equ	SK_OFF,		0
.equ	PK_OFF,		576
.equ	SIG_OFF,	1152
.equ	MSG_OFF,	1728
.equ	SEED_OFF,	1760

_start:
	LOAD_ADDRESS	gp, _test_data
	li		t0, 4095
	add		gp, gp, t0
	li		t0, -4096
	and		gp, gp, t0
	li		t0, 0x200000
	add		sp, gp, t0

	# ══════════════════════════════════════════════════
	# Blake2s tests
	# ══════════════════════════════════════════════════

	# Test 1: empty input
	li		a0, 'B'
	jal		write_byte
	li		a0, '1'
	jal		write_byte
	LOAD_ADDRESS	a0, tv_b2s_empty
	li		a1, 0
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv_b2s_empty_hash
	mv		a0, sp
	jal		check_hash_32
	addi		sp, sp, 32

	# Test 2: "abc"
	li		a0, 'B'
	jal		write_byte
	li		a0, '2'
	jal		write_byte
	LOAD_ADDRESS	a0, tv_b2s_abc
	li		a1, 3
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv_b2s_abc_hash
	mv		a0, sp
	jal		check_hash_32
	addi		sp, sp, 32

	# Test 3: 64 bytes (one block)
	li		a0, 'B'
	jal		write_byte
	li		a0, '3'
	jal		write_byte
	LOAD_ADDRESS	a0, tv_b2s_64
	li		a1, 64
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv_b2s_64_hash
	mv		a0, sp
	jal		check_hash_32
	addi		sp, sp, 32

	# Test 4: 65 bytes (two blocks)
	li		a0, 'B'
	jal		write_byte
	li		a0, '4'
	jal		write_byte
	LOAD_ADDRESS	a0, tv_b2s_65
	li		a1, 65
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv_b2s_65_hash
	mv		a0, sp
	jal		check_hash_32
	addi		sp, sp, 32

	# Test 5: blake2s_64 (optimized path)
	li		a0, 'B'
	jal		write_byte
	li		a0, '5'
	jal		write_byte
	LOAD_ADDRESS	a0, tv_b2s_64
	addi		sp, sp, -32
	mv		a1, sp
	jal		blake2s_64
	LOAD_ADDRESS	t0, tv_b2s_64_hash
	mv		a0, sp
	jal		check_hash_32
	addi		sp, sp, 32

	li		a0, '\n'
	jal		write_byte

	# ══════════════════════════════════════════════════
	# WOTS+ tests
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

	# Compute message hash
	li		a0, 'W'
	jal		write_byte
	li		a0, 'M'
	jal		write_byte
	LOAD_ADDRESS	a0, tv_wots_msg_text
	li		a1, 21
	li		t0, MSG_OFF
	add		a2, gp, t0
	jal		blake2s
	li		t0, MSG_OFF
	add		a0, gp, t0
	LOAD_ADDRESS	t0, tv_wots_msg_hash
	jal		check_hash_32

	# Keygen
	li		a0, 'K'
	jal		write_byte
	li		t0, SEED_OFF
	add		a0, gp, t0
	li		t0, PK_OFF
	add		a1, gp, t0
	li		t0, SK_OFF
	add		a2, gp, t0
	jal		wots_keyfrom
	# spot-check sk[0]
	mv		a0, gp
	LOAD_ADDRESS	t0, tv_wots_sk0
	jal		check_hash_32

	# Sign
	li		a0, 'S'
	jal		write_byte
	li		t0, SK_OFF
	add		a0, gp, t0
	li		t0, MSG_OFF
	add		a1, gp, t0
	li		t0, SIG_OFF
	add		a2, gp, t0
	jal		wots_sign

	li		a0, '.'
	jal		write_byte

	# Verify
	li		a0, 'V'
	jal		write_byte
	li		t0, PK_OFF
	add		a0, gp, t0
	li		t0, SIG_OFF
	add		a1, gp, t0
	li		t0, MSG_OFF
	add		a2, gp, t0
	jal		wots_verify
	bnez		a0, test_fail
	li		a0, '.'
	jal		write_byte

	# Negative test 1: tampered message should fail verification
	li		a0, 'N'
	jal		write_byte
	li		a0, '1'
	jal		write_byte
	# flip a bit in the message
	li		t0, MSG_OFF
	add		t0, gp, t0
	lbu		t1, 0(t0)
	xori		t1, t1, 1		# flip bit 0 of first byte
	sb		t1, 0(t0)
	# verify should return -1
	li		t0, PK_OFF
	add		a0, gp, t0
	li		t0, SIG_OFF
	add		a1, gp, t0
	li		t0, MSG_OFF
	add		a2, gp, t0
	jal		wots_verify
	beqz		a0, test_fail		# should NOT pass
	li		a0, '.'
	jal		write_byte
	# restore message
	li		t0, MSG_OFF
	add		t0, gp, t0
	lbu		t1, 0(t0)
	xori		t1, t1, 1
	sb		t1, 0(t0)

	# Negative test 2: tampered signature should fail verification
	li		a0, 'N'
	jal		write_byte
	li		a0, '2'
	jal		write_byte
	# flip a bit in the signature
	li		t0, SIG_OFF
	add		t0, gp, t0
	lbu		t1, 0(t0)
	xori		t1, t1, 1
	sb		t1, 0(t0)
	# verify should return -1
	li		t0, PK_OFF
	add		a0, gp, t0
	li		t0, SIG_OFF
	add		a1, gp, t0
	li		t0, MSG_OFF
	add		a2, gp, t0
	jal		wots_verify
	beqz		a0, test_fail		# should NOT pass
	li		a0, '.'
	jal		write_byte
	# restore signature
	li		t0, SIG_OFF
	add		t0, gp, t0
	lbu		t1, 0(t0)
	xori		t1, t1, 1
	sb		t1, 0(t0)

	# Negative test 3: tampered public key should fail verification
	li		a0, 'N'
	jal		write_byte
	li		a0, '3'
	jal		write_byte
	# flip a bit in pk
	li		t0, PK_OFF
	add		t0, gp, t0
	lbu		t1, 0(t0)
	xori		t1, t1, 1
	sb		t1, 0(t0)
	# verify should return -1
	li		t0, PK_OFF
	add		a0, gp, t0
	li		t0, SIG_OFF
	add		a1, gp, t0
	li		t0, MSG_OFF
	add		a2, gp, t0
	jal		wots_verify
	beqz		a0, test_fail		# should NOT pass
	li		a0, '.'
	jal		write_byte

	li		a0, '\n'
	jal		write_byte

	# ══════════════════════════════════════════════════
	# Compression tests
	# ══════════════════════════════════════════════════

	# Test C1: round-trip with repeating pattern
	li	a0, 'C'
	jal	write_byte
	li	a0, '1'
	jal	write_byte

	LOAD_ADDRESS	a0, tv_cz_repeat
	li	a1, 24
	# output at gp + 0x10000, match_array at gp + 0x20000
	li	t0, 0x10000
	add	a2, gp, t0
	li	t0, 0x20000
	add	a3, gp, t0
	jal	compress_block
	blez	a0, test_fail
	mv	s0, a0

	li	t0, 0x10000
	add	a0, gp, t0
	mv	a1, s0
	li	t0, 0x30000
	add	a2, gp, t0
	li	a3, 256
	jal	decompress_block
	li	t0, 24
	bne	a0, t0, test_fail

	LOAD_ADDRESS	t0, tv_cz_repeat
	mv	t3, gp
	li	t4, 0x30000
	add	t1, t3, t4
	li	t2, 24
_cz_cmp1:
	beqz	t2, _cz_cmp1_ok
	lbu	t3, 0(t0)
	lbu	t4, 0(t1)
	bne	t3, t4, test_fail
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	_cz_cmp1
_cz_cmp1_ok:
	li	a0, '.'
	jal	write_byte

	# Test C2: round-trip with short all-literal input
	li	a0, 'C'
	jal	write_byte
	li	a0, '2'
	jal	write_byte

	LOAD_ADDRESS	a0, tv_cz_short
	li	a1, 5
	li	t0, 0x10000
	add	a2, gp, t0
	li	t0, 0x20000
	add	a3, gp, t0
	jal	compress_block
	blez	a0, test_fail
	mv	s0, a0

	li	t0, 0x10000
	add	a0, gp, t0
	mv	a1, s0
	li	t0, 0x30000
	add	a2, gp, t0
	li	a3, 256
	jal	decompress_block
	li	t0, 5
	bne	a0, t0, test_fail

	LOAD_ADDRESS	t0, tv_cz_short
	mv	t3, gp
	li	t4, 0x30000
	add	t1, t3, t4
	li	t2, 5
_cz_cmp2:
	beqz	t2, _cz_cmp2_ok
	lbu	t3, 0(t0)
	lbu	t4, 0(t1)
	bne	t3, t4, test_fail
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	_cz_cmp2
_cz_cmp2_ok:
	li	a0, '.'
	jal	write_byte

	li	a0, '\n'
	jal	write_byte

	# ══════════════════════════════════════════════════
	# All passed
	# ══════════════════════════════════════════════════
	li		t0, EXIT_ADDR
	li		t1, EXIT_PASS
	sw		t1, 0(t0)
1:	wfi
	j		1b

test_fail:
	li		a0, '!'
	jal		write_byte
	li		a0, '\n'
	jal		write_byte
1:	wfi
	j		1b


# ──────────────────────────────────────────────────────────────────────────────
# check_hash_32: compare 32 bytes at a0 against expected at t0
# Prints "." on pass, "!" + halt on fail
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
	li	a0, '.'
	jal	write_byte
	RETURN


# ──────────────────────────────────────────────────────────────────────────────
write_byte:
	li	t1, UART_BASE
	lbu	t2, UART_LSR(t1)
	andi	t2, t2, UART_WR_MASK
	beqz	t2, write_byte
	sb	a0, 0(t1)
	ret


# ──────────────────────────────────────────────────────────────────────────────
DEFINE_BLAKE2S
DEFINE_WOTS
DEFINE_COMPRESS


# ══════════════════════════════════════════════════════════════════════════════
# Test vectors
# ══════════════════════════════════════════════════════════════════════════════
	.balign 4

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

_test_data:
