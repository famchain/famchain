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
# file: fam1.s - second stage (asm impl)
# ──────────────────────────────────────────────────────────────────────────────

    # --- Initialization ---
    li      t0, 0x10000000        # UART Base
    la      x22, data             # Label Table Base
    li      t1, 2048              # Offset for Source Buffer
    add     s1, x22, t1           # s1 = Start of Source Buffer
    mv      s2, s1                # s2 = Moving pointer for Capture
    li      t6, 10                # Initialize "prev char" to \n

capture_loop:
    # Wait for UART Data Ready
    lbu     t5, 5(t0)
    andi    t5, t5, 1
    beqz    t5, capture_loop
    
    lbu     t1, 0(t0)             # Get current char (t1)

    # Check for Termination ('.' following a newline)
    li      t3, 46                # ASCII '.'
    bne     t1, t3, not_exit_seq
    
    # If dot, check if previous was \n (10) or \r (13)
    li      t3, 10
    beq     t6, t3, run_encode    # Go to encode loop, NOT output
    li      t3, 13
    beq     t6, t3, run_encode    # Go to encode loop, NOT output

not_exit_seq:
    sb      t1, 0(s2)             # Store char to Source Buffer
    addi    s2, s2, 1             # Advance Capture Pointer
    mv      t6, t1                # Update "prev char"
    j       capture_loop

# --- 2. Pass 1: Encode (Copying from Buffer 1 to Buffer 2) ---
run_encode:
    mv      x23, s1               # x23 = Start of Source Buffer
    mv      x24, s2               # x24 = Start of Work Buffer (begins at s2)
    # Note: s2 is the END of Source Buffer from Capture Phase

start_encode:
    beq     x23, s2, start_output # When x23 hits s2, Pass 1 is done
    lbu     t1, 0(x23)            # Read from Source
    sb      t1, 0(x24)            # Write to Work Buffer
    addi    x23, x23, 1           # Advance Source Pointer
    addi    x24, x24, 1           # Advance Work Buffer Pointer
    j       start_encode

# --- 3. Pass 2: Output (Echo back the Work Buffer) ---
start_output:
    # Work Buffer exists from s2 to x24
    mv      t4, s2                # t4 = Pointer to start of Work Buffer
output_loop:
    beq     t4, x24, exit         # Stop when we reach the end of Work Buffer
    lbu     t1, 0(t4)             # Load char from Work Buffer

    # Translate \r (13) to \n (10) for terminal scrolling
    li      t3, 13
    bne     t1, t3, wait_tx
    li      t1, 10

wait_tx:
    lbu     t5, 5(t0)
    andi    t5, t5, 0x20          # Mask THRE
    beqz    t5, wait_tx
    sb      t1, 0(t0)             # Send to UART

    addi    t4, t4, 1
    j       output_loop

# --- 4. Shutdown ---
exit:
    # Drain UART to ensure text prints before poweroff
    lbu     t5, 5(t0)
    andi    t5, t5, 0x40          # Mask TEMT (Bit 6)
    beqz    t5, exit

    li      t2, 0x100000          # QEMU Virt Test Device
    li      t1, 0x5555            # Shutdown command
    sw      t1, 0(t2)

final_spin:
    wfi
    j       final_spin

.align 4
data:
    # Workspace follows this label

