# test_all.S — Unit tests for all libraries

.equ	EXIT_ADDR,	0x100000
.equ	EXIT_PASS,	0x5555
.equ	UART_BASE,	0x10000000
.equ	UART_LSR,	5
.equ	UART_WR_MASK,	0x20

.include "macros.inc"
.include "blake2s.inc"
.include "wots.inc"
.include "compress.inc"

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
	LOAD_ADDRESS	gp, _test_data
	li		t0, 4095
	add		gp, gp, t0
	li		t0, -4096
	and		gp, gp, t0
	li		t0, 0x200000
	add		sp, gp, t0

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

	# TODO: add corruption + fuzz tests for decompressor
	# Blocked on remaining infinite-loop path in decompress_block with
	# malicious input. Fixed so far: zero-length lookup entries, RLE bounds
	# overflow, invalid code lengths in calculate_codes/build_lookup_table,
	# match distance > output_pos. Need to find remaining hang path.

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
DEFINE_BLAKE2S
DEFINE_WOTS
DEFINE_COMPRESS


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
tn_cz_bible:	.asciz	"compress bible 4MB  "

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

tv_cz_bible:
	.incbin "resources/bible.txt"
tv_cz_bible_end:
	.balign 4

_test_data:
