.equ	UART_BASE,		0x10000000
.equ	UART_LSR,		5
.equ	UART_WR_MASK,		0x20

.altmacro
.macro LOAD_ADDRESS reg, label
_base\@:
	# Uses \@ to make a unique constant name for every expansion
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

# Macro to setup list of registers. Save all to stack
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

# Tear down the stack (LIFO order for stack frames)
.macro TEAR_DOWN
	_exec_tear_down %_macro_depth
	_kill_tear_down %_macro_depth
	.set _macro_depth, _macro_depth - 1
.endm

.macro RETURN
	TEAR_DOWN
	ret
.endm


.macro QR_STEP a, b, d, tmp, rot
	add	\a, \a, \b
	xor	\d, \d, \a
	slli \tmp, \d, \rot		# tmp = d << rot
	srli \d, \d, (32 - \rot)	# d = d >> (32 - rot)
	or	\d, \d, \tmp		# d = (d << rot) | (d >> (32 - rot))
.endm

# a, b, c, d are the 4 registers you're working on
.macro CHACHA_QR a, b, c, d
	QR_STEP \a, \b, \d, t5, 16		# Step 1: d is rotated
	QR_STEP \c, \d, \b, t5, 12		# Step 2: b is rotated
	QR_STEP \a, \b, \d, t5, 8		# Step 3: d is rotated
	QR_STEP \c, \d, \b, t5, 7		# Step 4: b is rotated
.endm

.macro CHACHA_ROUND
	# --- Column Rounds ---
	#           a   b   c   d
	CHACHA_QR	s0, s4, s8, t1	# Column 0: x[0], x[4], x[8], x[12]
	CHACHA_QR	s1, s5, s9, t2	# Column 1: x[1], x[5], x[9], x[13]
	CHACHA_QR	s2, s6, s10, t3 # Column 2: x[2], x[6], x[10], x[14]
	CHACHA_QR	s3, s7, t0, t4	# Column 3: x[3], x[7], x[11], x[15]

	# --- Diagonal Rounds ---
	#           a   b   c   d
	CHACHA_QR	s0, s5, s10, t4 # Diag 1: x[0], x[5], x[10], x[15]
	CHACHA_QR	s1, s6, t0, t1	# Diag 2: x[1], x[6], x[11], x[12]
	CHACHA_QR	s2, s7, s8, t2	# Diag 3: x[2], x[7], x[8],  x[13]
	CHACHA_QR	s3, s4, s9, t3	# Diag 4: x[3], x[4], x[9],  x[14]
.endm

# x[0-10] = s0-s10, x[11-15] = t0-t4
.macro CHACHA_ROUNDS
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
	CHACHA_ROUND
.endm

.macro CHACHA20_BLOCK
	SETUP		s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11
	mv		s11, a0

	lw		s0, 0(s11)
	lw		s1, 4(s11)
	lw		s2, 8(s11)
	lw		s3, 12(s11)
	lw		s4, 16(s11)
	lw		s5, 20(s11)
	lw		s6, 24(s11)
	lw		s7, 28(s11)
	lw		s8, 32(s11)
	lw		s9, 36(s11)
	lw		s10, 40(s11)
	lw		t0, 44(s11)
	lw		t1, 48(s11)
	lw		t2, 52(s11)
	lw		t3, 56(s11)
	lw		t4, 60(s11)

	CHACHA_ROUNDS

	.macro ADD_BACK reg ind
		lw		t5, \ind(s11)
		add		t5, \reg, t5
		sw		t5, \ind(s11)
	.endm

	ADD_BACK	s0, 0
	ADD_BACK	s1, 4
	ADD_BACK	s2, 8
	ADD_BACK	s3, 12
	ADD_BACK	s4, 16
	ADD_BACK	s5, 20
	ADD_BACK	s6, 24
	ADD_BACK	s7, 28
	ADD_BACK	s8, 32
	ADD_BACK	s9, 36
	ADD_BACK	s10, 40
	ADD_BACK	t0, 44
	ADD_BACK	t1, 48
	ADD_BACK	t2, 52
	ADD_BACK	t3, 56
	ADD_BACK	t4, 60

	TEAR_DOWN
.endm

	# Setup stack
	LOAD_ADDRESS	sp, data
	addi		sp, sp, 15
	andi		sp, sp, -16
	li		t0, 0x100000
	add		sp, sp, t0
	
	mv		a0, sp
	li		t0, 1
	sw		t0, 0(a0)

	CHACHA20_BLOCK
	jal		print_hash
	li		a0, '\n'
	jal		write_byte


1:	wfi
	j		1b

print_hash:
	.macro PRINT_INDEX ind
		lw		a0,		\ind(s0)
		jal		print_hex
	.endm
	SETUP		s0
	mv		s0, a0
	li		a1, 1
	PRINT_INDEX	0
	PRINT_INDEX	4
	PRINT_INDEX	8
	PRINT_INDEX	12
	PRINT_INDEX	16
	PRINT_INDEX	20
	PRINT_INDEX	24
	PRINT_INDEX	28
	mv		a0, s0
	RETURN
	


write_byte:
	li		t1, UART_BASE
	lbu		t2, UART_LSR(t1)
	andi		t2, t2, UART_WR_MASK
	beqz		t2, write_byte
	sb		a0, 0(t1)
	ret

print_hex:
	SETUP		s0, s1, s2, t0, t1, t2, a0

	mv		s0, a0		# Save original value

	# Print "0x" prefix
	bnez		a1, skip_0x
	li		a0, '0' 
	jal		write_byte
	li		a0, 'x'
	jal		write_byte
skip_0x:

1:	li		s1, 28		# Start at highest nibble
2:	
	srl		t2, s0, s1		# Isolate nibble
	andi		t2, t2, 0xF
	
	# Convert nibble to ASCII
	li		a0, 10
	blt		t2, a0, 5f		# If 0-9
	addi		t2, t2, 7		# Adjust for A-F
5:	addi		a0, t2, 48		# ASCII '0'
	jal		write_byte

next_nibble:
	addi		s1, s1, -4		# Move to next 4 bits
	bgez		s1, 2b
	
4:	RETURN

data:
