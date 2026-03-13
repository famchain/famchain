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
	beqz		x28, zero_byte	  # pass through zero byte
	li		x10, 32			# load white space limit
	ble		x28, x10, pass1_loop	# skip whitespace
	li		x10, 35			# ASCII '#' (comments)
	beq		x28, x10, skip_comment	# skip comments
	li		x10, 58			# ASCII ':' (label)
	beq		x28, x10, proc_label    # process label
	li		x10, 106		# ASCII 'j' (jal)
	beq		x28, x10, proc_jal      # process jal
	li		x10, 98			# ASCII 'b' (branch)
	beq		x28, x10, proc_branch	# beq,bne,blt,bge,bltu,bgeu
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

zero_byte:
	sb		x28, 0(x30)
	addi		x30, x30, 1
	j		pass1_loop

pass1_end_loop:
	mv	      x5, x29		 # update start ptr to output
	mv	      x6, x30		 # update end ptr to output
	mv	      x1, x20		 # return address restore
	ret

# Parse branch instructions:
# beq 1 2 label
# bne 3 4 label
proc_branch:
	beq		x29, x6, pass1_end_loop
	lbu		x9, 0(x29)
	add		x29, x29, 1
	lbu		x7, 0(x29)
	add		x29, x29, 1
	jal		x1, skip_whitesp
	beq		x29, x6, pass1_end_loop
	jal		hex_to_int
	mv		x22, x11
	add		x29, x29, 1
	jal		x1, skip_whitesp
	beq		x29, x6, pass1_end_loop
	jal		hex_to_int
	mv		x23, x11
	add		x29, x29, 1
	jal		x1, skip_whitesp
	beq		x29, x6, pass1_end_loop
	add		x29, x29, 1
	li		x8, 101 # ASCII 'e'
	bne		x9, x8, skip_e
	li		x26, 0x88
	j		end_btype
skip_e:
	li		x8, 110 # ASCII 'n'
	bne		x9, x8, skip_n
	li		x26, 0x89
	j		end_btype
skip_n:
	li		x8, 108 # ASCII 'l'
	bne		x9, x8, skip_l
	li		x8, 117 # ASCII 'u'
	bne		x7, x8, skip_l_u
	li		x26, 0x8A
	j		end_btype
skip_l_u:
	li		x26, 0x8B
	j		end_btype
skip_l:
	li		x8, 103 # ASCII 'g'
	bne		x9, x8, skip_g
	li		x8, 117 # ASCII 'u'
	bne		x7, x8, skip_g_u
	li		x26, 0x8C
	j		end_btype
skip_g_u:
	li		x26, 0x8D
	j		end_btype
skip_g:
end_btype:

	# Shift rs1 (x22) to Byte 2
	slli		x25, x22, 8
	or		x26, x26, x25

	# Shift rs2 (x23) to Byte 3
	slli		x25, x23, 16
	or		x26, x26, x25

	slli		x27, x27, 24
	or		x26, x26, x27

	sw		x26, 0(x30)	 # Write the 4-byte Magic Word
	addi		x30, x30, 4
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

proc_label:
	bge		x29, x6, pass1_end_loop	# pass complete
	lbu		x27, 0(x29)		# read label
	addi		x29, x29, 1		# incr in iter
	slli		x27, x27, 3		# shift left for dw size
	add		x27, x27, x3		# point to table
	sub		x31, x30, x6		# subtract start ptr
	sd		x31, 0(x27)		# store cur offset
	j		pass1_loop

skip_comment:
	bge		x29, x6, pass1_end_loop	# pass complete
	lbu		x28, 0(x29)		# load byte
	addi		x29, x29, 1		# incr in iter
	li		x13, 10			# ASCII '\n'
	beq		x28, x13, end_comment   # newline
	li		x13, 13			# ASCII '\r'
	beq		x28, x13, end_comment	# cr
	j		skip_comment

end_comment:
	j	       pass1_loop

pass2:
	mv	      x29, x5
	mv	      x30, x6
	mv	      x20, x1
	li		x7, 0

pass2_loop:
	bge	     x29, x6, pass2_end_loop # pass complete
	lbu	     x28, 0(x29)	     # load byte
	addi	    x29, x29, 1	     # incr in iter

	bnez		x7, skip_data

	# Patching
	li		x10, 0x80
	beq		x28, x10, proc_patch_jal
	li		x10, 0x88
	blt		x28, x10, skip_branch_patch
	li		x10, 0x8F
	bge		x28, x10, skip_branch_patch
	j		proc_patch_branch
skip_branch_patch:

	bnez		x28, skip_data
	li		x7, 1
	j		pass2_loop
skip_data:
	sb	      x28, 0(x30)
	addi	    x30, x30, 1

	bge	     x29, x6, pass2_end_loop # pass complete
	lbu	     x28, 0(x29)	     # load byte
	addi	    x29, x29, 1	     # incr in iter
	sb	      x28, 0(x30)
	addi	    x30, x30, 1

	bge	     x29, x6, pass2_end_loop # pass complete
	lbu	     x28, 0(x29)	     # load byte
	addi	    x29, x29, 1	     # incr in iter
	sb	      x28, 0(x30)
	addi	    x30, x30, 1

	bge	     x29, x6, pass2_end_loop # pass complete
	lbu	     x28, 0(x29)	     # load byte
	addi	    x29, x29, 1	     # incr in iter
	sb	      x28, 0(x30)
	addi	    x30, x30, 1

	j		pass2_loop

pass2_end_loop:
	mv	      x5, x29		 # update start ptr to output
	mv	      x6, x30		 # update end ptr to output
	mv	      x1, x20		 # return address restore
	ret

proc_patch_branch:
	lbu		x11, 0(x29)
	lbu		x12, 1(x29)
	lbu		x13, 2(x29)
	sb		x28, 0(x30)
	sb		x11, 1(x30)
	sb		x12, 2(x30)
	sb		x13, 3(x30)
	addi		x30, x30, 4
	addi		x29, x29, 3


	j		pass2_loop

proc_patch_jal:
	bge	     x29, x6, pass2_end_loop # pass complete
	lbu	     x11, 0(x29)	     # load byte
	addi		x29, x29, 1
	bge	     x29, x6, pass2_end_loop # pass complete
	lbu	     x12, 0(x29)	     # load byte
	addi	    x29, x29, 1
	bge	     x29, x6, pass2_end_loop # pass complete
	addi		x29, x29, 1


	slli		x11, x11, 3
	add		x11, x11, x3
	ld		x15, 0(x11)
	sub		x31, x30, x6
	sub		x15, x15, x31
	li		x21, 0x1FFFFF		# 21-bit mask 
	and		x15, x15, x21      

	srli    x15, x15, 1	 # Discard bit 0 (always zero)

	# ─────────────────────────────────────────────────────────────
	# BYTE 0: [rd[0] | opcode[6:0]]
	# ─────────────────────────────────────────────────────────────
	andi		x14, x12, 0x01		# Get bit 0 of rd
	slli		x14, x14, 7		# Move to bit 7
	li		x31, 0x6F		# JAL opcode
	or		x31, x31, x14
	sb		x31, 0(x30)
	addi		x30, x30, 1

	# ─────────────────────────────────────────────────────────────
	# BYTE 1: [imm[15:12] | rd[4:1]]
	# Note: imm[15:12] in the instruction are bits 14:11 of our x15
	# ─────────────────────────────────────────────────────────────
	srli		x14, x12, 1		# Get bits 4:1 of rd
	andi		x14, x14, 0x0F		# Mask to 4 bits
	srli		x16, x15, 11		# Get imm[15:12] from x15
	andi		x16, x16, 0x0F		# Mask to 4 bits
	slli		x16, x16, 4		# Move to bits 7:4
	
	or		x31, x14, x16
	sb		x31, 0(x30)
	addi		x30, x30, 1

	# ─────────────────────────────────────────────────────────────
	# BYTE 2: [imm[3:1] | imm[11] | imm[19:16]]
	# Note: mapped from x15 bits [2:0], [10], [18:15]
	# ─────────────────────────────────────────────────────────────
	srli		x14, x15, 15		# Get imm[19:16]
	andi		x14, x14, 0x0F		# Mask to 4 bits (bottom)
	
	srli		x16, x15, 10		# Get imm[11]
	andi		x16, x16, 0x01		# Mask 1 bit
	slli		x16, x16, 4		# Move to bit 4
	
	andi		x12, x15, 0x07		# Get imm[3:1]
	slli		x12, x12, 5		# Move to bits 7:5
	
	or		x31, x14, x16
	or		x31, x31, x12
	sb		x31, 0(x30)
	addi		x30, x30, 1

	# ─────────────────────────────────────────────────────────────
	# BYTE 3: [imm[20] | imm[10:4]]
	# Note: mapped from x15 bits [19], [9:3]
	# ─────────────────────────────────────────────────────────────
	srli		x14, x15, 3		# Get imm[10:4]
	andi		x14, x14, 0x7F		# Mask 7 bits
	
	srli		x16, x15, 19		# Get imm[20] (Sign bit)
	andi		x16, x16, 0x01		# Mask 1 bit
	slli		x16, x16, 7		# Move to bit 7
	
	or		x31, x14, x16
	sb		x31, 0(x30)
	addi		x30, x30, 1
	j		pass2_loop


capture:
	mv		x20, x1
	li		x12, 10			# last byte
capture_loop:
	jal		read_byte
	li		x21, 46			# Load ASCII '.'
	bne		x30, x21, not_end
	li		x21, 10
	beq		x12, x21, test_e
	li		x21, 13
	beq		x12, x21, test_e
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
	mv		x12, x30		# Update last byte
	j		capture_loop
end_capture:
	mv		x1, x20
	ret

output:
	mv		x20, x1
output_loop:
	bge		x5, x6, end_output
	lbu		x29, 0(x5)
	mv		x31, x29
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
	beqz		x27, end_whitesp
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
	sb		x31, 0(x4)		# send to UART
	ret

exit:
	li		x30, 0x100000		# QEMU Virt Test Device
	li		x29, 0x5555		# Shutdown command
	sw		x29, 0(x30)

final_spin:
	wfi
	j		final_spin

data:

