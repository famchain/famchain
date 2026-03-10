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

    lui     t0, 0x10000                   # UART
    la      s1, data                      # Load the address of 'data' into s1
    mv      x22, s1                       # Use x22 for our table
    addi    s1, s1, 1024
    addi    s1, s1, 1024                  # Reserve 2048 bytes for the lookup
    mv      s2, s1                        # s2 = current pointer
    li      t6, 0                         # in comment
    li      s3, 0                         # nibble toggle

wait_for_input:
    # --- Read UART ---
    lbu     t5, 5(t0)                     # Check Status
    andi    t5, t5, 1
    beqz    t5, wait_for_input
    lbu     t1, 0(t0)                     # t1 = received char
 
    # check end of comment 
    li      t3, 13
    bne     t1, t3, skip_end_comment
    li      t6, 0
skip_end_comment:
    li      t3, 10
    bne     t1, t3, skip_end_comment2
    li      t6, 0
skip_end_comment2:

    li      t3, 35
    bne     t1, t3, skip_start_comment
    li      t6, 1
skip_start_comment:
    li      t3, 1
    beq     t6, t3, wait_for_input

    # Check for label
    li      t3, 58
    beq     t1, t3, skip_label

    # --- Read UART ---
    #lbu     t5, 5(t0)                     # Check Status
    #andi    t5, t5, 1
    #beqz    t5, wait_for_input
    #lbu     t1, 0(t0)                     # t1 = received char

    # Calculate the table address: x22 + (t1 * 8)
    #slli    t3, t1, 3               # t3 = t1 << 3 (multiply by 8)
    #add     t3, x22, t3              # t3 = base_addr + offset

    # Store the current Output Pointer (s2) into the table
    #sd      s2, 0(t3)               # Store 64-bit address into label slot

skip_label:

    # --- Check Termination ('.') ---
    li      t3, 46                        # ASCII '.'
    beq     t1, t3, start_output          # EXIT loop if dot detected

    # --- Normalize t1 (ASCII - 48) ---
    mv      t2, t1                        # Keep original char in t2
    addi t1, t1, -48                      # t1 = char - '0'
    
    # --- Check 0-9 ---
    li      t3, 10                        # Load 10 for comparison
    bltu    t1, t3, is_hex                # If (char-'0') < 10, it's 0-9
    
    # --- Check A-F ---
    addi    t1, t1, -7                    # t1 = ch - '0' - 7 (Maps 'A' to 10)
    li      t3, 16                        # Load 16 for comparison
    
    # Check if it's between 10 and 15
    bltu     t1, t3, check_lower_bound
    j       wait_for_input                # Not hex

is_hex:
    li      t3, 1
    beq     s3, t3, store_low_nibble

    # --- High Nibble Case (s3 == 0) ---
    slli    s4, t1, 4                     # s4 = (0-15) << 4
    li      s3, 1                         # Set state to 1 (waiting for low)
    j       wait_for_input                # Don't store yet!

store_low_nibble:
    # --- Low Nibble Case (s3 == 1) ---
    or      s4, s4, t1                    # s4 = (high << 4) | low
    sb      s4, 0(s2)                     # STORE THE RAW BYTE
    addi    s2, s2, 1                     # Increment binary pointer
    li      s3, 0                         # Reset state to 0
    j       wait_for_input

start_output:
    mv      t4, s1                        # t4 = Pointer to start of buffer
output_loop:
    beq     t4, s2, exit                  # If reached end of buffer, term 
    lbu     t1, 0(t4)                     # Load char from buffer

wait_for_output:
    lbu     t5, 5(t0)                     # Read UART Status
    andi    t5, t5, 32                    # Mask 
    beqz    t5, wait_for_output           # Wait if busy
    sb      t1, 0(t0)                     # Send Hex Char
    
    addi    t4, t4, 1                     # Increment buffer pointer
    j       output_loop                   # Repeat

exit:
    lui t0, 0x100                         # QEMU specific
    li t1, 0x5555
    sw t1, 0(t0)
final_spin:
    wfi                                   # Hardware fallback
    j       final_spin
data:
