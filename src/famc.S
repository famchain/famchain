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

.macro LOAD_ADDRESS reg, label
_base\@:
    # Uses \@ to make a unique constant name for every expansion
    .equ _offset\@, (\label - _base\@)
    auipc   \reg, %hi(_offset\@)
    addi    \reg, \reg, %lo(_offset\@)
.endm

.macro ALLOC_STACK size
	addi		sp, sp, -\size		# Allocate bytes on stack
	blt		sp, gp, stack_panic	# panic if stack overflow
	sd		ra, 0(sp)		# Always store ra
.endm

.macro DEALLOC_STACK size
	ld		ra, 0(sp)		# Restore ra
	addi		sp, sp, \size		# Deallocate bytes on stack
.endm

.macro BUMP_HEAP size
	addi		gp, gp, \size		# update gp
	bgt		gp, sp, stack_panic     # stack overflow
.endm

_start:
	jal		init_io

dataptr:
	LOAD_ADDRESS	gp data
	li		sp, 1
	slli		sp, sp, 26
	add		sp, sp, gp
	andi		sp, sp, -16

	jal		read_data
	jal		pass1

	jal		write_data
	jal		exit


pass1:
	ret

read_data:
	ALLOC_STACK	16
	sd		s0, 8(sp)		# store s0


	mv		s0, gp			# point to start of heap
read_loop:
	jal		read_byte		# call read byte
	li		t0, 4			# set to ASCII \004 (EOT)
	beq		a0, t0, end_read_loop	# exit if EOT
	sb              a0, 0(gp)		# save read byte
	BUMP_HEAP	1			# add one byte to heap ptr
	j		read_loop		# repeat
end_read_loop:
	mv		a0, s0			# return start of input
	mv		a1, gp                  # return end of input

	ld		s0, 8(sp)		# restore s0
	DEALLOC_STACK	16
	ret					# return

write_data:
	ALLOC_STACK	16
	sd		s0, 8(sp)		# store s0

	mv		s0, a0			# copy first arg to s0

	# Write a nop header (0x13, 0x00, 0x00, 0x00)
	li		a0, 0x13
	jal		write_byte
	li		a0, 0x00
	jal		write_byte
	jal		write_byte
	jal		write_byte


	# Iterate through array
1:	
	beq		s0, a1, 2f		# exit when at end ptr
	lbu		a0, 0(s0)		# load next entry into arg
	jal		write_byte		# write value
	addi		s0, s0, 1		# move to next char
	j		1b			# repeat
2:

	ld		s0, 8(sp)		# restore s0
	DEALLOC_STACK	16
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

print_str:
	mv		t1, a0
1:	lbu		t0, 0(t1)
	beqz		t0, 2f
	lbu		t2, 5(x4)		# check status
	andi		t2, t2, 0x20		# mask
	beqz		t2, write_byte		# retry
	sb		t0, 0(x4)		# send to UART
	addi		t1, t1, 1		# Next char
        j		1b			# Loop back
2:
	ret

stack_panic:
	LOAD_ADDRESS	a0, msg_stack_overflow
	jal		print_str
	j		exit

exit:
	li		t0, 0x100000		# QEMU Virt Test Device
	li		t1, 0x5555		# Shutdown command
	sw		t1, 0(t0)
1:
	wfi
	j		1b


msg_stack_overflow: .string "stack overflow!\n"
data:

