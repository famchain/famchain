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
# famc.s - fam compiler (GNU as src)
# ──────────────────────────────────────────────────────────────────────────────

# System Constants
.equ	EXIT_ADDR,	0x100000
.equ	EXIT_PASS,	0x5555
.equ	UART_BASE,	0x10000000
.equ	UART_RD_MASK,	0x1
.equ	UART_WR_MASK,	0x20
.equ	UART_LSR,	5
.equ	UART_RBR,	0

.macro LOAD_ADDRESS reg, label
_base\@:
    # Uses \@ to make a unique constant name for every expansion
    .equ _offset\@, (\label - _base\@)
    auipc   \reg, %hi(_offset\@)
    addi    \reg, \reg, %lo(_offset\@)
.endm

.macro PRINT label
        LOAD_ADDRESS    a0, \label
        jal             print_str
.endm

.macro PRINTLN label
        LOAD_ADDRESS    a0, \label
        jal             print_str
        li              a0, '\n'
        jal             write_byte
.endm

.macro ALLOC_STACK size
        addi            sp, sp, -\size          # Allocate bytes on stack
        blt             sp, gp, stack_panic     # panic if stack overflow
        sd              ra, 0(sp)               # Always store ra
.endm

.macro DEALLOC_STACK size
        ld              ra, 0(sp)               # Restore ra
        addi            sp, sp, \size           # Deallocate bytes on stack
.endm

.macro BUMP_HEAP size
        addi            gp, gp, \size           # update gp
        bgt             gp, sp, stack_panic     # stack overflow
.endm

_start:
        LOAD_ADDRESS    gp data                 # Load heap ptr
        li              sp, 1
        slli            sp, sp, 26
        add             sp, sp, gp              # Init stack at heap + 64 MiB
        andi            sp, sp, -16             # Align stack to 16 bytes

	jal		write_data
	jal		exit

write_nop:
        ALLOC_STACK     16
        li              a0, 0x13
        jal             write_byte
        li              a0, 0x00
        jal             write_byte
        jal             write_byte
        jal             write_byte
        DEALLOC_STACK   16
        ret

write_data:
	ALLOC_STACK	16
	jal		write_nop
	DEALLOC_STACK	16
	ret

read_byte:
	li		t0, UART_BASE
1:
        lbu             t1, UART_LSR(t0)	# Read from UART
        andi            t1, t1, UART_RD_MASK	# mask
        beqz            t1, 1b			# if not ready read again
        lbu             a0, UART_RBR(t0)	# Get current char, store x30
        ret

write_byte:
	li		t0, UART_BASE
1:
        lbu             t1, UART_LSR(t0)
        andi            t1, t1, UART_WR_MASK	# mask
        beqz            t1, 1b			# retry
        sb              a0, UART_RBR(t0)	# send to UART
        ret

print_str:
	li		t4, UART_BASE
        mv              t1, a0
1:      lbu             t0, 0(t1)
        beqz            t0, 2f
        lbu             t2, UART_LSR(t4)               # check status
        andi            t2, t2, UART_WR_MASK            # mask
        beqz            t2, write_byte          # retry
        sb              t0, UART_RBR(t4)               # send to UART
        addi            t1, t1, 1               # Next char
        j               1b                      # Loop back
2:  
        ret 


stack_panic:
        PRINTLN msg_stack_overflow
        j               exit


exit:
	li		t0, EXIT_ADDR		# load exit addr
	li		t1, EXIT_PASS		# shutdown command
	sw		t1, UART_RBR(t0)
1:
	wfi
	j               1b

msg_stack_overflow: .string "stack overflow!"
hello: .string "hello!"
data:
