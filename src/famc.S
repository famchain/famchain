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
# famc.s - fam compiler (asm impl)
# ──────────────────────────────────────────────────────────────────────────────
.equ DATA_OFFSET, (data - dataptr)
_start:
	jal		init_io

dataptr:
	auipc		gp, %hi(DATA_OFFSET)
	addi		gp, gp, %lo(DATA_OFFSET)
	li		sp, 1
	slli		sp, sp, 26
	add		sp, sp, gp
	andi		sp, sp, -16

	jal		read_data
	mv		a1, a0
	mv		a0, gp
	jal		pass1
	jal		write_data
	jal		exit


pass1:
	ret

read_data:
	mv		t0, ra
	li		t1, 4
	mv		t2, gp
read_loop:
	jal		read_byte
	beq		a0, t1, end_read_loop
	sb              a0, 0(t2)
	addi		t2, t2, 1
	j		read_loop
end_read_loop:
	mv		a0, t2
	mv		ra, t0
	ret

write_data:
	addi		sp, sp, -16		# reserve 16 bytes
	sd		ra, 0(sp)		# store ra
	sd		s0, 8(sp)		# store s0

	mv		s0, a0			# copy first arg to s0

	# Iterate through array
write_loop:	
	beq		s0, a1, end_write_loop	# exit when at end ptr
	lbu		a0, 0(s0)		# load next entry into arg
	jal		write_byte		# write value
	addi		s0, s0, 1		# move to next char
	j		write_loop		# repeat
end_write_loop:

	ld		ra, 0(sp)		# restore ra
	ld		s0, 8(sp)		# restore s0
	addi		sp, sp, 16		# free 16 bytes
	ret

read_byte:
	lbu		a0, 5(x4)		# Read from UART
	andi		a0, a0, 1		# mask
	beqz		a0, read_byte		# if not ready read again
	lbu		a0, 0(x4)		# Get current char, store x30
	ret

write_byte:             
	lbu		t0, 5(x4)
	andi		t0, t0, 0x20		# mask
	beqz		t0, write_byte		# retry
	sb		a0, 0(x4)		# send to UART
	ret

init_io:
	li		x4, 0x10000000		# UART base
	ret

exit:
	li		t0, 0x100000		# QEMU Virt Test Device
	li		t1, 0x5555		# Shutdown command
	sw		t1, 0(t0)

final_spin:
	wfi
	j		final_spin


data:

