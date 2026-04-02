# test_compress.S — Component tests for compression library

.equ	EXIT_ADDR,	0x100000
.equ	EXIT_PASS,	0x5555
.equ	UART_BASE,	0x10000000
.equ	UART_LSR,	5
.equ	UART_WR_MASK,	0x20

.include "macros.inc"
.include "compress.inc"

_start:
	LOAD_ADDRESS	gp, _test_data
	li		t0, 4095
	add		gp, gp, t0
	li		t0, -4096
	and		gp, gp, t0
	li		t0, 0x200000
	add		sp, gp, t0

	# ══════════════════════════════════════════════════
	# Test 1: floor_log2
	# ══════════════════════════════════════════════════
	li	a0, 'L'
	jal	write_byte

	li	t0, 1
	jal	_cz_floor_log2
	bnez	a0, test_fail

	li	t0, 2
	jal	_cz_floor_log2
	li	t1, 1
	bne	a0, t1, test_fail

	li	t0, 4
	jal	_cz_floor_log2
	li	t1, 2
	bne	a0, t1, test_fail

	li	t0, 255
	jal	_cz_floor_log2
	li	t1, 7
	bne	a0, t1, test_fail

	li	t0, 256
	jal	_cz_floor_log2
	li	t1, 8
	bne	a0, t1, test_fail

	li	a0, '.'
	jal	write_byte

	# ══════════════════════════════════════════════════
	# Test 2: Bitstream write then read
	# ══════════════════════════════════════════════════
	li	a0, 'B'
	jal	write_byte

	mv	s0, gp
	li	t0, 16
	mv	t1, s0
_t2_zero:
	sw	zero, 0(t1)
	addi	t1, t1, 4
	addi	t0, t0, -1
	bnez	t0, _t2_zero

	li	s1, 0
	li	s2, 0
	li	s3, 0

	li	a0, 5
	li	a1, 3
	jal	bs_write

	li	a0, 19
	li	a1, 5
	jal	bs_write

	li	a0, 0xAB
	li	a1, 8
	jal	bs_write

	li	a0, 0x7FF
	li	a1, 11
	jal	bs_write

	jal	bs_flush

	li	s1, 0
	li	s2, 0
	li	s3, 0

	li	a0, 3
	jal	bs_read
	li	t0, 5
	bne	a0, t0, test_fail

	li	a0, 5
	jal	bs_read
	li	t0, 19
	bne	a0, t0, test_fail

	li	a0, 8
	jal	bs_read
	li	t0, 0xAB
	bne	a0, t0, test_fail

	li	a0, 11
	jal	bs_read
	li	t0, 0x7FF
	bne	a0, t0, test_fail

	li	a0, '.'
	jal	write_byte

	# ══════════════════════════════════════════════════
	# Test 3: Huffman tree + code calculation
	# ══════════════════════════════════════════════════
	li	a0, 'H'
	jal	write_byte

	addi	sp, sp, -16
	sw	zero, 0(sp)
	sw	zero, 4(sp)
	sw	zero, 8(sp)
	sw	zero, 12(sp)

	addi	sp, sp, -16
	li	t0, 5
	sw	t0, 0(sp)
	li	t0, 3
	sw	t0, 4(sp)
	sw	zero, 8(sp)
	sw	zero, 12(sp)

	mv	a0, sp
	addi	a1, sp, 16
	li	a2, 2
	li	a3, 11
	jal	_cz_calculate_lengths

	addi	t0, sp, 16
	lhu	t1, CZ_CL_LEN(t0)
	li	t2, 1
	bne	t1, t2, test_fail

	addi	t0, t0, CZ_CL_SIZE
	lhu	t1, CZ_CL_LEN(t0)
	li	t2, 1
	bne	t1, t2, test_fail

	addi	a0, sp, 16
	li	a1, 2
	jal	_cz_calculate_codes

	addi	t0, sp, 16
	lhu	t1, CZ_CL_CODE(t0)
	bnez	t1, test_fail

	addi	t0, t0, CZ_CL_SIZE
	lhu	t1, CZ_CL_CODE(t0)
	li	t2, 1
	bne	t1, t2, test_fail

	li	a0, '.'
	jal	write_byte

	addi	sp, sp, 32

	# ══════════════════════════════════════════════════
	# Test 4: Lookup table
	# ══════════════════════════════════════════════════
	li	a0, 'T'
	jal	write_byte

	addi	sp, sp, -8
	li	t0, 0
	sh	t0, 0(sp)
	li	t0, 1
	sh	t0, 2(sp)
	li	t0, 1
	sh	t0, 4(sp)
	li	t0, 1
	sh	t0, 6(sp)

	addi	sp, sp, -512
	li	t0, 128
	mv	t1, sp
_t4_zero:
	sw	zero, 0(t1)
	addi	t1, t1, 4
	addi	t0, t0, -1
	bnez	t0, _t4_zero

	addi	a0, sp, 512
	li	a1, 2
	mv	a2, sp
	li	a3, 7
	jal	_cz_build_lookup_table

	lhu	t0, CZ_HL_SYMBOL(sp)
	bnez	t0, test_fail

	lhu	t0, CZ_HL_SYMBOL + CZ_HL_SIZE(sp)
	li	t1, 1
	bne	t0, t1, test_fail

	li	a0, '.'
	jal	write_byte

	addi	sp, sp, 520

	# ══════════════════════════════════════════════════
	# Test 5: Round-trip compress → decompress
	# ══════════════════════════════════════════════════
	li	a0, 'R'
	jal	write_byte

	# Input: "ABCABCABCABCABCABCABCABC" (24 bytes, repeating pattern)
	# Located at _rt_input (defined below)

	LOAD_ADDRESS	a0, _rt_input
	li	a1, 24

	# Output buffer at gp + 0x10000
	mv	t0, gp
	li	t1, 0x10000
	add	a2, t0, t1			# compressed output

	# match_array at gp + 0x20000 (need 24*4+4 = 100 bytes)
	li	t1, 0x20000
	add	a3, t0, t1			# match_array

	jal	compress_block

	# a0 = compressed size, should be > 0
	blez	a0, test_fail

	# Save compressed size
	mv	s0, a0

	# Now decompress
	mv	t0, gp
	li	t1, 0x10000
	add	a0, t0, t1			# compressed input
	mv	a1, s0				# compressed len

	li	t1, 0x30000
	add	a2, t0, t1			# decompressed output

	li	a3, 256				# capacity

	jal	decompress_block

	# a0 = decompressed size, should be 24
	li	t0, 24
	bne	a0, t0, test_fail

	# Verify decompressed output matches input
	LOAD_ADDRESS	t0, _rt_input
	mv	t3, gp
	li	t4, 0x30000
	add	t1, t3, t4			# decompressed output
	li	t2, 24
_rt_cmp:
	beqz	t2, _rt_cmp_done
	lbu	t3, 0(t0)
	lbu	t4, 0(t1)
	bne	t3, t4, test_fail
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	_rt_cmp
_rt_cmp_done:

	li	a0, '.'
	jal	write_byte

	# ══════════════════════════════════════════════════
	# Test 6: Round-trip with all-literal (short) input
	# ══════════════════════════════════════════════════
	li	a0, 'S'
	jal	write_byte

	LOAD_ADDRESS	a0, _rt_short
	li	a1, 5

	mv	t0, gp
	li	t1, 0x10000
	add	a2, t0, t1
	li	t1, 0x20000
	add	a3, t0, t1

	jal	compress_block
	blez	a0, test_fail
	mv	s0, a0

	mv	t0, gp
	li	t1, 0x10000
	add	a0, t0, t1
	mv	a1, s0
	li	t1, 0x30000
	add	a2, t0, t1
	li	a3, 256
	jal	decompress_block

	li	t0, 5
	bne	a0, t0, test_fail

	LOAD_ADDRESS	t0, _rt_short
	mv	t3, gp
	li	t4, 0x30000
	add	t1, t3, t4
	li	t2, 5
_rt_cmp2:
	beqz	t2, _rt_cmp2_done
	lbu	t3, 0(t0)
	lbu	t4, 0(t1)
	bne	t3, t4, test_fail
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	_rt_cmp2
_rt_cmp2_done:

	li	a0, '.'
	jal	write_byte

	# ══════════════════════════════════════════════════
	# All passed
	# ══════════════════════════════════════════════════
	li	a0, '\n'
	jal	write_byte

	li	t0, EXIT_ADDR
	li	t1, EXIT_PASS
	sw	t1, 0(t0)
_tc_halt:
	wfi
	j	_tc_halt


test_fail:
	li	a0, '!'
	jal	write_byte
	li	a0, '\n'
	jal	write_byte
_tc_fail:
	wfi
	j	_tc_fail


_cz_floor_log2:
	li	a0, 0
	mv	t1, t0
_fl_loop:
	srli	t1, t1, 1
	beqz	t1, _fl_done
	addi	a0, a0, 1
	j	_fl_loop
_fl_done:
	ret


bs_write:
	sll	t0, a0, s2
	or	s1, s1, t0
	add	s2, s2, a1
_bsw_flush:
	li	t0, 8
	blt	s2, t0, _bsw_done
	andi	t0, s1, 0xFF
	add	t1, s0, s3
	sb	t0, 0(t1)
	addi	s3, s3, 1
	srli	s1, s1, 8
	addi	s2, s2, -8
	j	_bsw_flush
_bsw_done:
	ret


bs_flush:
	beqz	s2, _bsf_done
	andi	t0, s1, 0xFF
	add	t1, s0, s3
	sb	t0, 0(t1)
	addi	s3, s3, 1
	li	s1, 0
	li	s2, 0
_bsf_done:
	ret


bs_read:
	mv	t4, a0
_bsr_load:
	bge	s2, t4, _bsr_extract
	add	t0, s0, s3
	lbu	t0, 0(t0)
	sll	t0, t0, s2
	or	s1, s1, t0
	addi	s3, s3, 1
	addi	s2, s2, 8
	j	_bsr_load
_bsr_extract:
	li	t0, 1
	sll	t0, t0, t4
	addi	t0, t0, -1
	and	a0, s1, t0
	srl	s1, s1, t4
	sub	s2, s2, t4
	ret


write_byte:
	li	t1, UART_BASE
	lbu	t2, UART_LSR(t1)
	andi	t2, t2, UART_WR_MASK
	beqz	t2, write_byte
	sb	a0, 0(t1)
	ret


DEFINE_COMPRESS


.balign 4
_rt_input:
	.ascii	"ABCABCABCABCABCABCABCABC"

.balign 4
_rt_short:
	.ascii	"Hello"

_test_data:
