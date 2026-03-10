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

    li      t0, 0x10000000        # UART Base
    la      x22, data             # Label Table Base
    li      t1, 2048              # Offset for Source Buffer
    add     s1, x22, t1           # s1 = Start of Source Buffer
    mv      s2, s1                # s2 = Moving pointer for Capture
    li      t6, 10                # Initialize "prev char" to \n
    li      s3, 0                 # nibble toggle

capture_loop:
    lbu     t5, 5(t0)
    andi    t5, t5, 1
    beqz    t5, capture_loop
    lbu     t1, 0(t0)             # Get current char (t1)

    # Check for Termination ('.' following a newline)
    li      t3, 46                # ASCII '.'
    bne     t1, t3, not_exit_seq
    
    # If dot, check if previous was \n (10) or \r (13)
    li      t3, 10
    beq     t6, t3, run_encode    # Go to encode loop
    li      t3, 13
    beq     t6, t3, run_encode    # Go to encode loop

not_exit_seq:
    sb      t1, 0(s2)             # Store char to Source Buffer
    addi    s2, s2, 1             # Advance Capture Pointer
    mv      t6, t1                # Update "prev char"
    j       capture_loop          # Repeat

# --- Pass 1: Encode
run_encode:
    mv      x23, s1               # x23 = Start of Source Buffer
    mv      x24, s2               # x24 = Start of Work Buffer (begins at s2)

start_encode:
    beq     x23, s2, start_output # End of source?
    lbu     t1, 0(x23)            # Read from Source
    addi    x23, x23, 1           # Always advance source pointer

    # --- Check for Comment Start '#' (ASCII 35) ---
    li      t3, 35                
    beq     t1, t3, skip_comment  

    # filter non hex
    mv      t2, t1                # Keep original char in t2
    addi t1, t1, -48              # t1 = char - '0'

    # --- Check 0-9 ---
    li      t3, 10                # Load 10 for comparison
    bltu    t1, t3, is_hex        # If (char-'0') < 10, it's 0-9
    
    # --- Check A-F ---
    addi    t1, t1, -7            # t1 = char - '0' - 7 (Maps 'A' to 10)
    li      t3, 16                # Load 16 for comparison
    
    # Check if it's between 10 and 15
    bltu    t1, t3, is_hex
    j       start_encode # Not hex

is_hex:
    li      t3, 1
    beq     s3, t3, store_low

    # handle high
    slli    s4, t1, 4             # shift left 4, store in s4
    li      s3, 1                 # toggle
    j       start_encode          # get next

store_low:
    or      s4, s4, t1            # or with high nibble
    sb      s4, 0(x24)            # store in buffer
    addi    x24, x24, 1           # incr iterator
    li      s3, 0                 # toggle
    j       start_encode          # get next

skip_comment:
    beq     x23, s2, start_output # Safety check for end of buffer
    lbu     t1, 0(x23)            
    addi    x23, x23, 1           
    
    # Check for Newline (10) or Carriage Return (13)
    li      t3, 10                
    beq     t1, t3, start_encode  # Resume encoding after newline
    li      t3, 13                
    beq     t1, t3, start_encode  # Resume encoding after CR
    
    j       skip_comment          # Keep skipping until end of line


# --- Pass 2: Output
start_output:
    # Work Buffer exists from s2 to x24
    mv      t4, s2                # t4 = Pointer to start of Work Buffer
output_loop:
    beq     t4, x24, exit         # Stop when we reach the end of Work Buffer
    lbu     t1, 0(t4)             # Load char from Work Buffer

begin_write:
    lbu     t5, 5(t0)
    andi    t5, t5, 0x20          # Mask THRE
    beqz    t5, begin_write
    sb      t1, 0(t0)             # Send to UART

    addi    t4, t4, 1
    j       output_loop

# --- Shutdown ---
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

.align 8
data:
    # Workspace follows this label

