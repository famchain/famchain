# bench_compress.S — Compress bible.txt as single block, verify round-trip
#
# Run standalone in QEMU:
#   qemu-system-riscv32 -machine virt -nographic -bios none -smp 1 \
#     -m 256M -device loader,file=tmp/bench_compress.bin,addr=0x80000000

.equ	EXIT_ADDR,	0x100000
.equ	EXIT_PASS,	0x5555
.equ	UART_BASE,	0x10000000
.equ	UART_LSR,	5
.equ	UART_WR_MASK,	0x20

.include "macros.inc"
.include "compress.inc"

_start:
	# Stack at high address (compress_block uses ~150K internally)
	li	sp, 0x90000000

	# Input
	LOAD_ADDRESS	s0, _bible_start
	LOAD_ADDRESS	s1, _bible_end
	sub	s1, s1, s0			# s1 = input size

	# Print "IN:"
	li	a0, 'I'
	jal	write_byte
	li	a0, 'N'
	jal	write_byte
	li	a0, ':'
	jal	write_byte
	mv	a0, s1
	jal	print_dec
	li	a0, '\n'
	jal	write_byte

	# Workspace (well above code+data ~0x80450000):
	#   output:      0x81000000 (need input_len + 3 ~= 4.4 MB)
	#   match_array: 0x81800000 (need input_len * 4 + 4 ~= 17.6 MB)
	#   decomp out:  0x82C00000 (need input_len ~= 4.4 MB)
	li	s2, 0x81000000			# output buffer
	li	s3, 0x81800000			# match_array
	li	s4, 0x82C00000			# decompress output

	# ── Compress ──
	mv	a0, s0				# input
	mv	a1, s1				# input len
	mv	a2, s2				# output
	mv	a3, s3				# match_array
	jal	compress_block

	bltz	a0, _error
	mv	s5, a0				# s5 = compressed size

	# Print "OUT:"
	li	a0, 'O'
	jal	write_byte
	li	a0, 'U'
	jal	write_byte
	li	a0, 'T'
	jal	write_byte
	li	a0, ':'
	jal	write_byte
	mv	a0, s5
	jal	print_dec
	li	a0, '\n'
	jal	write_byte

	# ── Decompress ──
	mv	a0, s2				# compressed data
	mv	a1, s5				# compressed len
	mv	a2, s4				# decompress output
	li	a3, 0x00500000			# capacity (~5 MB)
	jal	decompress_block

	bltz	a0, _error

	# Check decompressed size matches input
	bne	a0, s1, _verify_error

	# ── Verify byte-by-byte ──
	mv	t0, s0				# original
	mv	t1, s4				# decompressed
	mv	t2, s1				# count
_verify_cmp:
	beqz	t2, _verify_ok
	lbu	t3, 0(t0)
	lbu	t4, 0(t1)
	bne	t3, t4, _verify_error
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	_verify_cmp

_verify_ok:
	li	a0, 'O'
	jal	write_byte
	li	a0, 'K'
	jal	write_byte
	li	a0, '\n'
	jal	write_byte

	li	t0, EXIT_ADDR
	li	t1, EXIT_PASS
	sw	t1, 0(t0)
_halt:	wfi
	j	_halt

_error:
	li	a0, 'E'
	jal	write_byte
	li	a0, '!'
	jal	write_byte
	li	a0, '\n'
	jal	write_byte
_ehalt:	wfi
	j	_ehalt

_verify_error:
	li	a0, 'V'
	jal	write_byte
	li	a0, '!'
	jal	write_byte
	li	a0, '\n'
	jal	write_byte
_vhalt:	wfi
	j	_vhalt


# ── print_dec: print u32 in a0 as decimal ──
print_dec:
	addi	sp, sp, -48
	sw	ra, 0(sp)
	mv	t0, a0
	li	t1, 0
	addi	t2, sp, 4

	beqz	t0, _pd_zero

_pd_loop:
	beqz	t0, _pd_print
	li	t3, 0
	mv	t4, t0
_pd_div10:
	li	t5, 10
	blt	t4, t5, _pd_div10_done
	sub	t4, t4, t5
	addi	t3, t3, 1
	j	_pd_div10
_pd_div10_done:
	addi	t4, t4, '0'
	add	t5, t2, t1
	sb	t4, 0(t5)
	addi	t1, t1, 1
	mv	t0, t3
	j	_pd_loop

_pd_zero:
	li	t4, '0'
	sb	t4, 0(t2)
	li	t1, 1

_pd_print:
	addi	t1, t1, -1
_pd_rev:
	bltz	t1, _pd_ret
	add	t0, t2, t1
	lbu	a0, 0(t0)
	li	t3, UART_BASE
_pd_wait:
	lbu	t4, UART_LSR(t3)
	andi	t4, t4, UART_WR_MASK
	beqz	t4, _pd_wait
	sb	a0, 0(t3)
	addi	t1, t1, -1
	j	_pd_rev

_pd_ret:
	lw	ra, 0(sp)
	addi	sp, sp, 48
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
_bible_start:
	.incbin "resources/bible.txt"
_bible_end:
