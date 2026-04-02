# pow.inc — Bible-based memory-hard Proof of Work for RISC-V 32-bit
#
# Usage:
#   .include "macros.inc"
#   .include "blake2s.inc"
#   .include "compress.inc"
#   .include "pow.inc"
#   ...
#   DEFINE_POW
#
# Public labels emitted by DEFINE_POW:
#   bible_expand(a0=compressed, a1=compressed_len, a2=table_out, a3=table_size)
#       Builds the PoW lookup table. Copies compressed data, then extends
#       via blake2s chain (16 iterations per 32-byte entry).
#       Returns: a0 = 0 on success, -1 on error
#
#   pow_hash(a0=table_ptr, a1=table_mask, a2=header_ptr, a3=out_ptr)
#       Compute PoW hash. blake2s(header) → 32 lookup rounds → 32-byte output.
#       header is 128 bytes. table_mask = (table_size >> 5) - 1.
#       Returns: nothing (result written to out_ptr)
#
#   mine_block(a0=table_ptr, a1=table_mask, a2=header_ptr, a3=target_ptr)
#       Mine: iterate nonces at header[124..127], hash, compare against target.
#       Additional args on stack: out_ptr at 0(sp), max_iter at 4(sp).
#       Returns: a0 = nonce on success, -1 if max_iter reached
#
# Requires: blake2s, decompress_block from blake2s.inc / compress.inc

.equ	POW_BLAKE2S_ITERS,	16		# blake2s iterations per generated entry
.equ	POW_LOOKUP_ROUNDS,	32		# random lookup rounds per hash
.equ	POW_HEADER_LEN,		128		# header length for hashing
.equ	POW_NONCE_OFFSET,	124		# nonce position in header (last 4 bytes)

.macro DEFINE_POW

# ══════════════════════════════════════════════════════════════════════════════
# bible_expand: build PoW lookup table from compressed bible data
# a0 = compressed_ptr (raw compressed bible data)
# a1 = compressed_len
# a2 = table_out (must be table_size bytes)
# a3 = table_size (must be multiple of 32, e.g. 16*1024*1024)
# Returns: a0 = 0 success, -1 error
# ══════════════════════════════════════════════════════════════════════════════
bible_expand:
	SETUP	s0, s1, s2, s3, s4, s5, s6

	mv	s0, a0				# compressed_ptr
	mv	s1, a1				# compressed_len
	mv	s2, a2				# table_out
	mv	s3, a3				# table_size

	# Validate: table_size must be >= 64
	li	t0, 64
	bltu	s3, t0, _be_err

	# Phase 1: copy compressed data to start of table
	# copy_len = min(compressed_len, table_size)
	mv	t2, s1
	bleu	t2, s3, _be_copy_start
	mv	t2, s3				# truncate to table_size
_be_copy_start:
	mv	t0, s0				# src
	mv	t1, s2				# dst
_be_copy:
	beqz	t2, _be_copy_done
	lbu	t3, 0(t0)
	sb	t3, 0(t1)
	addi	t0, t0, 1
	addi	t1, t1, 1
	addi	t2, t2, -1
	j	_be_copy
_be_copy_done:

	# Pad remaining bytes of the first partial 32-byte block with zeros
	# (align compressed_len up to next 32-byte boundary)
	andi	t0, s1, 31			# compressed_len & 31
	beqz	t0, _be_aligned
	li	t1, 32
	sub	t0, t1, t0			# bytes to pad
	add	t1, s2, s1			# dst = table + compressed_len
_be_pad:
	beqz	t0, _be_aligned
	sb	zero, 0(t1)
	addi	t1, t1, 1
	addi	t0, t0, -1
	j	_be_pad
_be_aligned:

	# s4 = offset of first generated entry (compressed_len rounded up to 32)
	addi	s4, s1, 31
	li	t0, -32
	and	s4, s4, t0			# s4 = (compressed_len + 31) & ~31

	# Phase 2: blake2s chain to fill remaining entries
	# Each entry: hash previous 32-byte block POW_BLAKE2S_ITERS times
	# Seed: last 32 bytes of the compressed data region
	addi	sp, sp, -32			# temp buffer for blake2s output
	mv	s5, sp

_be_gen_loop:
	bgeu	s4, s3, _be_done		# offset >= table_size → done

	# Input for chain: the previous 32-byte block in the table
	addi	a0, s4, -32
	add	a0, s2, a0			# table + offset - 32

	# Run POW_BLAKE2S_ITERS rounds of blake2s
	li	s6, POW_BLAKE2S_ITERS
_be_iter:
	beqz	s6, _be_iter_done
	# blake2s(input=a0, len=32, output=s5)
	li	a1, 32
	mv	a2, s5
	jal	blake2s
	# Next iteration: input = output
	mv	a0, s5
	addi	s6, s6, -1
	j	_be_iter
_be_iter_done:

	# Copy result to table
	add	t0, s2, s4			# dst = table + offset
	mv	t1, s5				# src = temp buffer
	li	t2, 8				# 32 bytes = 8 words
_be_store:
	lw	t3, 0(t1)
	sw	t3, 0(t0)
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	bnez	t2, _be_store

	addi	s4, s4, 32			# next entry
	j	_be_gen_loop

_be_done:
	addi	sp, sp, 32			# free temp buffer
	li	a0, 0
	j	_be_ret

_be_err:
	li	a0, -1
_be_ret:
	RETURN


# ══════════════════════════════════════════════════════════════════════════════
# pow_hash: compute memory-hard PoW hash
# a0 = table_ptr (16MB lookup table)
# a1 = table_mask ((table_size >> 5) - 1, e.g. 0x7FFFF for 16MB)
# a2 = header_ptr (128 bytes: block header with nonce at offset 124)
# a3 = out_ptr (32-byte output)
# ══════════════════════════════════════════════════════════════════════════════
pow_hash:
	SETUP	s0, s1, s2, s3, s4, s5

	mv	s0, a0				# table_ptr
	mv	s1, a1				# table_mask
	mv	s2, a3				# out_ptr

	# state = blake2s(header)
	# a0 = header_ptr (already in a0... wait, a0 = table_ptr now)
	mv	a0, a2				# header_ptr
	li	a1, POW_HEADER_LEN		# 128
	addi	sp, sp, -32			# state on stack
	mv	a2, sp
	jal	blake2s

	# sp now points to 32-byte state
	mv	s3, sp				# s3 = state ptr

	# 32 lookup rounds
	li	s4, POW_LOOKUP_ROUNDS
_ph_round:
	beqz	s4, _ph_done

	# idx = (state[0] ^ state[1] ^ ... ^ state[7]) & table_mask
	lw	t0, 0(s3)
	lw	t1, 4(s3)
	xor	t0, t0, t1
	lw	t1, 8(s3)
	xor	t0, t0, t1
	lw	t1, 12(s3)
	xor	t0, t0, t1
	lw	t1, 16(s3)
	xor	t0, t0, t1
	lw	t1, 20(s3)
	xor	t0, t0, t1
	lw	t1, 24(s3)
	xor	t0, t0, t1
	lw	t1, 28(s3)
	xor	t0, t0, t1
	and	t0, t0, s1			# & table_mask
	slli	t0, t0, 5			# * 32 (byte offset)
	add	t0, s0, t0			# table_ptr + offset

	# state ^= table[idx]
	lw	t1, 0(t0)
	lw	t2, 0(s3)
	xor	t2, t2, t1
	sw	t2, 0(s3)

	lw	t1, 4(t0)
	lw	t2, 4(s3)
	xor	t2, t2, t1
	sw	t2, 4(s3)

	lw	t1, 8(t0)
	lw	t2, 8(s3)
	xor	t2, t2, t1
	sw	t2, 8(s3)

	lw	t1, 12(t0)
	lw	t2, 12(s3)
	xor	t2, t2, t1
	sw	t2, 12(s3)

	lw	t1, 16(t0)
	lw	t2, 16(s3)
	xor	t2, t2, t1
	sw	t2, 16(s3)

	lw	t1, 20(t0)
	lw	t2, 20(s3)
	xor	t2, t2, t1
	sw	t2, 20(s3)

	lw	t1, 24(t0)
	lw	t2, 24(s3)
	xor	t2, t2, t1
	sw	t2, 24(s3)

	lw	t1, 28(t0)
	lw	t2, 28(s3)
	xor	t2, t2, t1
	sw	t2, 28(s3)

	addi	s4, s4, -1
	j	_ph_round

_ph_done:
	# Copy state to output
	mv	t0, s2				# out_ptr
	mv	t1, s3				# state
	li	t2, 8
_ph_copy:
	lw	t3, 0(t1)
	sw	t3, 0(t0)
	addi	t0, t0, 4
	addi	t1, t1, 4
	addi	t2, t2, -1
	bnez	t2, _ph_copy

	addi	sp, sp, 32			# free state
	RETURN


# ══════════════════════════════════════════════════════════════════════════════
# mine_block: iterate nonces until hash < target
# a0 = table_ptr
# a1 = table_mask
# a2 = header_ptr (128 bytes, nonce at offset 124, modified in place)
# a3 = target_ptr (32 bytes, big-endian comparison)
# Stack args: 0(sp) = out_ptr, 4(sp) = max_iter
# Returns: a0 = nonce on success, -1 if max_iter reached
# ══════════════════════════════════════════════════════════════════════════════
mine_block:
	SETUP	s0, s1, s2, s3, s4, s5, s6, s7

	mv	s0, a0				# table_ptr
	mv	s1, a1				# table_mask
	mv	s2, a2				# header_ptr
	mv	s3, a3				# target_ptr

	# Load stack args (offset by SETUP frame size)
	# SETUP saved 9 words (ra + s0-s7), rounded to 48 bytes
	lw	s4, 48(sp)			# out_ptr
	lw	s5, 52(sp)			# max_iter

	li	s6, 0				# nonce = 0

_mb_loop:
	bgeu	s6, s5, _mb_fail		# nonce >= max_iter → fail

	# Write nonce into header[124..127] (LE)
	li	t0, POW_NONCE_OFFSET
	add	t0, s2, t0
	sw	s6, 0(t0)

	# Compute hash
	mv	a0, s0				# table_ptr
	mv	a1, s1				# table_mask
	mv	a2, s2				# header_ptr
	mv	a3, s4				# out_ptr
	jal	pow_hash

	# Compare hash < target (LE u256: most significant byte at offset 31)
	li	t5, 31
_mb_cmp:
	bltz	t5, _mb_found			# all equal → hash == target, accept
	add	t0, s4, t5			# &hash[byte]
	add	t1, s3, t5			# &target[byte]
	lbu	t2, 0(t0)
	lbu	t3, 0(t1)
	bltu	t2, t3, _mb_found		# hash byte < target → success
	bgtu	t2, t3, _mb_next		# hash byte > target → next nonce
	addi	t5, t5, -1
	j	_mb_cmp

_mb_next:
	addi	s6, s6, 1
	j	_mb_loop

_mb_found:
	mv	a0, s6				# return nonce
	j	_mb_ret

_mb_fail:
	li	a0, -1
_mb_ret:
	RETURN

.endm	# DEFINE_POW
