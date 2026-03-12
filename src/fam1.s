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
	li		x4, 0x10000000		# UART base

# Setup stack and heap pointers
dataptr:
	auipc		x3, 0			# load pc
	addi		x3, x3, %lo(DATA_OFFSET)
	li		x2, 1
	add		x2, x2, 26		# 64 MiB
	li		x5, 2048		# Reserve for labels
	add		x5, x5, x3		# Input buffer
	mv		x6, x5			# End input buffer
	li		x27, 10			# Last char

# Main capture loop
capture_loop:
	jal		x1, read_uart		# Read next char
	beqz		x29, do_capture		# not a dot, continue
	li		x29, 10			# LF terminator
	beq		x27, x29, cont_term_chk # Check for end
	li		x29, 13			# CR terminator
	beq		x27, x29, cont_term_chk # Check for end
	j		cont_capture		# Not start of line
cont_term_chk:
	jal		x1, read_uart		# Read next char
	li		x29, 101		# Load ASCII 'e'
	bne		x30, x29, skip_end      # not .end
	j		end_capture		# .end found
skip_end:
	li		x29, 100		# Load ASCII 'd'
	bne		x30, x29, skip_data	# not .data
	li		x30, 0xFF		# data marker
	j		do_capture
skip_data:
	li		x29, 116		# Load ASCII 't'
	bne		x30, x29, skip_text	# not .text
	li		x30, 0xFE		# text marker
	j		do_capture
skip_text:
do_capture:
	sb		x30, 0(x6)		# store in buffer
	addi		x6, x6, 1		# advance pointer
	mv		x27, x30		# set last char
	j		capture_loop		# repeat

end_capture:
	jal		output			# output
	jal		exit			# exit

# ──────────────────────────────────────────────────────────────────────────────
# Functions
# ──────────────────────────────────────────────────────────────────────────────

# Send a byte of data to UART
# inputs:
# x29: byte to send
# x4: UART address
# clobbers: x28
send_byte:
	lbu		x28, 5(x4)
	andi		x28, x28, 0x20		# mask
	beqz		x28, send_byte		# retry
	sb		x29, 0(x4)		# send to UART
	ret

output:
	mv		x30, x5			# Copy input to x30
	mv		x20, x1			# Save ra

# Main output loop, capture 4 bytes and process
output_loop:
	bge		x30, x6, end_output
	lbu		x10, 0(x30)
	addi		x30, x30, 1

	mv		x29, x10
	jal		send_byte
	j		output_loop
end_output:
	mv		x1, x20
	ret 

# Input: x4 (UART base)
# Output: x30 (unsigned char read) x29 (is_dot)
read_uart:
	lbu		x30, 5(x4)              # Read from UART
	andi		x30, x30, 1             # mask
	beqz		x30, read_uart          # if not ready read again
	lbu		x30, 0(x4)              # Get current char, store x30

	# Check for section start
	li		x29, 46			# Check for '.' ASCII 46.
	bne		x29, x30, no_dot
	li		x29, 1
	ret   

no_dot:
	li		x29, 0
	ret  

exit:
	li		x30, 0x100000		# QEMU Virt Test Device
	li		x29, 0x5555		# Shutdown command
	sw		x29, 0(x30)
        
final_spin:
	wfi
	j final_spin
data:
