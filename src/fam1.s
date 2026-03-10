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
    la x22, data
    li      t1, 2048              # Offset for Source Buffer
    add     s1, x22, t1           # s1 = Start of Source Buffer
    mv      s2, s1                # s2 = Current Pointer for Capture
    li      t6, 10

capture_loop:
    # 1. Wait for UART
    lbu     t5, 5(t0)
    andi    t5, t5, 1
    beqz    t5, capture_loop
    
    lbu     t1, 0(t0)             # Get current char (t1)

    # --- THE FIX: Only exit if (current == '.' AND prev == '\n') ---
    li      t3, 46                # ASCII '.'
    bne     t1, t3, not_exit_seq  # If current is NOT '.', it's just data
    
    # It is a dot. Is the PREVIOUS char a newline?
    li      t3, 10                # ASCII '\n'
    beq     t6, t3, start_output  # EXIT if '\n' then '.'
    li      t3, 13                # ASCII '\r' (Carriage Return)
    beq     t6, t3, start_output  # EXIT if '\r' then '.'

not_exit_seq:
    # 2. Store current char to Buffer
    sb      t1, 0(s2)
    addi    s2, s2, 1
    
    # 3. Update "Previous Character" (t6) for next time
    mv      t6, t1                
    j       capture_loop

    # --- 4. Start Output (Echo back the Buffer) ---
start_output:
    mv      t4, s1                # t4 = Pointer to start of captured buffer
output_loop:
    beq     t4, s2, prepare_exit  # Stop when we reach the end (s2)
    lbu     t1, 0(t4)             # Load char from buffer

    # --- Translate \r (13) to \n (10) for terminal scrolling ---
    li      t3, 13                # Carriage Return
    bne     t1, t3, wait_tx
    li      t1, 10                # Convert to Line Feed

wait_tx:
    lbu     t5, 5(t0)             # Read Status
    andi    t5, t5, 0x20          # Mask THRE (Bit 5: Register Empty)
    beqz    t5, wait_tx           # Wait if busy
    sb      t1, 0(t0)             # Send char to UART

    addi    t4, t4, 1             # Move to next char in buffer
    j       output_loop

prepare_exit:
    # --- 5. Drain UART & Shutdown ---
    # Wait for the last character to physically leave the shift register
wait_final:
    lbu     t5, 5(t0)
    andi    t5, t5, 0x40          # Mask TEMT (Bit 6: Transmitter Empty)
    beqz    t5, wait_final

exit:
    li      t0, 0x100000          # QEMU Virt Test/Poweroff device
    li      t1, 0x5555            # Shutdown command
    sw      t1, 0(t0)

final_spin:
    wfi
    j       final_spin
data:
