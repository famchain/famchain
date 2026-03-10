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

    li      x5, 0x10000000        # UART Base
    la      x22, data             # Label Table Base
    li      x6, 2048              # Offset for Source Buffer
    add     x14, x22, x6           # x14 = Start of Source Buffer
    mv      x15, x14                # x15 = Moving pointer for Capture
    li      x11, 10                # Initialize "prev char" to \n
    li      x16, 0                 # nibble toggle

capture_loop:
    lbu     x10, 5(x5)
    andi    x10, x10, 1
    beqz    x10, capture_loop
    lbu     x6, 0(x5)             # Get current char (x6)

    # Check for Termination ('.' following a newline)
    li      x8, 46                # ASCII '.'
    bne     x6, x8, not_exit_seq
    
    # If dot, check if previous was \n (10) or \r (13)
    li      x8, 10
    beq     x11, x8, run_encode    # Go to encode loop
    li      x8, 13
    beq     x11, x8, run_encode    # Go to encode loop

not_exit_seq:
    sb      x6, 0(x15)             # Store char to Source Buffer
    addi    x15, x15, 1             # Advance Capture Pointer
    mv      x11, x6                # Update "prev char"
    j       capture_loop          # Repeat

# --- Pass 1: Encode
run_encode:
    mv      x23, x14               # x23 = Start of Source Buffer
    mv      x24, x15               # x24 = Start of Work Buffer (begins at x15)

start_encode:
    beq     x23, x15, start_output # End of source?
    lbu     x6, 0(x23)            # Read from Source
    addi    x23, x23, 1           # Advance source pointer

    # --- Check for Comment Start '#' (ASCII 35) ---
    li      x8, 35                
    beq     x6, x8, skip_comment  

    # Check for label ':' (ASCII 58)
    li      x8, 58
    bne     x6, x8, skip_label

    beq     x23, x15, start_output # Safety check for end of buffer
    lbu     x6, 0(x23)            # Read label
    addi    x23, x23, 1           # Advance source pointer

    # calculate offset
    slli    x10, x6, 3             # x10 = char << 3
    add     x10, x22, x10          # x10 = base_addr (x22) + offset
    sd      x24, 0(x10)

    j       start_encode
skip_label:

    # Check for jal 'j' (ASCII 106)
    li      x8, 106
    bne     x6, x8, skip_jal
    addi    x23, x23, 1           # Advance source pointer

jal_white_space:
    beq     x23, x15, start_output # Safety check for end of buffer
    lbu     x6, 0(x23)
    addi    x23, x23, 1           # Advance source pointer
    li      x7, 32  # space ' '
    bne     x6, x7, jal_white_space_end  # end whitespace
    j       jal_white_space
jal_white_space_end:
    
skip_jal:

    # filter non hex
    mv      x7, x6                # Keep original char in x7
    addi x6, x6, -48              # x6 = char - '0'

    # --- Check 0-9 ---
    li      x8, 10                # Load 10 for comparison
    bltu    x6, x8, is_hex        # If (char-'0') < 10, it's 0-9
    
    # --- Check A-F ---
    addi    x6, x6, -7            # x6 = char - '0' - 7 (Maps 'A' to 10)
    li      x8, 16                # Load 16 for comparison
    
    # Check if it's between 10 and 15
    bltu    x6, x8, is_hex
    j       start_encode # Not hex

is_hex:
    li      x8, 1
    beq     x16, x8, store_low

    # handle high
    slli    x17, x6, 4             # shift left 4, store in x17
    li      x16, 1                 # toggle
    j       start_encode          # get next

store_low:
    or      x17, x17, x6            # or with high nibble
    sb      x17, 0(x24)            # store in buffer
    addi    x24, x24, 1           # incr iterator
    li      x16, 0                 # toggle
    j       start_encode          # get next

skip_comment:
    beq     x23, x15, start_output # Safety check for end of buffer
    lbu     x6, 0(x23)            
    addi    x23, x23, 1           
    
    # Check for Newline (10) or Carriage Return (13)
    li      x8, 10                
    beq     x6, x8, start_encode  # Resume encoding after newline
    li      x8, 13                
    beq     x6, x8, start_encode  # Resume encoding after CR
    
    j       skip_comment          # Keep skipping until end of line


# --- Pass 2: Output
start_output:
    # Work Buffer exists from x15 to x24
    mv      x9, x15                # x9 = Pointer to start of Work Buffer
output_loop:
    beq     x9, x24, exit         # Stop when we reach the end of Work Buffer
    lbu     x6, 0(x9)             # Load char from Work Buffer

begin_write:
    lbu     x10, 5(x5)
    andi    x10, x10, 0x20          # Mask THRE
    beqz    x10, begin_write
    sb      x6, 0(x5)             # Send to UART

    addi    x9, x9, 1
    j       output_loop

# --- Shutdown ---
exit:
    # Drain UART to ensure text prints before poweroff
    lbu     x10, 5(x5)
    andi    x10, x10, 0x40          # Mask TEMT (Bit 6)
    beqz    x10, exit

    li      x7, 0x100000          # QEMU Virt Test Device
    li      x6, 0x5555            # Shutdown command
    sw      x6, 0(x7)

final_spin:
    wfi
    j       final_spin

# Helpers:

# --- Hex to Integer Helper ---
# Input: x6 (ASCII), Output: x10 (0-15)
hex_to_int:
    addi    x10, x6, -48             # x10 = char - '0'
    li      t1, 10
    bltu    x10, t1, hex_to_int_done # If 0-9, done
    addi    x10, x10, -7             # Adjust for 'A'-'F' (Maps 17 to 10)
hex_to_int_done:
    ret

.align 8
data:
    # Workspace follows this label

