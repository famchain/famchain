.section .text
.globl _start

_start:
    # 1. Setup a simple offset to encode
    # Example: 200 bytes
    li      a0, -8
    
    # 2. Call encoding logic
    # Since we aren't using a stack, we use t6 to store the return address 
    # instead of 'call' which uses 'ra' and expects a stack.
    jal     t6, encode_jal

    # 3. Print the 32-bit result (in a0) as Hex to UART
    # QEMU Virt UART is at 0x10000000
    li      s0, 0x10000000      # UART Base Address
    mv      s1, a0              # Save encoded instruction
    li      s2, 8               # Counter for 8 hex digits



print_loop:
    # Extract top 4 bits (nibble)
    srli    t0, s1, 28          
    andi    t0, t0, 0xF         
    
    # Convert to ASCII
    li      t1, 10
    blt     t0, t1, is_digit
    addi    t0, t0, 7           # Offset for A-F
is_digit:
    addi    t0, t0, 48          # Offset for 0-9
    
    # Write to UART Transmitter Holding Register
    sb      t0, 0(s0)           
    
    # Shift left for next nibble and loop
    slli    s1, s1, 4
    addi    s2, s2, -1
    bnez    s2, print_loop

    # Final newline
    li      t0, 10
    sb      t0, 0(s0)

halt:
    j       halt

li a0, 64   # Offset
li a1, 0    # rd = x1 (ra)
j combine

# --- JAL Encoding Function ---
# Input:  a0 = offset
# Output: a0 = JAL machine code (rd=x1)
encode_jal:
    li      t0, 0x6F            # JAL Opcode (1101111)
    addi    t0, t0, 0x80        # Add rd = x1 (bit 7)

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
combine:
    or      a0, t0, t1
    or      a0, a0, t2
    or      a0, a0, t3
    or      a0, a0, t4
    jr      t6                  # Return using t6

