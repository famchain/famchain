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
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# ──────────────────────────────────────────────────────────────────────────────
# file: fam1.s - second stage (asm impl)
# ──────────────────────────────────────────────────────────────────────────────

	li		x2, 0x10000000		# UART base
	la		x3, data		# Label offset Base
	li		x4, 2048		# first pass src buffer
	add		x5, x3, x4		# x5 = start of src buffer
	mv		x6, x5			# x6 = pointer for capture
	li		x7, 10			# last_char = '\n' (initial)

capture_loop:
	jal		x1, read_uart		# read next char
	beqz		x29, cont_capture	# not a dot, continue 
	li		x8, 10
	beq		x7, x8, end_capture	# LF. termination
	li		x8, 13
	beq		x7, x8, end_capture	# CR. termination

cont_capture:
	sb		x30, 0(x6)		# store in buffer
	addi		x6, x6, 1		# advance capture pointer
	mv		x7, x30			# set last char
	j		capture_loop		# repeat

end_capture:
	jal		x1, pass1		# first pass
	jal		x1, output		# output data
	jal		x1, exit		# call exit function

# ──────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ──────────────────────────────────────────────────────────────────────────────

# Input x5/x6 start/end of input buffer. The function updates them in place.
# Min clobber x27
pass1:
	mv		x29, x5
	mv		x30, x6
pass1_loop:
	beq		x29, x6, pass1_end_loop

        lb		x28, 0(x29)      # x28 = *src
	addi		x29, x29, 1

	li		x27, 35
	beq		x27, x28, skip_comment

        sb		x28, 0(x30)      # *dst = x28
	addi		x30, x30, 1
	j		pass1_loop

skip_comment:
	beq		x29, x6, pass1_end_loop
	lb		x27, 0(x29)
	li		x28, 10
	beq		x28, x27, pass1_loop
	li		x28, 13
	beq             x28, x27, pass1_loop
	addi            x29, x29, 1
	j		skip_comment

pass1_end_loop:
	mv		x5, x29
	mv		x6, x30
	ret



# Input: x2 (UART base)
# Input: x5 (start of work buffer)
# Input: x6 (pointer to the end of work buffer)
# Min clobber: x28
output:
	mv		x30, x5

output_loop:
	beq		x30, x6, end_output
	lbu		x29, 0(x30)

begin_write:
	lbu		x28, 5(x2)
	andi		x28, x28, 0x20		# mask
	beqz		x28, begin_write	# retry

	li		x28, 13
	bne		x29, x28, not_cr
	li		x29, 10

not_cr:
	sb		x29, 0(x2)		# send to UART
	addi		x30, x30, 1		# advance
	j		output_loop

end_output:
	ret

# Input: x2 (UART base)
# Output: x29 (is_dot)
# Min clobber: x29
read_uart:
	lbu		x30, 5(x2)		# Read from UART
	andi		x30, x30, 1		# mask
	beqz		x30, read_uart		# if not ready read again
	lbu		x30, 0(x2)		# Get current char, store x30

	# Check for termination
	li		x29, 46 # Check for '.' ASCII 46.
	bne		x29, x30, no_dot
	li		x29, 1
	ret

no_dot:
	li		x29, 0
	ret

# No inputs/Outputs/return
exit:
    li      x30, 0x100000          # QEMU Virt Test Device
    li      x29, 0x5555            # Shutdown command
    sw      x29, 0(x30)

final_spin:
    wfi
    j       final_spin


# ──────────────────────────────────────────────────────────────────────────────
# data pointer - pointer to entire memory block after program
# ──────────────────────────────────────────────────────────────────────────────
.align 8
data:
