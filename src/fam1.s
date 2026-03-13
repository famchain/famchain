# MIT License
#
# Copyright (c) 2026 Christopher Gilliard
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# ──────────────────────────────────────────────────────────────────────────────
# file: fam1.s - second stage (asm impl)
# ──────────────────────────────────────────────────────────────────────────────
.equ DATA_OFFSET, (data - dataptr)
	jal		init_io

# Setup stack and heap pointers
dataptr:
	auipc		x3, 0			# load pc
	addi		x3, x3, %lo(DATA_OFFSET)
	li		x2, 1
	add		x2, x2, 26		# 64 MiB
	li		x5, 2048		# Reserve for labels
	add		x5, x5, x3		# Input buffer
	mv		x6, x5			# End input buffer

	jal		capture
	jal		pass1
	jal		pass2
	jal		output
	jal		exit

pass1:
	mv		x29, x5
	mv		x30, x6
	mv		x20, x1
pass1_loop:

	bge		x29, x6, pass1_end_loop # pass complete
	lbu		x28, 0(x29)		# load byte
	addi		x29, x29, 1		# incr in iter
	li		x10, 32			# load white space limit
	ble		x28, x10, pass1_loop	# skip whitespace

	sb		x28, 0(x30)		# store value
	addi		x30, x30, 1		# incr out iter
	j		pass1_loop
pass1_end_loop:

	mv		x5, x29			# update start ptr to output
	mv		x6, x30			# update end ptr to output
	mv		x1, x20
	ret

pass2:
	ret

capture:
	mv		x20, x1
	li		x17, 10			# last byte
capture_loop:
	jal		read_byte
	li		x21, 46			# Load ASCII '.'
	bne		x30, x21, not_end
	li		x21, 10
	beq		x17, x21, test_e
	li		x21, 13
	beq		x17, x21, test_e
	j		not_end
test_e:
	jal		read_byte
	li		x21, 100
	bne		x30, x21, skip_d
	li		x30, 0x0
	j		not_end
skip_d:
	li		x21, 101
	beq		x30, x21, end_capture
not_end:
	sb		x30, 0(x6)
	addi		x6, x6, 1
	mv		x17, x30		# Update last byte
	j		capture_loop
end_capture:
	mv		x1, x20
	ret

output:
	mv		x20, x1
output_loop:
	bge		x5, x6, end_output
	lbu		x29, 0(x5)
	jal		write_byte
	addi		x5, x5, 1
	j		output_loop
end_output:
	mv		x1, x20
	ret

init_io:
	li		x4, 0x10000000		# UART base
	ret

# Input: x4 (UART base)
# Output: x30 (unsigned char read) x29 (is_dot)
read_byte:
	lbu		x30, 5(x4)		# Read from UART
	andi		x30, x30, 1		# mask
	beqz		x30, read_byte		# if not ready read again
	lbu		x30, 0(x4)		# Get current char, store x30
	ret   

write_byte:
	lbu		x28, 5(x4)
	andi		x28, x28, 0x20		# mask
	beqz		x28, write_byte		# retry
	sb		x29, 0(x4)		# send to UART
	ret

exit:
	li		x30, 0x100000		# QEMU Virt Test Device
	li		x29, 0x5555		# Shutdown command
	sw		x29, 0(x30)

final_spin:
	wfi
	j		final_spin


data:

