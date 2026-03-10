    lui     t0, 0x10000         # UART
    auipc   s1, 0
    addi    s1, s1, 1024        # Buffer at PC + 1024
    mv      s2, s1              # s2 = current pointer

wait_for_input:
    # --- 1. Read UART ---
    lbu     t5, 5(t0)           # Check Status
    andi    t5, t5, 1
    beqz    t5, wait_for_input
    lbu     t1, 0(t0)           # t1 = received char

    li      t3, 13              # ASCII for \r (Carriage Return)
    bne     t1, t3, check_dot   # If not \r, check for dot
    li      t1, 10              # If it was \r, change it to \n (Line Feed)

check_dot:
    li      t3, 46              # ASCII '.'
    beq     t1, t3, start_output # EXIT loop if dot detected


    sb      t1, 0(s2)           # STORE THE RAW BYTE
    addi    s2, s2, 1           # Increment binary pointer
    j       wait_for_input

start_output:
    mv      t4, s1              # t4 = Pointer to start of buffer
output_loop:
    beq     t4, s2, exit        # If reached end of buffer, go to end
    lbu     t1, 0(t4)           # Load char from buffer

wait_tx:
    lbu     t5, 5(t0)           # Read UART Status
    andi    t5, t5, 32          # Mask THRE
    beqz    t5, wait_tx         # Wait if busy
    sb      t1, 0(t0)           # Send Hex Char

    addi    t4, t4, 1           # Increment buffer pointer
    j       output_loop           # Repeat

exit:
    lui t0, 0x100
    li t1, 0x5555
    sw t1, 0(t0)
final_spin:
    wfi
    j       final_spin

