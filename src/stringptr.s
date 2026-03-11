li		x3, 0x10000000      # UART base
#la		x5, strx1
#auipc   x5, 0
#addi    x5, x5, 0x44

auipc x5, 0
.equ STR_OFFSET, (strx1 - here + 4)
here:
addi x5, x5, %lo(STR_OFFSET)


string_loop:
lbu     x30, 0(x5)         # Load current char into x30 (input for write_char)
beqz    x30, string_end     # If null, we are done
write_char:
lbu     x29, 5(x3)          # UART LSR
andi    x29, x29, 0x20      # THRE bit
beqz    x29, write_char
sb      x30, 0(x3)          # UART THR
addi x5,x5,1
j       string_loop
string_end:
jal		exit                # Shutdown

exit:
li      x30, 0x100000       # QEMU Virt Test Device
li      x29, 0x5555         # Shutdown command
sw      x29, 0(x30)
final_spin:
wfi
j       final_spin

strx1: .ascii "abcd"

