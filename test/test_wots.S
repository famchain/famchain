# test_wots.S — WOTS+ unit test: keygen + sign + verify
#
# Generates a keypair from a known seed, signs a known message,
# then verifies the signature. Uses QEMU exit device for pass/fail.
#
# NOTE: This test is slow (~14K blake2s calls). May take several seconds.

.equ	EXIT_ADDR,	0x100000
.equ	EXIT_PASS,	0x5555
.equ	UART_BASE,	0x10000000
.equ	UART_LSR,	5
.equ	UART_WR_MASK,	0x20

.include "macros.inc"
.include "blake2s.inc"
.include "wots.inc"

# Memory layout in data region (from gp):
# gp + 0:      sk  (576 bytes)
# gp + 576:    pk  (576 bytes)
# gp + 1152:   sig (576 bytes)
# gp + 1728:   message hash (32 bytes)
# gp + 1760:   seed (32 bytes)
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
	li		t0, 0x100000
	add		sp, gp, t0

	# ── setup seed (0xAA * 32) ──
	li		t0, SEED_OFF
	add		t0, gp, t0
	li		t1, 0xAAAAAAAA
	.set	_i, 0
	.rept	8
	sw		t1, (_i * 4)(t0)
	.set	_i, _i + 1
	.endr

	# ── compute message = blake2s("test message for wots") ──
	LOAD_ADDRESS	a0, _test_msg_text
	li		a1, 21			# strlen("test message for wots")
	li		t0, MSG_OFF
	add		a2, gp, t0
	jal		blake2s

	# ── verify message hash matches expected ──
	li		a0, 'M'
	jal		write_byte

	li		t0, MSG_OFF
	add		t0, gp, t0
	LOAD_ADDRESS	t1, _expected_msg
	li		t2, 8
1:	lw		t3, 0(t0)
	lw		t4, 0(t1)
	bne		t3, t4, test_fail
	addi		t0, t0, 4
	addi		t1, t1, 4
	addi		t2, t2, -1
	bnez		t2, 1b

	li		a0, '.'
	jal		write_byte

	# ── keygen ──
	li		a0, 'K'
	jal		write_byte

	li		t0, SEED_OFF
	add		a0, gp, t0		# seed
	li		t0, PK_OFF
	add		a1, gp, t0		# pk
	li		t0, SK_OFF
	add		a2, gp, t0		# sk
	jal		wots_keyfrom

	# spot-check sk[0] against expected
	mv		t0, gp			# sk is at gp + 0
	LOAD_ADDRESS	t1, _expected_sk0
	li		t2, 8
1:	lw		t3, 0(t0)
	lw		t4, 0(t1)
	bne		t3, t4, test_fail
	addi		t0, t0, 4
	addi		t1, t1, 4
	addi		t2, t2, -1
	bnez		t2, 1b

	li		a0, '.'
	jal		write_byte

	# ── sign ──
	li		a0, 'S'
	jal		write_byte

	li		t0, SK_OFF
	add		a0, gp, t0		# sk
	li		t0, MSG_OFF
	add		a1, gp, t0		# message
	li		t0, SIG_OFF
	add		a2, gp, t0		# sig
	jal		wots_sign

	li		a0, '.'
	jal		write_byte

	# ── verify ──
	li		a0, 'V'
	jal		write_byte

	li		t0, PK_OFF
	add		a0, gp, t0		# pk
	li		t0, SIG_OFF
	add		a1, gp, t0		# sig
	li		t0, MSG_OFF
	add		a2, gp, t0		# message
	jal		wots_verify

	bnez		a0, test_fail

	li		a0, '.'
	jal		write_byte
	li		a0, '\n'
	jal		write_byte

	# ── all passed ──
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

write_byte:
	li		t1, UART_BASE
	lbu		t2, UART_LSR(t1)
	andi		t2, t2, UART_WR_MASK
	beqz		t2, write_byte
	sb		a0, 0(t1)
	ret

DEFINE_BLAKE2S
DEFINE_WOTS

# ──────────────────────────────────────────────────────────────────────────────
# Test data
# ──────────────────────────────────────────────────────────────────────────────
	.balign 4

_test_msg_text:
	.ascii	"test message for wots"
	.balign 4

# Expected message hash: blake2s("test message for wots")
_expected_msg:
	.word	0x124F6752, 0xCE245256, 0xF7351839, 0xE575CED0
	.word	0x5FD2F416, 0x266C31B0, 0xB1FA94D6, 0xDE134521

# Expected sk[0]: blake2s(0xAA*32 || 0x00)
_expected_sk0:
	.word	0xA140DE27, 0x4B1070DA, 0xCEB4C263, 0x74D48709
	.word	0xB0ADA4FB, 0x3CC780CA, 0x42923694, 0x116E997A

_test_data:
