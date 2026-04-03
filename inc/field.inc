# field.inc — BabyBear prime field arithmetic for RISC-V 32-bit
#
# BabyBear: p = 2^31 - 2^27 + 1 = 2013265921 = 0x78000001
#
# Usage:
#   .include "macros.inc"
#   .include "field.inc"
#   ...
#   DEFINE_FIELD
#
# Public labels emitted by DEFINE_FIELD:
#   fp_add(a0, a1) → a0 = (a0 + a1) mod p
#   fp_sub(a0, a1) → a0 = (a0 - a1) mod p
#   fp_mul(a0, a1) → a0 = (a0 * a1) mod p
#   fp_inv(a0)     → a0 = a0^(-1) mod p (Fermat: a^(p-2))
#   fp_neg(a0)     → a0 = -a0 mod p
#
# All functions are leaf (no SETUP/RETURN), clobber t-regs.
# Inputs must be in [0, p-1].

.equ	FP_P,		0x78000001	# 2^31 - 2^27 + 1 = 2013265921
.equ	FP_P_NEG,	0x87FFFFFF	# -p mod 2^32 = 2^32 - p

.macro DEFINE_FIELD

# ══════════════════════════════════════════════════════════════════════════════
# fp_add: a0 = (a0 + a1) mod p
# Clobbers: t0
# ══════════════════════════════════════════════════════════════════════════════
fp_add:
	add	a0, a0, a1
	# if a0 >= p, subtract p (handles both overflow and range)
	li	t0, FP_P
	bltu	a0, a1, _fpa_wrap		# unsigned overflow → definitely >= p
	bltu	a0, t0, _fpa_done		# no overflow and < p → done
_fpa_wrap:
	sub	a0, a0, t0
_fpa_done:
	ret


# ══════════════════════════════════════════════════════════════════════════════
# fp_sub: a0 = (a0 - a1) mod p
# Clobbers: t0
# ══════════════════════════════════════════════════════════════════════════════
fp_sub:
	bgeu	a0, a1, _fps_nowrap		# a0 >= a1 → no underflow
	li	t0, FP_P
	add	a0, a0, t0			# a0 + p
_fps_nowrap:
	sub	a0, a0, a1
	ret


# ══════════════════════════════════════════════════════════════════════════════
# fp_neg: a0 = -a0 mod p (= p - a0, or 0 if a0 == 0)
# Clobbers: t0
# ══════════════════════════════════════════════════════════════════════════════
fp_neg:
	beqz	a0, _fpn_done
	li	t0, FP_P
	sub	a0, t0, a0
_fpn_done:
	ret


# ══════════════════════════════════════════════════════════════════════════════
# fp_mul: a0 = (a0 * a1) mod p
#
# Software multiply: shift-and-add producing 64-bit result in (t1:t0),
# then Barrett-style reduction mod p.
#
# BabyBear reduction: p = 2^31 - 2^27 + 1
#   2^31 ≡ 2^27 - 1 (mod p)
#
# Clobbers: t0-t6
# ══════════════════════════════════════════════════════════════════════════════
fp_mul:
	# Modular shift-and-add: stays in 32 bits throughout.
	# Process multiplier bits from MSB to LSB:
	#   result = 0
	#   for each bit (MSB first):
	#     result = (2 * result) mod p
	#     if bit set: result = (result + multiplicand) mod p
	#
	# Inputs are < p < 2^31, so 2*result < 2^32 and result+multiplicand < 2^32.
	mv	t2, a0				# multiplicand
	mv	t3, a1				# multiplier
	li	t0, 0				# result
	li	t4, FP_P

	# Find highest set bit of multiplier to avoid leading-zero iterations
	li	t5, 0x40000000			# start at bit 30 (inputs < 2^31)

_fpm_loop:
	beqz	t5, _fpm_done
	# result = (2 * result) mod p
	add	t0, t0, t0			# 2 * result
	bgeu	t0, t4, _fpm_dbl_sub
	j	_fpm_dbl_ok
_fpm_dbl_sub:
	sub	t0, t0, t4
_fpm_dbl_ok:
	# if bit set: result = (result + multiplicand) mod p
	and	t6, t3, t5			# test current bit
	beqz	t6, _fpm_next
	add	t0, t0, t2			# result + multiplicand
	bgeu	t0, t4, _fpm_add_sub
	j	_fpm_next
_fpm_add_sub:
	sub	t0, t0, t4
_fpm_next:
	srli	t5, t5, 1			# next bit
	j	_fpm_loop

_fpm_done:
	mv	a0, t0
	ret


# ══════════════════════════════════════════════════════════════════════════════
# fp_inv: a0 = a0^(-1) mod p using Fermat's little theorem: a^(p-2) mod p
#
# p-2 = 0x77FFFFFF = 0111 0111 1111 1111 1111 1111 1111 1111
#
# Uses square-and-multiply. Clobbers: t0-t6, a1. Uses SETUP for s-regs.
# ══════════════════════════════════════════════════════════════════════════════
fp_inv:
	SETUP	s0, s1, s2

	mv	s0, a0				# base
	li	s1, 1				# result = 1
	li	s2, FP_P - 2			# exponent = p - 2

_fpi_loop:
	beqz	s2, _fpi_done
	andi	t0, s2, 1			# test LSB of exponent
	beqz	t0, _fpi_sq
	# result = result * base mod p
	mv	a0, s1
	mv	a1, s0
	jal	fp_mul
	mv	s1, a0
_fpi_sq:
	# base = base * base mod p
	mv	a0, s0
	mv	a1, s0
	jal	fp_mul
	mv	s0, a0
	srli	s2, s2, 1			# exponent >>= 1
	j	_fpi_loop

_fpi_done:
	mv	a0, s1
	RETURN

# ══════════════════════════════════════════════════════════════════════════════
# fp_pow: a0 = a0^a1 mod p (modular exponentiation via square-and-multiply)
# Clobbers: t0-t6 (via fp_mul). Uses SETUP for s-regs.
# ══════════════════════════════════════════════════════════════════════════════
fp_pow:
	SETUP	s0, s1, s2

	mv	s0, a0				# base
	li	s1, 1				# result = 1
	mv	s2, a1				# exponent

_fpp_loop:
	beqz	s2, _fpp_done
	andi	t0, s2, 1
	beqz	t0, _fpp_sq
	# result *= base
	mv	a0, s1
	mv	a1, s0
	jal	fp_mul
	mv	s1, a0
_fpp_sq:
	# base *= base
	mv	a0, s0
	mv	a1, s0
	jal	fp_mul
	mv	s0, a0
	srli	s2, s2, 1
	j	_fpp_loop

_fpp_done:
	mv	a0, s1
	RETURN

.endm	# DEFINE_FIELD
