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

	jal		init_plic

	li a0, '0'
	add a0, a0, s0
	jal write_byte
	li a0, '\n'
	jal write_byte

halt_core:
	1: wfi
	j 1b

init_plic:
	# 1. Set UART (ID 10) Priority to 1
	li      t0, PLIC_PRIO_10
	li      t1, 1
	sw      t1, 0(t0)

	# 2. Enable ID 10 in the Enable Mask
	li      t0, PLIC_MENABLE
	li      t1, (1 << 10)
	sw      t1, 0(t0)

	# 3. Set Threshold to 0 (Allow all priorities > 0)
	li      t0, PLIC_MTHRESH
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

boot_lock: .word 0	
