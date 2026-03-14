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
.equ	PLIC_BASE,    0x0c000000
.equ	PLIC_PRIO_10, (PLIC_BASE + 0x28)     # 10 * 4 = 40 (0x28)
.equ	PLIC_MENABLE, (PLIC_BASE + 0x2000)   # Machine Mode Enable
.equ	PLIC_MTHRESH, (PLIC_BASE + 0x200000) # Machine Mode Threshold
.equ	PLIC_MCLAIM,  (PLIC_BASE + 0x200004) # Claim/Complete Register

.macro LOAD_ADDRESS reg, label
_base\@:
    # Uses \@ to make a unique constant name for every expansion
    .equ _offset\@, (\label - _base\@)
    auipc   \reg, %hi(_offset\@)
    addi    \reg, \reg, %lo(_offset\@)
.endm

_start:
	LOAD_ADDRESS	t0 boot_lock
	li		t1, 1
	amoadd.w.aq	s0, t1, (t0)

	mv		a0, s0
	jal		init_plic
	LOAD_ADDRESS    t0, trap_handler
	csrw            mtvec, t0

	ebreak

 	li      t0, UART_BASE
        li      t1, 1            # Bit 0 of IER is "Received Data Available"
        sb      t1, 1(t0)

	ebreak

    # Gate 1: Enable Machine External Interrupts in the 'mie' register
    li      t0, 0x800       # Bit 11 is MEIE (Machine External Interrupt Enable)
    csrs    mie, t0

    # Gate 2: Flip the master switch in 'mstatus'
    li      t0, 8           # Bit 3 is MIE (Global Machine Interrupt Enable)
    csrs    mstatus, t0



	li a0, '0'
	add a0, a0, s0
	jal write_byte
	li a0, '\n'
	jal write_byte

halt_core:
	1: wfi
	j 1b

init_plic:
    # 1. Global Setup: Set UART (ID 10) Priority to 1
    li      t0, PLIC_PRIO_10
    li      t1, 1
    sw      t1, 0(t0)

    # 2. Local Setup: Calculate this core's context offset (ID * 0x80)
    slli    t2, a0, 7           # t2 = ID * 128 (0x80)

    # 3. Enable ID 10 in THIS core's Enable Mask
    li      t0, PLIC_MENABLE
    add     t0, t0, t2          # Base + (ID * 0x80)
    li      t1, (1 << 10)
    sw      t1, 0(t0)

    # 4. Set Threshold to 0 for THIS core
    li      t0, PLIC_MTHRESH
    add     t0, t0, t2          # Base + (ID * 0x80)
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

# --- The Trap Handler ---
.align 4                 # This is critical: mtvec target MUST be 4-byte aligned
trap_handler:
    csrr    t0, mcause      # Why are we here?
    bltz    t0, handle_int  # If bit 63 is 1, it's an Interrupt (Hardware)

    # --- It's an Exception (like ebreak) ---
    li      a0, 'E'         # 'E' for Exception
    jal     write_byte
    csrr    t1, mepc
    addi    t1, t1, 4       # Skip the ebreak
    csrw    mepc, t1
    mret

handle_int: 
    # 1. Calculate THIS core's specific Claim/Complete register
    # Base (Hart 0 M-mode) is 0x0c200004. Each hart is +0x1000 (4096 bytes)
    csrr    t1, mhartid      # Get physical ID (0, 1, 2, 3...)
    li      s10, 0x0c200004  # PLIC_MCLAIM Base
    slli    t1, t1, 12       # ID * 4096 (0x1000)
    add     s10, s10, t1     # s10 now points to THIS hart's claim register

    # 2. Claim from PLIC
    lw      a1, 0(s10)       # Get ID (10)

    # 3. Clear the UART (Crucial: Read the key)
    li      t1, UART_BASE
    lbu     t2, 0(t1)        # Read key to clear hardware flag

    # 4. Print the '!'
    li      a0, '!'
    jal     write_byte

    # 5. Complete to PLIC (Using the SAME calculated register in s10)
    sw      a1, 0(s10)       # Write ID back to complete
    mret


boot_lock: .word 0	
