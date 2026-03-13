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
	li		x21, 0			# set low nibble

pass1_loop:
	bge		x29, x6, pass1_end_loop # pass complete
	lbu		x28, 0(x29)		# load byte
	addi		x29, x29, 1		# incr in iter
	li		x10, 32			# load white space limit
	ble		x28, x10, pass1_loop	# skip whitespace
	li		x10, 35			# ASCII '#' (comments)
	beq		x28, x10, skip_comment	# skip comments
	li		x10, 58			# ASCII ':' (label)
	beq		x28, x10, proc_label    # process label
	li		x10, 106		# ASCII 'j' (jal)
	beq		x28, x10, proc_jal      # process jal

	jal		x1, is_hex_char		# check if its hex
	beqz		x26, pass1_loop		# skip

	# Hex encoding
	beqz		x21, high_nibble
	li		x21, 0
	or		x24, x24, x27
	sb		x24, 0(x30)
	addi		x30, x30, 1
	j		pass1_loop

high_nibble:
	li		x21, 1
	slli		x24, x27, 4
	li		x25, 1
	j		pass1_loop


# Parse jal. Format: j<rd> <label>
# e.g. j1 x # jump to label :x storing ra in x1
proc_jal:
	bge		x29, x6, pass1_end_loop	# pass complete
	lbu		x27, 0(x29)		# load byte
	jal		hex_to_int		# read hex digit
	addi		x29, x29, 1		# incr in iter
	jal		skip_whitesp		# skip whitespace
	addi		x29, x29, 1		# incr in iter
	slli		x26, x11, 16		# Register to Byte 2
	slli		x25, x27, 8		# Label to Byte 1
	or		x26, x26, x25		# Combine
	li		x25, 0x80		# Load sentinel
	or		x26, x26, x25		# Combine
	sw		x26, 0(x30)		# Write the data
	addi		x30, x30, 4		# incr out iter
	j		pass1_loop

pass1_end_loop:
	mv		x5, x29			# update start ptr to output
	mv		x6, x30			# update end ptr to output
	mv		x1, x20			# return address restore
	ret

proc_label:
	bge	     x29, x6, pass1_end_loop # pass complete
	lbu	     x27, 0(x29)	     # read label
	addi	    x29, x29, 1	     # incr in iter
	add	     x27, x27, x3	    # point to table
	sd	      x30, 0(x27)	     # store cur offset
	j	       pass1_loop

skip_comment:
	bge	     x29, x6, pass1_end_loop # pass complete
	lbu	     x28, 0(x29)	     # load byte
	addi	    x29, x29, 1	     # incr in iter
	li	      x13, 10		 # ASCII '\n'
	beq	     x28, x13, end_comment   # newline
	li	      x13, 13		 # ASCII '\r'
	beq	     x28, x13, end_comment   # cr
	j	       skip_comment

end_comment:
	j	       pass1_loop


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

skip_whitesp:
	bge	     x29, x6, end_whitesp
	lbu	     x27, 0(x29)
	addi	    x29, x29, 1
	li	      x28, 33
	blt	     x27, x28, skip_whitesp # repeat

end_whitesp:
	ret

is_hex_char:
	mv		x27, x28
	addi		x27, x27, -48
	li		x26, 10
	bltu		x27, x26, is_hex
	addi		x27, x27, -7
	li		x26, 10
	bltu		x27, x26, not_hex
	li		x26, 16
	bltu		x27, x26, is_hex

not_hex:
	li x26, 0 
	ret  

is_hex:
	li x26, 1
	ret


hex_to_int:
	addi	    x11, x27, -48	   # x11 = char - '0'
	li	      x31, 10		 # Limit for digits
	bltu	    x11, x31, hex_done      # If 0-9, we are done
	addi	    x11, x11, -7	    # x11 = char - 55

hex_done:
	andi	    x11, x11, 0xF	   # wipe out illegal bits
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

