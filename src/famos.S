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
.equ    UART_BASE,      0x10000000
.equ    UART_RD_MASK,   0x1
.equ    UART_WR_MASK,   0x20
.equ    UART_LSR,       5
.equ    UART_RBR,       0
.equ    PLIC_BASE,    0x0c000000
.equ    PLIC_PRIO_10, (PLIC_BASE + 0x28)     # 10 * 4 = 40 (0x28)
.equ    PLIC_MENABLE, (PLIC_BASE + 0x2000)   # Machine Mode Enable
.equ    PLIC_MTHRESH, (PLIC_BASE + 0x200000) # Machine Mode Threshold
.equ    PLIC_MCLAIM,  (PLIC_BASE + 0x200004) # Claim/Complete Register

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

	LOAD_ADDRESS    t0, trap_handler
	csrw            mtvec, t0

    	mv              a0, s0          # Pass ID to init function
	jal             init_plic

	li      t0, 0x808       # 0x800 (External) + 0x008 (Software)
	csrs    mie, t0


    li              t0, 8           # MIE (Global Interrupt Enable)
    csrs            mstatus, t0

    # 5. Enable UART Hardware Interrupts (IER)
    li              t0, UART_BASE
    li              t1, 1           # Received Data Available
    sb              t1, 1(t0)

    # 6. TEST: Every core hits ebreak (Exception)
    ebreak

    li      t0, 0x02000004
    li      t1, 1
    sw      t1, 0(t0) 

	li		a0, '0'
	add		a0, a0, s0
	jal		write_byte

1:
	wfi
	j 1b


write_byte:
        li              t0, UART_BASE
1:
        lbu             t1, UART_LSR(t0)
        andi            t1, t1, UART_WR_MASK    # mask
        beqz            t1, 1b                  # retry
        sb              a0, UART_RBR(t0)        # send to UART
        ret

init_plic:
    # Set Priority (Global - safe to repeat)
    li      t0, PLIC_PRIO_10
    li      t1, 1
    sw      t1, 0(t0)

    # Calculate Context Offset (Logical ID * 0x80)
    slli    t2, a0, 7           

    # SELECTIVE: Only enable UART (ID 10) for ID 0
    bnez    a0, skip_enable
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

.align 4
trap_handler:
    csrr    t1, mhartid
    csrr    t0, mcause
    bltz    t0, handle_int  # If negative, it's an interrupt

    # Handle Exception (ebreak)
    li      a0, 'E'         # Print 'E' for every core that hits ebreak
    add     a0, a0, t1
    jal     write_byte
    csrr    t1, mepc
    addi    t1, t1, 4       # Advance PC past ebreak
    csrw    mepc, t1
    mret

handle_int:
    # Calculate THIS core's Claim register (Physical mhartid * 0x1000)

csrr   t0, mcause
slli t1, t0, 1
srli t1, t1, 1

li t2, 3
beq t1, t2, handle_clint_ipi

    csrr    t1, mhartid
    li      t0, 0x0c200004
    slli    t1, t1, 12
    add     t0, t0, t1

    lw      a1, 0(t0)       # Claim
    beqz    a1, 2f          # If 0, nothing to do (spurious)

    li      a0, '!'
    add     a0, a0, t1
    jal     write_byte      # Print '!' for keypress

    # Clear UART hardware by reading the byte
    li      t1, UART_BASE
    li      t0, 0xc200004
    lbu     x0, 0(t1)

    sw      a1, 0(t0)       # Complete

    li      t2, 0x0200000C   # CLINT MSIP for Hart 3 (0x02000000 + 3*4)
    li      t3, 1
    sw      t3, 0(t2)

2:  mret

handle_clint_ipi:
    # 1. STOP THE INFINITE LOOP (Clear the MSIP bit)
    csrr    t1, mhartid
    li      t0, 0x02000000   # CLINT Base
    slli    t1, t1, 2        # Physical ID * 4
    add     t0, t0, t1
    sw      x0, 0(t0)        # Write 0 to clear the interrupt

    # 2. Print 'S' for Software Interrupt
    li      a0, 'S'
    csrr    t1, mhartid
    add     a0, a0, t1
    jal     write_byte
    mret

boot_lock:
