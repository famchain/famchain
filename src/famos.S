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
# famcos.S - fam operating system (GNU as src)
# ──────────────────────────────────────────────────────────────────────────────

# System Constants
.equ	UART_BASE,	0x10000000
.equ	UART_RD_MASK,	0x1
.equ	UART_WR_MASK,	0x20
.equ	UART_LSR,	5
.equ	UART_RBR,	0
.equ    PLIC_BASE,    0x0c000000
.equ    PLIC_PRIO_10, (PLIC_BASE + 0x28)     # 10 * 4 = 40 (0x28)
.equ    PLIC_MENABLE, (PLIC_BASE + 0x2000)   # Machine Mode Enable
.equ    PLIC_MTHRESH, (PLIC_BASE + 0x200000) # Machine Mode Threshold
.equ    PLIC_MCLAIM,  (PLIC_BASE + 0x200004) # Claim/Complete Register


.macro ALLOC_STACK      size
        addi            sp, sp, -\size          # Allocate bytes on stack
        blt             sp, gp, stack_panic     # panic if stack overflow
        sd              ra, 0(sp)               # Always store ra
.endm

.macro DEALLOC_STACK size
        ld              ra, 0(sp)               # Restore ra
        addi            sp, sp, \size           # Deallocate bytes on stack
.endm

.macro BUMP_HEAP        size
        addi            gp, gp, \size           # update gp
        bgt             gp, sp, stack_panic     # stack overflow
.endm

.macro LOAD_ADDRESS reg, label
_base\@:
	.equ _offset\@, (\label - _base\@)
	auipc \reg, %hi(_offset\@)
	addi \reg, \reg, %lo(_offset\@)
.endm

_start:
	LOAD_ADDRESS    t0 boot_lock
        li              t1, 1
        amoadd.w.aq     tp, t1, (t0)

        # --- NEW LOGIC: Save the Winner's ID ---
        bnez            tp, skip_save_winner   # Only the Hart that got '0' continues
        csrr            t0, mhartid            # Get the physical Hart ID
        LOAD_ADDRESS    t1, uart_owner_id      # Point to our global variable
        sw              t0, 0(t1)              # Store it permanently
skip_save_winner:
        # --- END NEW LOGIC ---

	LOAD_ADDRESS    t0, trap_handler
	csrw		mtvec, t0

	jal		init_plic

        li		t0, 0x808       # 0x800 (External) + 0x008 (Software)
        csrs		mie, t0
    	li              t0, 8           # MIE (Global Interrupt Enable)
    	csrs            mstatus, t0


	# Enable UART Hardware Interrupts (IER)
	li              t0, UART_BASE
	li              t1, 1           # Received Data Available
	sb              t1, 1(t0)


	ebreak

	jal main
1:	wfi
	j 1b

init_plic:
	li	t0, PLIC_PRIO_10
	li	t1, 1
	sw	t1, 0(t0)

	slli	t2, a0, 7
	bnez	tp, skip_enable

	li      t0, PLIC_MENABLE
	add     t0, t0, t2  
	li      t1, (1 << 10)
	sw      t1, 0(t0) 

skip_enable:
	# All cores must set threshold to 0 to accept ANY interrupts
	li      t0, PLIC_MTHRESH
	add     t0, t0, t2
	sw      x0, 0(t0)
	ret

write_byte:
        li              t0, UART_BASE
1:
        lbu             t1, UART_LSR(t0)
        andi            t1, t1, UART_WR_MASK    # mask
        beqz            t1, 1b                  # retry
        sb              a0, UART_RBR(t0)        # send to UART
        ret

.align 4
trap_handler:
	li	a0, 'a'
	add	a0, a0, tp
	jal	write_byte
	csrr    t0, mcause
	bltz	t0, handle_int

	csrr	t1, mepc
	addi	t1, t1, 4 # advance past ebreak
	csrw	mepc, t1
	mret

handle_int:
	csrr	t0, mcause
	slli	t1, t0, 1
	srli	t1, t1, 1

        # --- CHANGE STARTS HERE ---
        # Instead of getting the current hart's ID, get the winner's ID
        LOAD_ADDRESS t0, uart_owner_id
        lw      t1, 0(t0)           # t1 = The ID of the winner (saved at boot)

        # Calculate the PLIC mailbox for THAT winner
        li      t0, 0x0c200004      # PLIC Context 0 Base
        slli    t1, t1, 12          # HartID * 4096 (0x1000)
        add     t0, t0, t1          # t0 = The winner's specific mailbox
        # --- CHANGE ENDS HERE ---
	
	csrr	t1, mhartid
	li	t0, 0x0c200004
	slli	t1, t1, 12
	add	t0, t0, t1

	lw	a0, 0(t0)
	beqz	a0, 1f

# Check if ID is UART (10)
        li      t2, 10
        bne     a0, t2, skip_uart

drain_uart:
        li      t1, UART_BASE
        lbu     t2, 5(t1)        # Read LSR (Line Status Register)
        andi    t2, t2, 1        # Check Bit 0 (Data Ready)
        beqz    t2, skip_uart     # FIFO is empty, move to Complete

        lbu     x0, 0(t1)        # Read/Discard byte to clear hardware
        j       drain_uart        # Check for more data

skip_uart:
        sw      a0, 0(t0)        # COMPLETE (The last hardware step)


	#li	t1, UART_BASE
	#lbu	x0, 0(t1)
	#sw	a0, 0(t0)
1:	mret


main:
		mv s0, ra
		li a0, 'x'
		jal write_byte
		mv ra, s0
		ret

boot_lock: .word
.balign 4
uart_owner_id: .word 0

data:
