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

# System hardware constants
.equ	EXIT_ADDR,		0x100000
.equ	EXIT_PASS,		0x5555
.equ	UART_BASE,		0x10000000
.equ	UART_RD_MASK,		0x1
.equ	UART_WR_MASK,		0x20
.equ	UART_LSR,		5
.equ	UART_RBR,		0
.equ	HEAP_MAX,		0x84000000		# 64MB limit from start of RAM

.macro LOAD_ADDRESS reg, label
_base\@:
        .equ _offset\@, (\label - _base\@)
        auipc   \reg, %hi(_offset\@)
        addi    \reg, \reg, %lo(_offset\@)
.endm

.macro BUMP_HEAP        size
        LOAD_ADDRESS    t3, global_ptr
        li              t1, 1
        LOAD_ADDRESS    t0, global_lock
1:      amoswap.w.aq    t2, t1, (t0)
        bnez            t2, 1b
        lw              t2, 0(t3)
        li              t4, \size
        mv              a0, t2
        add             t2, t2, t4
        li              t5, HEAP_MAX
        bgeu            t2, t5, heap_panic
        sw              t2, 0(t3)
        amoswap.w.rl    t2, zero, (t0)
.endm

.macro DECR_STACK       size
        addi		sp, sp, -\size
        blt             sp, s11, stack_panic
.endm

.macro INCR_STACK       size
        addi             sp, sp, \size
.endm


.macro INIT_STACK size
        LOAD_ADDRESS    t0 boot_lock
        li              t1, 1
        amoadd.w.aq     tp, t1, (t0)
        bnez            tp, 1f
        LOAD_ADDRESS    gp, data
        li              t0, 15
        add             gp, gp, t0
        li              t0, -16
        and             gp, gp, t0

        LOAD_ADDRESS    t0, global_ptr
        sw              gp, 0(t0)
        li              t1, 1
        LOAD_ADDRESS    t0 complete_lock
        amoadd.w.rl     t1, t1, (t0)
1:      
        LOAD_ADDRESS    t0, complete_lock
2:      lw              t1, 0(t0)
        beqz            t1, 2b
        BUMP_HEAP       \size
        li              t0, \size
        add             sp, a0, t0
        addi            s11, a0, 0
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
        .set _sz, ((_cnt * 8) + 15) & -16

        _def_restore_macro %_macro_depth, %_sz, \regs


        DECR_STACK _sz
        sw      ra, 0(sp)
        .ifnc "\regs", ""
        .set _off, 8
        .irp reg, \regs
                sw \reg, _off(sp)
                .set _off, _off + 8
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
j	main

boot_lock: .word                0x0
global_ptr: .word              0x0
complete_lock: .word            0x0
global_lock: .word              0x0
disk_ptr: .word                0x0

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


write_byte:	
	SETUP t0, t1
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

main:
	INIT_STACK	0x100000
	mv		a0, sp
	jal		print_hex
        li              a0, '\n'
        jal             write_byte
	li		a0, 'x'
	jal		write_byte
	li		a0, '\n'
	jal		write_byte
	#j		exit

1:	wfi
	j		1b

data:
