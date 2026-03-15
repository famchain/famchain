# --- System Constants ---
.equ UART_BASE,         0x10000000
.equ UART_LSR,          5
.equ UART_WR_MASK,      0x20
.equ VIRTIO_DISK_BASE,  0x10001000   
.equ VIO_MAGIC,         0x000
.equ VIO_DEVICE_ID,     0x008
.equ VIO_STATUS,        0x070

_start:
		li a0, 'x'
		jal write_byte
		li a0, '\n'
		jal write_byte

		li   t0, VIRTIO_DISK_BASE
		lw   t1, VIO_MAGIC(t0)      # Should be 0x74726976 ("virt")
		li   t2, 0x74726976
		bne  t1, t2, error_not_virtio
	
		lw   t1, VIO_DEVICE_ID(t0)  # Should be 2 for Block Device
		li   t2, 2
		bne  t1, t2, error_not_disk

		# 1. Reset the device
		sw      zero, VIO_STATUS(t0)

		# 2. Set ACKNOWLEDGE bit (1)
		li      t1, 1
		sw      t1, VIO_STATUS(t0)

		# 3. Set DRIVER bit (2)
		lw      t1, VIO_STATUS(t0)
		ori     t1, t1, 2
		sw      t1, VIO_STATUS(t0)

		# 4. Set FEATURES_OK bit (8)
		# (In a real OS, you'd negotiate features here, but for bare-metal, 
		# we'll just tell it we're okay with the defaults)
		lw      t1, VIO_STATUS(t0)
		ori     t1, t1, 8
		sw      t1, VIO_STATUS(t0)

		# 5. Check if FEATURES_OK was accepted
		lw      t1, VIO_STATUS(t0)
		andi    t2, t1, 8
		beqz    t2, error_features_not_supported

		# 6. Set DRIVER_OK bit (4) - Device is now "Live"
		lw      t1, VIO_STATUS(t0)
		ori     t1, t1, 4
		sw      t1, VIO_STATUS(t0)


		li a0, 's'
		jal write_byte
		li a0, '\n'
		jal write_byte

1:		wfi	
		j 1b

error_not_virtio:
		li a0, '0'
		jal write_byte
		li a0, '\n'
1:              wfi  
                j 1b

error_not_disk:
                li a0, '1'
                jal write_byte
                li a0, '\n'
1:              wfi
                j 1b

error_features_not_supported:
                li a0, '2'
                jal write_byte
                li a0, '\n'
1:              wfi
                j 1b






write_byte: 
    li      t1, UART_BASE
1:  lbu     t2, UART_LSR(t1)
    andi    t2, t2, UART_WR_MASK
    beqz    t2, 1b
    sb      a0, 0(t1)
    ret    
