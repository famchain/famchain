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
	LOAD_ADDRESS    t0 boot_lock
        li              t1, 1
        amoadd.w.aq     tp, t1, (t0)

	bnez tp, skip_0_events
	li a0, 'x'
	jal write_byte
	jal init_uart
skip_0_events:
	beqz tp, skip_others_events
	li a0, 'y'
	jal write_byte
	jal init_others
skip_others_events:
	jal init_common

1:	wfi
	j 1b

init_uart:
    # 1. Global Priority
    li      t0, PLIC_PRIO_10
    li      t1, 1
    sw      t1, 0(t0)

    # 2. DYNAMIC Enable: Enable UART for the ACTUAL winner
    csrr    t3, mhartid      # Get the physical ID of the winner
    slli    t4, t3, 1        # Context = Hart * 2 (M-Mode)
    slli    t2, t4, 7        # Offset = Context * 128
    
    li      t0, PLIC_MENABLE
    add     t0, t0, t2       # Now we point to the WINNER'S enable register
    li      t1, (1 << 10)
    sw      t1, 0(t0)

    # 3. UART Hardware
    li      t0, UART_BASE
    li      t1, 1
    sb      t1, 1(t0)
    ret


init_others:
	ret

init_common:
    # 1. Set Trap Vector
    LOAD_ADDRESS t0, trap_handler
    csrw    mtvec, t0

    # 2. Calculate THIS hart's PLIC Threshold (Stride 0x1000)
    csrr    t3, mhartid
    slli    t2, t3, 12       # HartID * 4096
    li      t0, PLIC_MTHRESH
    add     t0, t0, t2
    sw      zero, 0(t0)      # Threshold = 0 (Accept all)

    # 3. Enable Local Interrupts (External + Software)
    li      t0, 0x808       # MSIE (8) + MEIE (800)
    csrs    mie, t0
    li      t0, 8           # MIE (Global)
    csrs    mstatus, t0
    ret

.align 4
trap_handler:
    li      a0, 'a'
    add     a0, a0, tp
    jal     write_byte
    li      a0, 'A'
    csrr    t1, mhartid
    add     a0, a0, t1
    jal write_byte

    csrr    t0, mcause
    bltz    t0, handle_int
    
    # Exception handling (ebreak)
    csrr    t1, mepc
    addi    t1, t1, 4
    csrw    mepc, t1
    mret

handle_int:
    csrr    t0, mcause
    slli    t1, t0, 1
    srli    t1, t1, 1

    # 1. Check for External Interrupt (11)
    li      t2, 11
    bne     t1, t2, 1f

    # 2. Look at OUR OWN mailbox (The Winner's mailbox)
    csrr    t1, mhartid
    slli    t1, t1, 1           # ContextID = HartID * 2
    slli    t1, t1, 12          # Offset = ContextID * 4096 (0x1000)
    li      t0, 0x0c200004      # Base for Context 0
    add     t0, t0, t1          # t0 = OUR unique Claim/Complete register

    # 3. Claim
    lw      a0, 0(t0)
    beqz    a0, 1f              # Spurious? Exit.

    # 4. Handle UART
    li      t1, UART_BASE
    lbu     x0, 0(t1)

    # 5. Complete
    sw      a0, 0(t0)

1:  mret



write_byte:
        li              t0, UART_BASE
1:
        lbu             t1, UART_LSR(t0)
        andi            t1, t1, UART_WR_MASK    # mask
        beqz            t1, 1b                  # retry
        sb              a0, UART_RBR(t0)        # send to UART
        ret

boot_lock: .word
