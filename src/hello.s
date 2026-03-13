	j main

exit:
        li              x30, 0x100000           # QEMU Virt Test Device
        li              x29, 0x5555             # Shutdown command
        sw              x29, 0(x30)

final_spin:
        wfi
        j               final_spin


write_byte:
        lbu             x28, 5(x4)
        andi            x28, x28, 0x20          # mask
        beqz            x28, write_byte         # retry
        sb              x31, 0(x4)              # send to UART
        ret


main:
	mv		x20, x1
        li              x4, 0x10000000          # UART base
	li		x31, 66
	jal		write_byte
        li              x31, 10
	jal		write_byte
	jal		exit

