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

	_start:
	li x4, 0x10000000  # UART base

# load heap and stack pointer
	dataptr:
	auipc x3, 0
addi  x3, x3, %lo(DATA_OFFSET)
	li    x2, 1
	slli  x2, x2, 26
	add   x2, x2, x3  # 64 MiB stack pointer/heap
	li    x5, 2048
	add   x5, x5, x3  # input buffer start
	mv    x6, x5   # input buffer end
li    x27, 10   # last char (end if .)

	capture_loop:
	jal  x1, read_uart           # read next char
	beqz x29, cont_capture       # not a dot, continue
	li   x28, 10
	beq  x27, x28, end_capture     # LF. termination
	li   x28, 13
	beq  x27, x28, end_capture     # CR. termination

	cont_capture:
	sb   x30, 0(x6)              # store in buffer
	addi x6, x6, 1               # advance capture pointer
	mv   x27, x30                 # set last char
	j    capture_loop            # repeat

	end_capture:
	jal x1, pass1               # first pass
	jal x1, output              # output data
	jal exit

# ──────────────────────────────────────────────────────────────────────────────
# Helper functions
# ──────────────────────────────────────────────────────────────────────────────

# Input: x5 beginning of input
# Input: x6 end of input
# Output: None
# Clobbers: x30, x29, x28
	pass1:
	mv x29, x5
	mv x30, x6
	mv x19, x1
	li x21, 0

	pass1_loop:
	beq  x29, x6, pass1_end_loop
lb   x28, 0(x29)
	addi x29, x29, 1

	li  x27, 35 # Check for '#'
	beq x27, x28, skip_comment

	li  x27, 58 # label :x
	beq x27, x28, proc_label

	li  x27, 106 # 'j'
	beq x27, x28, proc_jal

	jal  x1, is_hex_char
	beqz x26, pass1_loop

	beqz x21, high_nibble
	li   x21, 0
	or   x24, x24, x27
sb   x24, 0(x30)
	addi x30, x30, 1
	j    pass1_loop

	high_nibble:
	li   x21, 1
	slli x24, x27, 4
	li   x25, 1
	j    pass1_loop

	pass1_end_loop:
	mv x5, x29
	mv x6, x30
	mv x1, x19
	ret

	proc_label:
	beq  x29, x6, pass1_end_loop
lbu  x27, 0(x29)
	addi x29, x29, 1
	slli x27, x27, 3
	add  x27, x27, x3
sd   x30, 0(x27)
	j    pass1_loop

	proc_jal:
	jal x1, skip_whitespace
	beq x29, x6, pass1_end_loop
	jal x1, hex_to_int
	add x29, x29, 1
	jal x1, skip_whitespace

	slli x26, x11, 16        # Register to Byte 2
	slli x25, x27, 8         # Label to Byte 1
or   x26, x26, x25       # Combine (Byte 3 and 0 are already 0)

	sw   x26, 0(x30)         # Write the 4-byte Magic Word
	addi x30, x30, 4         # Advance buffer
	j    pass1_loop          # Next token

	j pass1_loop

	skip_comment:
	beq  x29, x6, pass1_end_loop
lb   x27, 0(x29)
	li   x28, 10
	beq  x28, x27, pass1_loop
	li   x28, 13
	beq  x28, x27, pass1_loop
	addi x29, x29, 1
	j    skip_comment

	skip_whitespace:
	beq  x29, x6, end_whitespace
lbu  x27, 0(x29)
	addi x29, x29, 1
	li   x28, 33
	blt  x27, x28, skip_whitespace

	end_whitespace:
	ret

# Input x28
# Output x26
# Ouptup x27 (hex value)
# Clobbers x26, x27, x28
	is_hex_char:
	mv   x27, x28
	addi x27, x27, -48
	li   x26, 10
	bltu x27, x26, is_hex
	addi x27, x27, -7
	li   x26, 10
	bltu x27, x26, not_hex
	li   x26, 16
	bltu x27, x26, is_hex

	not_hex:
	li x26, 0
	ret

	is_hex:
	li x26, 1
	ret

	hex_to_int:
	addi x11, x27, -48           # x11 = char - '0'
	li   x31, 10                 # Limit for digits
	bltu x11, x31, hex_done      # If 0-9, we are done

# If we are here, it's 'A'-'F' (or invalid)
# 'A' is 65. 65 - 48 = 17. We want 10, so subtract 7 more.
	addi x11, x11, -7            # x11 = char - 55

	hex_done:
	andi x11, x11, 0xF
	ret

	send_byte:
lbu  x28, 5(x4)
	andi x28, x28, 0x20          # mask
	beqz x28, send_byte # retry
	sb   x29, 0(x4)              # send to UART
	ret

# Input: x4 (UART base)
# Input: x5 beginning of input
# Input: x6 end of input
# Output: NONE
# Clobbers: x30, x29, x28
	output:
	mv x30, x5
	mv x20, x1

	output_loop:
	bge  x30, x6, end_output
lb   x10, 0(x30)
	addi x30, x30, 1
	bge  x30, x6, end_output
lb   x11, 0(x30)
	addi x30, x30, 1
	bge  x30, x6, end_output
lb   x12, 0(x30)
	addi x30, x30, 1
	bge  x30, x6, end_output
lb   x13, 0(x30)
	addi x30, x30, 1

	beqz x10, proc_patch

	li  x27, 4
	mv  x29, x10 # Send 4 bytes
	jal send_byte
	mv  x29, x11
	jal send_byte
	mv  x29, x12
	jal send_byte
	mv  x29, x13
	jal send_byte
	j   output_loop

	proc_patch:
	mv   x29,    x12          # Send first byte
	andi x14, x12, 1          # Get LSB
	slli x14, x14, 7          # Shift to bit 7
	li   x29, 0x6F
	or   x29, x29, x14
	jal  send_byte

        slli x11, x11, 3
        add x11, x11, x3
        ld x15, 0(x11)
	sub x15, x15, x30
	addi x15, x15, 4
	srli x15, x15, 1
	srli x16, x15, 11
	andi x16, x16, 0x0F
	slli x16, x16, 4

        srli    x14, x12, 1         # Shift right by 1
        andi    x14, x14, 0x0F      # Mask to keep only these 4 bits
        or      x29, x14, x16
        jal  send_byte

	li x29, 0
	jal  send_byte
	li   x29, 0x0
	jal  send_byte
	j    output_loop

	end_output:
	mv x1, x20
	ret

# Input: x4 (UART base)
# Output: x30 (unsigned char read) x29 (is_dot)
# Clobbers: x29
	read_uart:
	lbu  x30, 5(x4)              # Read from UART
	andi x30, x30, 1             # mask
	beqz x30, read_uart          # if not ready read again
	lbu  x30, 0(x4)              # Get current char, store x30

# Check for termination
	li  x29, 46 # Check for '.' ASCII 46.
	bne x29, x30, no_dot
	li  x29, 1
	ret

	no_dot:
	li x29, 0
	ret

# No inputs/Outputs/return
	exit:
	li x30, 0x100000          # QEMU Virt Test Device
	li x29, 0x5555            # Shutdown command
sw x29, 0(x30)

	final_spin:
	wfi
	j final_spin

	data:
