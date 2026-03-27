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
.option arch, +zicsr

# System hardware constants
.equ	EXIT_ADDR,		0x100000
.equ	EXIT_PASS,		0x5555
.equ	UART_BASE,		0x10000000
.equ	UART_RD_MASK,		0x1
.equ	UART_WR_MASK,		0x20
.equ	UART_LSR,		5
.equ	UART_RBR,		0
.equ	HEAP_MAX,		0x84000000		# 64MB limit from start of RAM
.equ	DISK_HART,		0			# Which hart handles disk interrupts
.equ	MAX_HARTS,		4
.equ	STACK_SHIFT, 		17			# 2^17 = 128 KiB
.equ	STACK_SIZE,		(1 << STACK_SHIFT)

.equ	VIO_DISK_BASE,		0x10001000
.equ	VIO_MAGIC,		0x000
.equ	VIO_DEVICE_ID,		0x008
.equ	VIO_STATUS,		0x070
.equ	VIO_QUEUE_SEL,		0x030
.equ	VIO_QUEUE_NUM,		0x038
.equ	VIO_QUEUE_PFN,		0x040

.equ	PLIC_BASE,		0x0c000000
.equ	PLIC_PRIO_10,		(PLIC_BASE + 0x28)	# 10 * 4 = 40 (0x28)
.equ	PLIC_MENABLE,		(PLIC_BASE + 0x2000)	# Machine Mode Enable
.equ	PLIC_MTHRESH,		(PLIC_BASE + 0x200000)	# Machine Mode Threshold
.equ	PLIC_MCLAIM,		(PLIC_BASE + 0x200004)	# Claim/Complete Register
.equ	DISK_IRQ,		1
.equ	PLIC_ENABLE_BASE,	0x0c002000
.equ	PLIC_MTHRESH_BASE,	0x0c200000
.equ	L_INTERS,		0x808			# MSIE (8) | MEIE (800)
.equ	MIE_GLOBAL,		0x8			# MIE (Global)
.equ	INTERRUPT_BIT,    0x80000000
.equ	M_SOFT_INT,       (INTERRUPT_BIT | 3)  # IPI (Software)
.equ	M_EXT_INT,        (INTERRUPT_BIT | 11) # External (PLIC/Disk)
.equ	IPI_CAUSE,		M_SOFT_INT # mcause for an IPI
.equ	EXTERNAL_CAUSE,		M_EXT_INT # Machine External Interrupt
.equ	IPI_BASE,		0x02000000		# Base of the IPI memory loc

# Disk structure
.equ	DISK_VIRTQ_AREA,	0
.equ	DISK_HEADER,		4096
.equ	DISK_BUFFER,		4112
.equ	DISK_STATUS,		4624

.macro LOAD_ADDRESS reg, label
_base\@:
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

.macro DECR_STACK	size
	addi sp, sp, -\size
	blt		sp, s11, stack_panic
.endm

.macro INCR_STACK	size
	addi		sp, sp, \size
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
	INCR_STACK \sz
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


	DECR_STACK _sz
	sw	ra, 0(sp)
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

.macro WRITE_BYTE	value
	li		t0, UART_BASE		# UART Base
101:	lbu		t1, UART_LSR(t0)	# load state
	andi		t1, t1, UART_WR_MASK	# mask
	beqz		t1, 101b		# retry
	li		t1, \value
	sb		t1, UART_RBR(t0)	# send to UART
.endm

_start:
j	main

pad: .space 12 # align trap handler 16

trap_handler:
	DECR_STACK	80
	sw		ra, 8(sp)
	sw		t0, 12(sp)
	sw		t1, 16(sp)
	sw		t2, 20(sp)
	sw		t3, 24(sp)
	sw		t4, 28(sp)
	sw		t5, 32(sp)
	sw		t6, 36(sp)

	sw		a0, 40(sp)
	sw		a1, 44(sp)
	sw		a2, 48(sp)
	sw		a3, 52(sp)
	sw		a4, 56(sp)
	sw		a5, 60(sp)
	sw		a6, 64(sp)
	sw		a7, 68(sp)

	li		a0, 'q'
	jal             write_byte

	csrr		t0, mstatus
	sw		t0, 4(sp)
	csrr		t0, mepc
	sw		t0, 0(sp)
	csrr		t0, mcause
	li		t1, IPI_CAUSE
	beq		t0, t1, ipi_handler
	li		t1, EXTERNAL_CAUSE
	beq		t0, t1, ext_handler
	csrr		t0, mepc
	addi		t0, t0, 4
	sw		t0, 0(sp)
	jal		proc_exception
	j		end_trap
ext_handler:
	li      t0, PLIC_MCLAIM
        # (Note: You need to add the hart offset if not on Hart 0)
        lw      t1, 0(t0)           # t1 now contains the IRQ number (e.g., 1)

        # 2. Check if it's the Disk
        li      t2, DISK_IRQ
        bne     t1, t2, end_trap
        
        # 3. Clear the VirtIO Device Event (The second half of the fix)
        # You MUST acknowledge the device itself
        li      t3, VIO_DISK_BASE
        lw      t4, 0x60(t3)        # Read InterruptStatus
        sw      t4, 0x64(t3)        # Write back to InterruptACK
	j		end_trap
ipi_handler:
	li		t0, IPI_BASE		# base
	slli		t1, tp, 2		# multiply by 4
	add		t0, t0, t1		# add to base
	sw		zero, 0(t0)		# zero the interrupt
	fence 		rw, rw
	jal		proc_ipi
end_trap:
	lw		t0, 0(sp)
	csrw		mepc, t0
	lw		t0, 4(sp)
	csrw		mstatus, t0
	lw		ra, 8(sp)
	lw		t0, 12(sp)
	lw		t1, 16(sp)
	lw		t2, 20(sp)
	lw		t3, 24(sp)
	lw		t4, 28(sp)
	lw		t5, 32(sp)
	lw		t6, 36(sp)

	lw		a0, 40(sp)
	lw		a1, 44(sp)
	lw		a2, 48(sp)
	lw		a3, 52(sp)
	lw		a4, 56(sp)
	lw		a5, 60(sp)
	lw		a6, 64(sp)
	lw		a7, 68(sp)
	INCR_STACK	80
	mret

stack_panic:
	WRITE_BYTE	's'
	WRITE_BYTE	't'
	WRITE_BYTE	'a'
	WRITE_BYTE	'c'
	WRITE_BYTE	'k'
	WRITE_BYTE	' '
	WRITE_BYTE	'o'
	WRITE_BYTE	'v'
	WRITE_BYTE	'e'
	WRITE_BYTE	'r'
	WRITE_BYTE	'f'
	WRITE_BYTE	'l'
	WRITE_BYTE	'o'
	WRITE_BYTE	'w'
	WRITE_BYTE	'!'
	WRITE_BYTE	'\n'
	j		exit

error_not_virtio:
	WRITE_BYTE	'n'
	WRITE_BYTE	'v'
	WRITE_BYTE	'i'
	WRITE_BYTE	'r'
	WRITE_BYTE	't'
	WRITE_BYTE	'\n'
	j		exit

error_not_disk:
	WRITE_BYTE	'e'
	WRITE_BYTE	'd' 
	WRITE_BYTE	'i'
	WRITE_BYTE	's'
	WRITE_BYTE	'k'
	WRITE_BYTE	'\n'
	j		exit

error_features_not_supported:
	WRITE_BYTE	'e'
	WRITE_BYTE	'f'	
	WRITE_BYTE	'e'	
	WRITE_BYTE	'a'
	WRITE_BYTE	't'	
	WRITE_BYTE	'u'
	WRITE_BYTE	'r'
	WRITE_BYTE	'e'
	WRITE_BYTE	'\n'
	j		exit	
	

proc_exception:
	mv t6, ra
	li a0, 'x'
	jal write_byte
	li a0, '0'
	add a0, a0, tp
	jal write_byte
	mv ra, t6
	ret

proc_ipi:
	li a0, 'y'
	jal write_byte
	li a0, '0'
	add a0, a0, tp
	jal write_byte
	ret

print_hex:
	SETUP		s0, s1, s2, t0, t1, t2, a0
	
	mv		s0, a0			# Save original value
	li		s2, 0			# flag = 0 (skipping leading)

	# Print "0x" prefix 
	li		a0, '0' 
	jal		write_byte
	li		a0, 'x'
	jal		write_byte	
	
	# Special Case: If value is 0, just print '0' and exit
	bnez		s0, 1f
	li		a0, '0'
	jal		write_byte
	j		4f

1:	li		s1, 28			# Start at highest nibble
2:
	srl		t2, s0, s1		# Isolate nibble
	andi		t2, t2, 0xF

	# Skip leading zeros logic
	bnez		t2, 3f			# If nibble != 0, start
	bnez		s2, 3f			# If already started, print
	j		next_nibble		# Otherwise, skip

3:	li		s2, 1			# Flip "started" flag

	# Convert nibble to ASCII
	li		a0, 10
	blt		t2, a0, 5f		# If 0-9
	addi		t2, t2, 7		# Adjust for A-F
5:	addi		a0, t2, 48		# ASCII '0'
	jal		write_byte

next_nibble:
	addi		s1, s1, -4		# Move to next 4 bits
	bgez		s1, 2b

4:	RETURN


write_byte:	
	SETUP		t0, t1
	li		t0, UART_BASE		# UART Base
1:	lbu		t1, UART_LSR(t0)	# load state
	andi		t1, t1, UART_WR_MASK	# mask
	beqz		t1, 1b			# retry
	sb		a0, UART_RBR(t0)	# send to UART
	RETURN

exit:
	li		t0, EXIT_ADDR		# load exit addr
	li		t1, EXIT_PASS		# shutdown command
	sw		t1, UART_RBR(t0)	# signal UART
1:	wfi					# wait for interrupt in loop
	j		1b

signal:
	li		t0, IPI_BASE		# Load base address
	slli		t1, a0, 2		# Multiply Hart ID by 4 (each MSIP is 32-bits)
	add		t0, t0, t1		# Final address for Target Core
	li		t1, 1		# Value to trigger
	sw		t1, 0(t0)		# Trigger the IPI

	ret

# a0 = Allocated Stack Base (where setup was done)
# a1 = Sector number to read
# s10 = VIO_MMIO_BASE

disk_read_sector:
    # 1. Update the Sector in the Header
    li      t2, DISK_HEADER
    add     t2, t2, a0
    sw      zero, 0(t2)           # Type = Read (0)
    sw      a1, 8(t2)             # Sector Low
    sw      zero, 12(t2)          # Sector High

    # 2. Reset Status Byte to "Busy"
    li      t3, DISK_STATUS
    add     t3, t3, a0
    li      t4, 0xFF
    sb      t4, 0(t3)

    # 3. Memory Barrier (Ensure the hardware sees the new sector/status)
    fence   w, w

    # 4. Notify the Hardware
    li      t2, 0                 # Queue Index 0
    sw      t2, 0x50(s10)         # Doorbell (VIO_QUEUE_NOTIFY)

    # 5. Polling Loop
wait_for_disk:
    lb      t2, 0(t3)
    li      t4, 0xFF
    beq     t2, t4, wait_for_disk # Loop while status is 0xFF
    
    # Check status: t2 should now be 0 for success
    ret


main:
	csrr		tp, mhartid
	li		t0, MAX_HARTS
	bge		tp, t0, park
	LOAD_ADDRESS	sp, data
	addi		sp, sp, 15
	andi		sp, sp, -16
	addi		t0, tp, 1
	slli		t0, t0, STACK_SHIFT
	add		sp, sp, t0
	li		s11, STACK_SIZE
	sub		s11, sp, s11

	li		a0, 't'
	jal		write_byte

	LOAD_ADDRESS	t0, trap_handler
	csrw		mtvec, t0
	slli		t1, tp, 12
	li		t0, PLIC_MTHRESH
	add		t0, t0, t1
	sw		zero, 0(t0)
	li		t0, L_INTERS
	csrs		mie, t0
	li		t0, MIE_GLOBAL
	csrs		mstatus, t0

	# Only enable for disk hart
	li		t0, DISK_HART
	bne		tp, t0, 1f
	li		t0, PLIC_BASE
	li		t1, 1			# Priority 1 (> Threshold)
	li		t2, DISK_IRQ
	slli		t2, t2, 2		# IRQ * 4 (4 bytes)
	add		t0, t0, t2
	sw		t1, 0(t0)

	# 2. Enable the Disk IRQ for THIS Hart specifically
	# M-Mode Enable contexts are spaced by 0x80 (128 bytes)
	csrr		t3, mhartid
	li		t0, PLIC_ENABLE_BASE
	slli		t2, t3, 7		# HartID * 128
	add		t0, t0, t2

	# Read-Modify-Write to enable Bit 1 (Disk)
	lw		t1, 0(t0)
	ori		t1, t1, (1 << DISK_IRQ)
	sw		t1, 0(t0)

	# 3. Ensure Threshold allows this priority
	# M-Mode Threshold contexts are spaced by 0x1000 (4096 bytes)
	li		t0, PLIC_MTHRESH_BASE
	slli		t2, t3, 12		# HartID * 4096
	add		t0, t0, t2
	sw		zero, 0(t0)		# Threshold 0 

	# Disk handshake
	li		t0, 12288		# Resreve 3 pages
	sub		sp, sp, t0
	blt		sp, s11, stack_panic	# Check allocation
	li		t0, 4095
	add		a0, t0, sp
	li		t0, -4096		# page align
	and		a0, a0, t0

	li	t0, 12288			# 3 pages
	add	t1, sp, t0			# t1 points to the END of the 3 pages
2:
	addi	t1, t1, -4			# Move pointer down first
	sw	zero, 0(t1)			# Zero it out
	bgt	t1, sp, 2b			# If we haven't reached the start (sp), keep going

	li	t0, VIO_DISK_BASE
	lw	t1, VIO_MAGIC(t0)		# Should be 0x74726976 ("virt")
	li	t2, 0x74726976
	bne	t1, t2, error_not_virtio
	lw	t1, VIO_DEVICE_ID(t0)		# Should be 2 for Block Device
	li	t2, 2
	bne	t1, t2, error_not_disk

	# 1. Reset the device
	sw	zero, VIO_STATUS(t0)

	# 2. Set ACKNOWLEDGE bit (1)
	li	t1, 1
	sw	t1, VIO_STATUS(t0)

	# 3. Set DRIVER bit (2)
	lw	t1, VIO_STATUS(t0)
	ori	t1, t1, 2
	sw	t1, VIO_STATUS(t0)

	# 4. Set FEATURES_OK bit (8)
	lw	t1, VIO_STATUS(t0)
	ori	t1, t1, 8
	sw	t1, VIO_STATUS(t0)

	# 5. Check if FEATURES_OK was accepted
	lw	t1, VIO_STATUS(t0)
	andi	t2, t1, 8
	beqz	t2, error_features_not_supported

        # Select Queue 0     
        sw      zero, VIO_QUEUE_SEL(t0)
        # Set Queue Size (let's use 16 descriptors)
        li      t1, 16   
        sw      t1, VIO_QUEUE_NUM(t0)

        srli    t1, a0, 12      
        sw      t1, VIO_QUEUE_PFN(t0)

	# Set DRIVER_OK bit (4) - Device is now "Live"
	lw	t1, VIO_STATUS(t0)
	ori	t1, t1, 4
	sw	t1, VIO_STATUS(t0)

	mv	t1, a0
	li	t2, DISK_HEADER
	add	t2, t2, t1

	sw	t2, 0(t1)		# Addr
	sw	zero, 4(t1)		# High 32 bits (MUST be zero for RV32)
	li	t2, 16
	sw	t2, 8(t1)		# Len
	li	t2, 1			# NEXT flag
	sh	t2, 12(t1)		# Flags
	li	t2, 1
	sh	t2, 14(t1)		# Next index = 1

	# Setup Descriptor 1 (Data Buffer)
	li	t2, DISK_BUFFER
	add	t2, t2, a0

	sw	t2, 16(t1)		# Addr (Table + 16)
	sw	zero, 20(t1)		# High 32 bits
	li	t2, 512
	sw	t2, 24(t1)		# Len
	li	t2, 3			# NEXT | WRITE flags
	sh	t2, 28(t1)		# Flags
	li	t2, 2
	sh	t2, 30(t1)		# Next index = 2


        # 3. Setup Descriptor 2 (Status Byte)
        li t2, DISK_STATUS
        add t2, t2, a0
        sw      t2, 32(t1)              # Addr (Table + 32)
	sw	zero, 36(t1)		# zero upper bits
        li      t2, 1
        sw      t2, 40(t1)              # Len
        li      t2, 2           	# WRITE flag
        sh      t2, 44(t1)              # Flags
        sh      zero, 46(t1)            # Next = 0 (End)

        # 4. Notify the Available Ring
        # Available Ring starts at offset 256 (after 16 descriptors)
        addi    t3, t1, 256
        sh      zero, 4(t3)               # Set ring[0] = 0 (Start at Desc 0)
        li      t2, 1
        sh      t2, 2(t3)               # Set idx = 1 (We have 1 chain ready)
	fence   w, w
1:

	bnez		tp, park

	li	s10, VIO_DISK_BASE
	li	a1, 0
	mv	s9, a0
	jal	print_hex
	mv	a0, s9
	#jal	disk_read_sector
	li      t2, DISK_BUFFER
        add     t2, t2, a0
	lb      a0, 0( t2)
	addi a0, a0, 'A'
	jal write_byte
	li a0, '\n'
	jal write_byte


	ebreak
	li		a0, 2
	jal		signal

park:
1:	wfi
	j		1b

data:
