# test_blake2s.S — BLAKE2s unit tests with known vectors
#
# Tests blake2s against 4 known inputs. Uses QEMU exit device for pass/fail.
# No network or disk needed — pure compute test.

.equ	EXIT_ADDR,	0x100000
.equ	EXIT_PASS,	0x5555
.equ	UART_BASE,	0x10000000
.equ	UART_LSR,	5
.equ	UART_WR_MASK,	0x20

.include "macros.inc"
.include "blake2s.inc"

# ──────────────────────────────────────────────────────────────────────────────
_start:
	# setup gp and sp
	LOAD_ADDRESS	gp, _test_data
	li		t0, 4095
	add		gp, gp, t0
	li		t0, -4096
	and		gp, gp, t0
	li		t0, 0x100000
	add		sp, gp, t0

	# ── Test 1: empty input ──
	li		a0, 'T'
	jal		write_byte
	li		a0, '1'
	jal		write_byte

	LOAD_ADDRESS	a0, tv1_in
	li		a1, 0
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv1_hash
	jal		check_result
	addi		sp, sp, 32

	# ── Test 2: "abc" ──
	li		a0, 'T'
	jal		write_byte
	li		a0, '2'
	jal		write_byte

	LOAD_ADDRESS	a0, tv2_in
	li		a1, 3
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv2_hash
	jal		check_result
	addi		sp, sp, 32

	# ── Test 3: 64 bytes (one full block) ──
	li		a0, 'T'
	jal		write_byte
	li		a0, '3'
	jal		write_byte

	LOAD_ADDRESS	a0, tv3_in
	li		a1, 64
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv3_hash
	jal		check_result
	addi		sp, sp, 32

	# ── Test 4: 65 bytes (two blocks) ──
	li		a0, 'T'
	jal		write_byte
	li		a0, '4'
	jal		write_byte

	LOAD_ADDRESS	a0, tv4_in
	li		a1, 65
	addi		sp, sp, -32
	mv		a2, sp
	jal		blake2s
	LOAD_ADDRESS	t0, tv4_hash
	jal		check_result
	addi		sp, sp, 32

	# ── All passed ──
	li		a0, '\n'
	jal		write_byte

	# exit QEMU with success
	li		t0, EXIT_ADDR
	li		t1, EXIT_PASS
	sw		t1, 0(t0)
1:	wfi
	j		1b


# ──────────────────────────────────────────────────────────────────────────────
# check_result: compare 32-byte hash at sp against expected at t0
# Prints "." on pass, "!" on fail (and halts on fail)
check_result:
	SETUP	s0, s1
	mv	s0, sp
	addi	s0, s0, 16		# skip SETUP's frame: ra(4) + s0(4) + s1(4) + pad = 16
	mv	s1, t0
	li	t2, 8
1:	lw	t3, 0(s0)
	lw	t4, 0(s1)
	bne	t3, t4, check_fail
	addi	s0, s0, 4
	addi	s1, s1, 4
	addi	t2, t2, -1
	bnez	t2, 1b
	li	a0, '.'
	jal	write_byte
	RETURN

check_fail:
	li	a0, '!'
	jal	write_byte
	li	a0, '\n'
	jal	write_byte
1:	wfi
	j	1b


# ──────────────────────────────────────────────────────────────────────────────
write_byte:
	li	t1, UART_BASE
	lbu	t2, UART_LSR(t1)
	andi	t2, t2, UART_WR_MASK
	beqz	t2, write_byte
	sb	a0, 0(t1)
	ret


# ──────────────────────────────────────────────────────────────────────────────
# Emit blake2s functions and data
DEFINE_BLAKE2S


# ──────────────────────────────────────────────────────────────────────────────
# Test vectors (from Python hashlib blake2s, 32-byte output)
# ──────────────────────────────────────────────────────────────────────────────
	.balign 4

# Test 1: empty input → 69217a3079908094e11121d042354a7c...
tv1_in:	.byte 0
tv1_hash:
	.word 0x307A2169, 0x94809079, 0xD02111E1, 0x7C4A3542
	.word 0x48B6551F, 0x1EA5A12C, 0xFD0D251B, 0xF9EED01E

# Test 2: "abc" → 508c5e8c327c14e2e1a72ba34eeb452f...
tv2_in:	.ascii "abc"
	.balign 4
tv2_hash:
	.word 0x8C5E8C50, 0xE2147C32, 0xA32BA7E1, 0x2F45EB4E
	.word 0x208B4537, 0x293AD69E, 0x4C9B994D, 0x82596786

# Test 3: bytes 0x00..0x3f (64 bytes, one full block)
tv3_in:
	.byte  0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15
	.byte 16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
	.byte 32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
	.byte 48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63
tv3_hash:
	.word 0x8B4EF356, 0x907E5596, 0x524BF2C1, 0x519DC8D0
	.word 0x1BCF6A08, 0xCF34F600, 0x3392DE1D, 0x3EAAEAB8

# Test 4: bytes 0x00..0x40 (65 bytes, two blocks)
tv4_in:
	.byte  0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15
	.byte 16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
	.byte 32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
	.byte 48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63
	.byte 64
	.balign 4
tv4_hash:
	.word 0x94EE531B, 0x4B4EF3AA, 0xDE489D15, 0x067F2C35
	.word 0x0EA4D061, 0x0B5AF9DF, 0x09B43916, 0x7244970E

_test_data:
