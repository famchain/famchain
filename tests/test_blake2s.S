# test_blake2s.S — BLAKE2s test harness with known vectors
#
# Runs blake2s on known inputs, compares against expected outputs.
# Prints "PASS" or "FAIL" for each test, then halts.

.equ	UART_BASE,	0x10000000
.equ	UART_LSR,	5
.equ	UART_WR_MASK,	0x20

.altmacro

.macro LOAD_ADDRESS reg, label
_base\@:
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

.macro TEAR_DOWN
	_exec_tear_down %_macro_depth
	_kill_tear_down %_macro_depth
	.set _macro_depth, _macro_depth - 1
.endm

.macro RETURN
	TEAR_DOWN
	ret
.endm

.include "../inc/blake2s.inc"

# ──────────────────────────────────────────────────────────────────────────────
# RUN_TEST: hash input, compare to expected, print PASS/FAIL
# test_num = test number (immediate), in_label = input data label,
# in_len = input length, exp_label = expected hash label
# ──────────────────────────────────────────────────────────────────────────────
.macro RUN_TEST test_num, in_label, in_len, exp_label
	# print test number
	li	a0, '0' + \test_num
	jal	write_byte
	li	a0, ':'
	jal	write_byte

	# blake2s(input, len, output)
	LOAD_ADDRESS a0, \in_label
	li	a1, \in_len
	addi	sp, sp, -32
	mv	a2, sp
	jal	blake2s

	# compare 32 bytes
	LOAD_ADDRESS t0, \exp_label
	mv	t1, sp
	li	t2, 8
1:	lw	t3, 0(t1)
	lw	t4, 0(t0)
	bne	t3, t4, 2f
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	bnez	t2, 1b

	addi	sp, sp, 32
	# PASS
	li	a0, 'P'; jal write_byte
	li	a0, 'A'; jal write_byte
	li	a0, 'S'; jal write_byte
	li	a0, 'S'; jal write_byte
	li	a0, '\n'; jal write_byte
	j	3f

2:	addi	sp, sp, 32
	# FAIL
	li	a0, 'F'; jal write_byte
	li	a0, 'A'; jal write_byte
	li	a0, 'I'; jal write_byte
	li	a0, 'L'; jal write_byte
	li	a0, '\n'; jal write_byte
3:
.endm

# ──────────────────────────────────────────────────────────────────────────────
_start:
	LOAD_ADDRESS gp, _test_data
	li	t0, 4095
	add	gp, gp, t0
	li	t0, -4096
	and	gp, gp, t0
	li	t0, 0x100000
	add	sp, gp, t0

	RUN_TEST 1, tv1_in, 0, tv1_hash		# empty input
	RUN_TEST 2, tv2_in, 3, tv2_hash		# "abc"
	RUN_TEST 3, tv3_in, 64, tv3_hash		# 64 bytes (one block)
	RUN_TEST 4, tv4_in, 65, tv4_hash		# 65 bytes (two blocks)

	li	a0, 'D'; jal write_byte		# done
	li	a0, '\n'; jal write_byte
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
# Test vectors
# ──────────────────────────────────────────────────────────────────────────────
	.balign 4

# Test 1: empty input
tv1_in:	.byte 0		# placeholder (0-length input)
tv1_hash:
	.word 0x307A2169, 0x94809079, 0xD02111E1, 0x7C4A3542
	.word 0x48B6551F, 0x1EA5A12C, 0xFD0D251B, 0xF9EED01E

# Test 2: "abc"
tv2_in:	.ascii "abc"
	.balign 4
tv2_hash:
	.word 0x8C5E8C50, 0xE2147C32, 0xA32BA7E1, 0x2F45EB4E
	.word 0x208B4537, 0x293AD69E, 0x4C9B994D, 0x82596786

# Test 3: bytes 0x00..0x3f (64 bytes, exactly one block)
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
