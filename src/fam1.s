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

	li x27, 98 # 'b'
	beq x27, x28, proc_branch

	li  x27, 106 # 'j'
	beq x27, x28, proc_jal

	li x27, 108 # 'l'
	beq x27, x28, proc_la

	li x27, 115 # 's'
	beq x27, x28, proc_store

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

	proc_la:
	jal x1, skip_whitespace
        beq x29, x6, pass1_end_loop
        jal hex_to_int
	mv x22, x11
        add x29, x29, 1
	jal x1, skip_whitespace
        beq x29, x6, pass1_end_loop
	add x29, x29, 1

	li x26, 0x87
        slli x25, x22, 8
        or   x26, x26, x25

        slli x25, x27, 16
        or   x26, x26, x25

	sw   x26, 0(x30)
        addi x30, x30, 4

	li x26, 0
	sw   x26, 0(x30)
        addi x30, x30, 4

	j pass1_loop

	proc_store:
	beq  x29, x6, pass1_end_loop
	lbu  x7, 0(x29)
	addi x29, x29, 1

	jal x1, skip_whitespace
        beq x29, x6, pass1_end_loop
        jal hex_to_int
	mv x22, x11
	add x29, x29, 1
	jal x1, skip_whitespace
        beq x29, x6, pass1_end_loop
        jal hex_to_int
        mv x23, x11
	add x29, x29, 1

	li x26, 0x86


        # Shift rs1 (x22) to Byte 2
        slli x25, x22, 8
        or   x26, x26, x25

        # Shift rs2 (x23) to Byte 3
        slli x25, x23, 16
        or   x26, x26, x25

	addi x7, x7, -48
        slli x25, x7, 24
        or   x26, x26, x25


	sw   x26, 0(x30)         # Write the 4-byte Magic Wor
        addi x30, x30, 4
	li x26, 0
	sw   x26, 0(x30)
	addi x30, x30, 4

	j pass1_loop

	proc_label:
	beq  x29, x6, pass1_end_loop
lbu  x27, 0(x29)
	addi x29, x29, 1
	slli x27, x27, 3
	add  x27, x27, x3
sd   x30, 0(x27)
	j    pass1_loop

	proc_branch:
	beq  x29, x6, pass1_end_loop
	lbu  x9, 0(x29)
	add x29, x29, 1
	lbu  x7, 0(x29) 
	add x29, x29, 1
	jal x1, skip_whitespace
        beq x29, x6, pass1_end_loop
	jal hex_to_int
	mv x22, x11
	add x29, x29, 1
	jal x1, skip_whitespace
	beq x29, x6, pass1_end_loop
	jal hex_to_int
	mv x23, x11
        add x29, x29, 1
	jal x1, skip_whitespace
	beq x29, x6, pass1_end_loop
	add x29, x29, 1


	li x8, 101 # ASCII 'e'
	bne x9, x8, skip_e
        li   x26, 0x80
	j end_btype
skip_e:
	li x8, 110 # ASCII 'n'
	bne x9, x8, skip_n
	li x26, 0x81
	j end_btype
skip_n:
        li x8, 108 # ASCII 'l'
        bne x9, x8, skip_l
	li x8, 117 # ASCII 'u'
	bne x7, x8, skip_l_u
	li x26, 0x84
	j end_btype	
	skip_l_u:
        li x26, 0x82
        j end_btype
skip_l:
        li x8, 103 # ASCII 'g'
        bne x9, x8, skip_g

	li x8, 117 # ASCII 'u'
        bne x7, x8, skip_g_u
        li x26, 0x85
        j end_btype
        skip_g_u:
        li x26, 0x83
        j end_btype
skip_g:
end_btype:
	
        # Shift rs1 (x22) to Byte 2
        slli x25, x22, 8 
        or   x26, x26, x25
        
        # Shift rs2 (x23) to Byte 3
        slli x25, x23, 16 
        or   x26, x26, x25

	slli x27, x27, 24
	or   x26, x26, x27

	sw   x26, 0(x30)         # Write the 4-byte Magic Wor
	addi x30, x30, 4
	j pass1_loop


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
	lbu   x10, 0(x30)
	addi x30, x30, 1
	bge  x30, x6, end_output
	lbu   x11, 0(x30)
	addi x30, x30, 1
	bge  x30, x6, end_output
	lbu   x12, 0(x30)
	addi x30, x30, 1
	bge  x30, x6, end_output
	lbu   x13, 0(x30)
	addi x30, x30, 1

	beqz x10, proc_patch_jal
	li x8, 0
	li x29, 0x80
	beq x10, x29, proc_patch_branch
	addi x8, x8, 1
	li x29, 0x81
        beq x10, x29, proc_patch_branch
	addi x8, x8, 3
        li x29, 0x82
        beq x10, x29, proc_patch_branch
	addi x8, x8, 1
        li x29, 0x83
        beq x10, x29, proc_patch_branch
 	addi x8, x8, 1
        li x29, 0x84
        beq x10, x29, proc_patch_branch
 	addi x8, x8, 1
        li x29, 0x85
        beq x10, x29, proc_patch_branch
	li x29, 0x86
	beq x10, x29, proc_patch_store
	li x29, 0x87
	beq x10, x29, proc_patch_la


	li  x27, 4
	mv  x29, x10 
	jal send_byte
	mv  x29, x11
	jal send_byte
	mv  x29, x12
	jal send_byte
	mv  x29, x13
	jal send_byte
	j   output_loop


proc_patch_la:
        # 1. LOOKUP LABEL
	slli    x12, x12, 3         # Label * 8
	add     x12, x12, x3        # x3 = Label Table Base
	ld      x15, 0(x12)         # x15 = Target Address

	# 2. CALCULATE OFFSET
	sub     x15, x15, x30       # Target - PC
	addi    x15, x15, 4         # Adjust for PC already advanced by 8
	mv      x9, x15

	li      x31, 2048           # The "Carry" constant
	add     x15, x15, x31       # offset + 2048
	srli    x15, x15, 12        # x15 = imm20 (The Page Number)


	# Build the word: [imm20 << 12] | [rd << 7] | 0x17
	slli    x16, x15, 12        # imm20 to top bits
	slli    x17, x11, 7         # rd to bit 7
	or      x16, x16, x17       # Combine
	ori     x16, x16, 0x17      # Add AUIPC Opcode

	# Send 4 bytes (Little Endian)
	mv      x29, x16
	jal     send_byte           # Byte 0
	srli    x29, x16, 8
	jal     send_byte           # Byte 1
	srli    x29, x16, 16
	jal     send_byte           # Byte 2
	srli    x29, x16, 24
	jal     send_byte           # Byte 3

	#li x29, 0
	#jal send_byte
        #li x29, 0
        #jal send_byte
        #li x29, 0
        #jal send_byte
        #li x29, 0
        #jal send_byte

        # --- ENCODE ADDI ---
        # 1. Mask strictly to the lower 12 bits of the raw offset
        li      x31, 0xFFF
        and     x16, x9, x31        # x16 = imm12 (Fine adjustment)

        # 2. Build ADDI Word: [imm12 << 20] | [rs1 << 15] | [rd << 7] | 0x13
        # rs1 (x18) and rd (x17) are BOTH the target register (x11)
        slli    x17, x16, 20        # imm12 -> bits 31:20
        slli    x18, x11, 15        # rs1 = destination register
        or      x17, x17, x18
        # funct3 is 000 (bits 14:12), no OR needed
        slli    x18, x11, 7         # rd = destination register
        or      x17, x17, x18
        ori     x17, x17, 0x13      # Opcode 0x13 (OP-IMM)

        # 3. Send 4 bytes (Little Endian)
        mv      x29, x17
        jal     send_byte           # Byte 0 (13)
        srli    x29, x17, 8
        jal     send_byte           # Byte 1 (rd/part of imm)
        srli    x29, x17, 16
        jal     send_byte           # Byte 2 (rs1/part of imm)
        srli    x29, x17, 24
        jal     send_byte           # Byte 3 (top of imm)


        j   output_loop


# Input:
# x11 - rs2 (Data)
# x12 - rs1 (Base Pointer)
# x13 - size (1=sb, 2=sh, 4=sw, 8=sd)

proc_patch_store:
    # --- STEP 1: Determine funct3 from size ---
    li      x14, 0              # Default sb (0x0)
    li      x15, 2
    beq     x13, x15, set_sh    # if 2 -> sh
    li      x15, 4
    beq     x13, x15, set_sw    # if 4 -> sw
    li      x15, 8
    beq     x13, x15, set_sd    # if 8 -> sd
    j       encode              # else sb
set_sh: li x14, 1; j encode
set_sw: li x14, 2; j encode
set_sd: li x14, 3

encode:
    # --- BYTE 0: Opcode ---
    # Bits 6:0 = 0100011 (0x23). Bit 7 = imm[0] (0).
    li      x29, 0x23
    jal     send_byte

    # --- BYTE 1: [rs1[0]] [funct3] [imm 4:1] ---
    # imm[4:1] is 0000. funct3 (x14) is at bits 6:4. rs1[0] is at bit 7.
    andi    x29, x12, 1         # Get LSB of rs1
    slli    x29, x29, 7         # Move to bit 7
    slli    x15, x14, 4         # Move funct3 to bits 6:4
    or      x29, x29, x15
    jal     send_byte

    # --- BYTE 2: [rs2[3:0]] [rs1[4:1]] ---
    # rs1[4:1] moved to bits 3:0. rs2[3:0] moved to bits 7:4.
    srli    x29, x12, 1         # rs1 bits 4:1
    andi    x15, x11, 0xF       # rs2 bits 3:0
    slli    x15, x15, 4         # Move to bits 7:4
    or      x29, x29, x15
    jal     send_byte

    # --- BYTE 3: [imm 11:5] [rs2[4]] ---
    # imm is 0. rs2[4] is bit 0. (For x0-x15, bit 4 is 0).
    srli    x29, x11, 4         # Get bit 4 of rs2 (0 if x < 16)
    jal     send_byte

    j       output_loop 


proc_patch_branch:
    # 1. LOOKUP LABEL
    slli    x13, x13, 3         # Label * 8
    add     x13, x13, x3        # x3 = Label Table Base
    ld      x15, 0(x13)         # x15 = Target Address

    # 2. CALCULATE OFFSET
    sub     x15, x15, x30       # Target - PC
    addi    x15, x15, 4         # Adjust for PC already advanced by 4
    srai    x15, x15, 1         # Hardware offset = (Target-PC) >> 1

    # --- STITCH BYTE 0 ---
    # [Imm 11][Opcode 0x63]
    li      x29, 0x63           # BEQ Opcode
    srli    x14, x15, 10        # Bit 11 is at pos 10
    andi    x14, x14, 1         # Isolate Bit 11
    slli    x14, x14, 7         # Move to bit 7
    or      x29, x29, x14
    jal     send_byte

    # --- STITCH BYTE 1 ---
    # Byte 1 structure: [rs1 bit 0 (pos 7)] [funct3 (pos 6:4)] [imm 4:1 (pos 3:0)]

    andi    x29, x15, 0x0F      # Extract Imm[4:1] (at pos 3:0)
    
    # Process funct3 (passed in x8)
    andi    x14, x8, 0x07       # Mask funct3 to ensure only 3 bits
    slli    x14, x14, 4         # Shift funct3 to positions 6:4
    or      x29, x29, x14       # Merge into x29
    
    # Process rs1
    slli    x14, x11, 7         # rs1 bit 0 -> bit 7 of the byte
    or      x29, x29, x14       # Final merge
    
    jal     send_byte           # Send the assembled Byte 1


    # --- STITCH BYTE 2 ---
    # Inst Bits 23:16 -> [rs2 bits 3:0][rs1 bits 4:1]
    srli    x29, x11, 1         # Get rs1 bits 4:1
    andi    x29, x29, 0x0F
    slli    x14, x12, 4         # rs2 bits 3:0 -> top nibble
    or      x29, x29, x14
    jal     send_byte

    # --- STITCH BYTE 3 ---
    # Inst Bits 31:24 -> [Imm 12][Imm 10:5][rs2 bit 4]
    srli    x29, x12, 4         # rs2 bit 4 -> bit 0
    andi    x29, x29, 1
    
    srli    x14, x15, 4         # Imm bits 10:5 (at pos 9:4)
    andi    x14, x14, 0x3F      # Mask 6 bits
    slli    x14, x14, 1         # Shift to bits 6:1
    or      x29, x29, x14
    
    srli    x14, x15, 11        # Imm bit 12 (Sign)
    andi    x14, x14, 1
    slli    x14, x14, 7         # Shift to bit 7
    or      x29, x29, x14
    jal     send_byte

    j       output_loop

	proc_patch_jal:
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

        andi    x14, x15, 0x07      # Get 3 bits
        slli    x14, x14, 5         # Shift to top of byte (7:5)

        # 2. Offset bit 11 -> Byte bit 4
        # (In x15, bit 11 is at bit 10)
        srli    x16, x15, 10
        andi    x16, x16, 0x01      # Get bit 11
        slli    x16, x16, 4         # Move to bit 4

        # 3. Offset bits 19:16 -> Byte bits 3:0
        # (In x15, bit 16 is at bit 15)
        srli    x17, x15, 15
        andi    x17, x17, 0x0F      # Get 4 bits

        # 4. Combine and Send
        or      x29, x14, x16
        or      x29, x29, x17

	jal  send_byte

    srli    x14, x15, 3
    andi    x14, x14, 0x7F      # Mask 7 bits

    # 2. Offset bit 20 (Sign bit) -> Byte bit 7
    # (In x15, bit 20 is at bit 19)
    srli    x16, x15, 19
    andi    x16, x16, 0x01      # Get bit 20
    slli    x16, x16, 7         # Move to bit 7

    # 3. Combine and Send
    or      x29, x14, x16

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
