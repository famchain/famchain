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
# file: famchain.S - famchain full node
# ──────────────────────────────────────────────────────────────────────────────

.altmacro

# --- System Constants ---
.equ	UART_BASE,		0x10000000
.equ	UART_LSR,		5
.equ	UART_WR_MASK,		0x20
.equ	VIRTIO_DISK_BASE,	0x10001000	
.equ	VIO_MAGIC,		0x000
.equ	VIO_DEVICE_ID,		0x008
.equ	VIO_STATUS,		0x070

.equ	VIO_QUEUE_SEL,		0x030
.equ	VIO_QUEUE_NUM,		0x038
.equ	VIO_QUEUE_PFN,		0x040
.equ	VIRT_QUEUE0,		0x050
.equ	VIRT_MAGIC,		0x74726976
.equ	BIN_SIZE,		20

.equ	VIRT_DISK_BUFFER,	0
.equ	VIRT_DESCRIPTOR_TABLE,	512
.equ	VIRT_DISK_STATUS,	8704		# reserve space for 'used ring'
.equ	VIRT_DISK_HEADER,	8706
.equ	LOAD_LOC,		8722

.macro LOAD_ADDRESS reg, label
_base\@:
	# Uses \@ to make a unique constant name for every expansion
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

.macro LOAD_DATA reg tmp
	LOAD_ADDRESS \reg, data
	li \tmp, 4095
	add \reg, \reg, \tmp
	li \tmp, -4096
	and \reg, \reg, \tmp
	li \tmp, 3584
	add \reg, \reg, \tmp
.endm

.macro INIT_DISK
	li		t0, VIRTIO_DISK_BASE
	lw		t1, VIO_MAGIC(t0)		# Should be 0x74726976 ("virt")
	li		t2, VIRT_MAGIC
	bne		t1, t2, error_not_virtio

	lw		t1, VIO_DEVICE_ID(t0)		# Should be 2 for Block Device
	li		t2, 2
	bne		t1, t2, error_not_disk

	# Reset the device
	sw		zero, VIO_STATUS(t0)

	# Set ACKNOWLEDGE bit (1)
	li		t1, 1
	sw		t1, VIO_STATUS(t0)

	# Set DRIVER bit (2)
	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 2
	sw		t1, VIO_STATUS(t0)

	# Set FEATURES_OK bit (8)
	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 8
	sw		t1, VIO_STATUS(t0)

	# Check if FEATURES_OK was accepted
	lw		t1, VIO_STATUS(t0)
	andi		t2, t1, 8
	beqz		t2, error_features_not_supported

	# Set DRIVER_OK bit (4) - Device is now "Live"
	lw		t1, VIO_STATUS(t0)
	ori		t1, t1, 4
	sw		t1, VIO_STATUS(t0)

	# Select Queue 0
	sw		zero, VIO_QUEUE_SEL(t0)

	# Set Queue Size - 16
	li		t1, 16
	sw		t1, VIO_QUEUE_NUM(t0)

	# zero the buffer
	mv		t1, s10
	mv		t2, t1
	li		t3, LOAD_LOC
	add		t3, t3, t2

1:	
	sb		zero, 0(t2)
	addi		t2, t2, 1
	blt		t2, t3, 1b

	addi	t1, t1, VIRT_DESCRIPTOR_TABLE
	sw	t1, VIO_QUEUE_PFN(t0)
.endm


# a0 = sector
# a1 = counter
.macro READ_BLOCK
	mv		t0, s10
	addi		t1, t0, VIRT_DESCRIPTOR_TABLE	# t1 = Disk table
	li		t2, VIRT_DISK_HEADER		# t2 = Disk header
	add		t2, t2, t0
	li		t3, VIRT_DISK_STATUS
	add		t3, t3, t0			# t3 = Disk status

	sw		a1, 8(t2)

	sw		t2, 0(t1)			# Addr
	sw		zero, 4(t1)
	li		t4, 16
	sw		t4, 8(t1)			# Len
	li		t4, 1				# NEXT flag
	sh		t4, 12(t1)			# Flags
	sh		t4, 14(t1)



	# 2. Setup Descriptor 1 (Data Buffer)
	sw		t0, 16(t1)			# Addr
	sw		zero, 20(t1)

	li		t4, 512
	sw		t4, 24(t1)			# Len
	li		t4, 3				# NEXT | WRITE flags
	sh		t4, 28(t1)			# Flags
	li		t4, 2
	sh 		t4, 30(t1)			# Next index = 2


	sw		t3, 32(t1)			# Addr (Table + 32)
	sw		zero, 36(t1)
	li		t4, 1
	sw		t4, 40(t1)			# Len
	li		t4, 2				# WRITE flag
	sh		t4, 44(t1)			# Flags
	sh		zero, 46(t1)			# Next = 0 (End)


	# 4. Notify the Available Ring
	# Available Ring starts at offset 256 (after 16 descriptors)
	addi		t4, t1, 256		
	sh		zero, 4(t4)			# Set ring[0] = 0 (Start at Desc 0)
	sh		a0, 2(t4)			# Set idx

	li		t5, 0xFF
	sb		t5, 0(t3)

	# 5. Kick the hardware
	li		t5, VIRTIO_DISK_BASE		# VIRTIO_DISK_BASE
	sw		zero, VIRT_QUEUE0(t5)		# Notify Queue 0

	# 6. Wait for disk_status to change from 0xFF
	li		t5, 0xFF
1:	lbu		t4, 0(t3)
	beq		t4, t5, 1b
.endm

.set _macro_depth, 0

.macro _def_restore_macro depth, sz, regs:vararg
        .macro _do_tear_down_\depth
        .ifnc "\regs", ""
                .set _off, 8
                .irp reg, \regs
                lw \reg, _off(sp)
                .set _off, _off + 8
                .endr
        .endif
        lw ra, 0(sp)
        addi sp, sp, \sz
        .endm
.endm

.macro _exec_tear_down depth
        _do_tear_down_\depth
.endm

.macro _kill_tear_down depth
        .purgem _do_tear_down_\depth
.endm

# Macro to setup list of registers. Save all to stack
.macro SETUP regs:vararg
        .set _macro_depth, _macro_depth + 1

        .set _cnt, 1
        .ifnc "\regs", ""
        .irp item, \regs
                .set _cnt, _cnt + 1
        .endr
        .endif
        .set _sz, ((_cnt * 4) + 15) & -16

        _def_restore_macro %_macro_depth, %_sz, \regs


        addi sp, sp, -_sz
        sw      ra, 0(sp)
        .ifnc "\regs", ""
        .set _off, 4
        .irp reg, \regs
                sw \reg, _off(sp)
                .set _off, _off + 4
        .endr
        .endif
.endm

# Tear down the stack (LIFO order for stack frames)
.macro TEAR_DOWN
        _exec_tear_down %_macro_depth
        _kill_tear_down %_macro_depth
        .set _macro_depth, _macro_depth - 1
.endm

.macro RETURN
        TEAR_DOWN
        ret
.endm


_start:
	LOAD_DATA	s10, t0
	INIT_DISK

	li		s0, BIN_SIZE
	li		s1, 0
	li		s2, 1				# Total requests sent
	li		t0, LOAD_LOC
	mv		s5, s10
	add		s5, s5, t0

begin_loop:
	blez		s0, end_loop
	li		s4, 512

	mv		a1, s1
	mv		a0, s2 
	READ_BLOCK	
	addi		s2, s2, 1


	# Point to disk buffer
	mv		s3, s10
1:
	lbu		a0, 0(s3)			# Get next byte
	sb		a0, 0(s5)
	addi		s5, s5, 1
	addi		s3, s3, 1
	addi		s4, s4, -1
	addi		s0, s0, -1
	blez		s4, 2f
	blez		s0, 2f
	j		1b
2:

	addi		s1, s1, 1
	j		begin_loop
end_loop:

	li		t0, LOAD_LOC
	mv		s5, s10
	add		s5, s5, t0
	li		t0, BIN_SIZE
	add		s6, s5, t0
	li		s7, 0
1:
	lbu		a0, 0(s5)
	addi		s5, s5, 1
	addi		s7, s7, 1
	blt		s5, s6, 1b

	li		sp, 40000
	add		sp, sp, s10
	li		a0, 0x1235
	sw		a0, 0(sp)

	jal		chacha20_block
	mv		s9, sp

	lw		a0, 0(s9)
	jal		print_hex
	li		a0, '\n'
	jal		write_byte

        lw              a0, 4(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 8(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 12(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 16(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 20(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 24(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte


        lw              a0, 28(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 32(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 36(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte


        lw              a0, 40(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 44(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 48(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 52(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 56(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte

        lw              a0, 60(s9)
        jal             print_hex
        li              a0, '\n'
        jal             write_byte



	li		t0, LOAD_LOC
	mv		s5, s10
	add		s5, s5, t0
	fence		rw, rw				# Ensure writes
	jr		s5

3:	wfi
	j		3b

error_not_virtio:
	li		a0, '0'
	jal		write_byte
	li		a0, '\n'
100:	wfi
	j		100b

error_not_disk:
	li		a0, '1'
	jal		write_byte
	li		a0, '\n'
101:	wfi
	j		101b

error_features_not_supported:
	li		a0, '2'
	jal		write_byte
	li		a0, '\n'
102:	wfi
	j		102b

write_byte: 
	li		t1, UART_BASE
103:	lbu		t2, UART_LSR(t1)
	andi		t2, t2, UART_WR_MASK
	beqz		t2, 103b
	sb		a0, 0(t1)
	ret	

.macro QR_STEP a, b, d, rot
	add	\a, \a, \b
	xor	\d, \d, \a
	slli t0, \d, \rot	# t0 = d << rot
	srli \d, \d, (32 - \rot)	# d = d >> (32 - rot)
	or	\d, \d, t0		# d = (d << rot) | (d >> (32 - rot))
.endm

# chacha_qr:
# Input/Output: a0=a, a1=b, a2=c, a3=d
chacha_qr:
	# 1. Step 1 & 3 focus on (a, b, d)
	# 2. Step 2 & 4 focus on (c, d, b)
	QR_STEP a0, a1, a3, 16	# a += b; d ^= a; d <<< 16
	QR_STEP a2, a3, a1, 12	# c += d; b ^= c; b <<< 12
	QR_STEP a0, a1, a3, 8	# a += b; d ^= a; d <<< 8
	QR_STEP a2, a3, a1, 7	# c += d; b ^= c; b <<< 7
	ret

# Macro-like helper to load, call QR, and store
# This saves bytes by reusing the same loading logic
.macro DO_QR i0, i1, i2, i3
	lw	a0, \i0*4(sp)
	lw	a1, \i1*4(sp)
	lw	a2, \i2*4(sp)
	lw	a3, \i3*4(sp)
	jal	chacha_qr
	sw	a0, \i0*4(sp)
	sw	a1, \i1*4(sp)
	sw	a2, \i2*4(sp)
	sw	a3, \i3*4(sp)
.endm

chacha_round:
	mv	s11, ra		# Save return address

	# Column Rounds
	DO_QR 0, 4, 8, 12
	DO_QR 1, 5, 9, 13
	DO_QR 2, 6, 10, 14
	DO_QR 3, 7, 11, 15

	# Diagonal Rounds
	DO_QR 0, 5, 10, 15
	DO_QR 1, 6, 11, 12
	DO_QR 2, 7, 8, 13
	DO_QR 3, 4, 9, 14

	jr	s11	

chacha_rounds:
	mv		s2, ra
	li		s0, 0
	li		s1, 10
1:
	jal		chacha_round
	addi		s0, s0, 1
	blt		s0, s1, 1b
	jr		s2

# chacha20_block
# Input:  sp points to 64 bytes of initial state (Original)
# Output: sp-64 contains the 64-byte transformed block
# Registers used: t0-t5, s0-s2, s11 (via sub-calls)
chacha20_block:
    addi    sp, sp, -64     # Create space for the Working Copy
    mv      s3, ra          # Save return address to a saved register

    # --- Phase 1: Copy Original to Working ---
    # Original is now at 64(sp), Working is at 0(sp)
    addi    t3, sp, 64      # Source pointer (Original)
    addi    t4, sp, 0       # Destination pointer (Working)
    addi    t5, sp, 128     # End of Original block (64 + 64)
copy_loop:
    lw      t1, 0(t3)       # Load word from Original
    sw      t1, 0(t4)       # Store word to Working
    addi    t3, t3, 4       # Advance Original pointer
    addi    t4, t4, 4       # Advance Working pointer
    blt     t3, t5, copy_loop

    # --- Phase 2: Run 20 Rounds ---
    # chacha_rounds modifies the 64 bytes starting at 0(sp)
    jal     chacha_rounds

    # --- Phase 3: Add Original back to Working ---
    addi    t3, sp, 64      # Source pointer (Original)
    addi    t4, sp, 0       # Destination pointer (Working)
    addi    t5, sp, 128     # End trigger
add_back_loop:
    lw      t1, 0(t4)       # Get post-round word (Working)
    lw      t2, 0(t3)       # Get original word (Original)
    add     t1, t1, t2      # ChaCha20 Add: Result = Round(State) + State
    sw      t1, 0(t4)       # Update Working copy with final result
    addi    t3, t3, 4
    addi    t4, t4, 4
    blt     t3, t5, add_back_loop

    # --- Cleanup ---
    mv      ra, s3          # Restore return address
    ret                     # Result is now at 0(sp)

print_hex:
        SETUP           s0, s1, s2, t0, t1, t2, a0

        mv              s0, a0                  # Save original value
        li              s2, 0                   # flag = 0 (skipping leading)

        # Print "0x" prefix 
        li              a0, '0' 
        jal             write_byte
        li              a0, 'x'
        jal             write_byte 
        
        # Special Case: If value is 0, just print '0' and exit
        bnez            s0, 1f
        li              a0, '0'
        jal             write_byte
        j               4f

1:      li              s1, 28                  # Start at highest nibble
2:
        srl             t2, s0, s1              # Isolate nibble
        andi            t2, t2, 0xF

        # Skip leading zeros logic
        bnez            t2, 3f                  # If nibble != 0, start
        bnez            s2, 3f                  # If already started, print
        j               next_nibble             # Otherwise, skip

3:      li              s2, 1                   # Flip "started" flag

        # Convert nibble to ASCII
        li              a0, 10
        blt             t2, a0, 5f              # If 0-9
        addi            t2, t2, 7               # Adjust for A-F
5:      addi            a0, t2, 48              # ASCII '0'
        jal             write_byte

next_nibble:
        addi            s1, s1, -4              # Move to next 4 bits
        bgez            s1, 2b

4:      RETURN


data:
