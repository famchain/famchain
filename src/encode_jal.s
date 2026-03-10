.section .text
.globl _start

_start:
    li      a1, 1
    # --- Test 1: Offset 64 ---
    li      a0, 64
    jal     t6, encode_jal
    jal     t5, print_loop      # Use t5 as our 'return address'

    # --- Test 2: Offset -4 ---
    li      a0, -4
    jal     t6, encode_jal
    jal     t5, print_loop

    # --- Test 3: Offset -8 ---
    li      a0, -8
    jal     t6, encode_jal
    jal     t5, print_loop

x:
    j       x                   # Infinite loop when done


print_loop:
    li      s0, 0x10000000      # UART Base Address
    mv      s1, a0              # Value to print is in a0
    li      s2, 8               # 8 hex digits
    
digit_loop:
    srli    t0, s1, 28          
    andi    t0, t0, 0xF         
    li      t1, 10
    blt     t0, t1, is_digit
    addi    t0, t0, 7           
is_digit:
    addi    t0, t0, 48          
    sb      t0, 0(s0)           
    slli    s1, s1, 4
    addi    s2, s2, -1
    bnez    s2, digit_loop

    li      t0, 10              # Print Newline
    sb      t0, 0(s0)
    jr      t5                  # Return to caller using t5

# --- JAL Encoding Function ---
# Input:  a0 = offset
# Output: a0 = JAL machine code (rd=x1)
encode_jal:
    li      t0, 0x6F            # JAL Opcode (1101111)

    # 2. Insert the chosen rd (bits 11:7)
    andi    a1, a1, 0x1F    # Safety: mask to 5 bits
    slli    a1, a1, 7       # Shift to rd position
    or      t0, t0, a1      # Combine opcode and rd


    # Scramble bits into J-type format
    # imm[20] -> inst[31]
    srli    t1, a0, 20
    andi    t1, t1, 0x1
    slli    t1, t1, 31
    
    # imm[10:1] -> inst[30:21]
    srli    t2, a0, 1
    li      t5, 0x3FF
    and     t2, t2, t5
    slli    t2, t2, 21
    
    # imm[11] -> inst[20]
    srli    t3, a0, 11
    andi    t3, t3, 0x1
    slli    t3, t3, 20
    
    # imm[19:12] -> inst[19:12]
    srli    t4, a0, 12
    andi    t4, t4, 0xFF
    slli    t4, t4, 12
    
    # Combine
    or      a0, t0, t1
    or      a0, a0, t2
    or      a0, a0, t3
    or      a0, a0, t4
    jr      t6                  # Return using t6

