# --- System Constants ---
.equ UART_BASE,         0x10000000
.equ UART_LSR,          5
.equ UART_WR_MASK,      0x20
.equ VIRTIO_DISK_BASE,  0x10001000   
.equ VIO_MAGIC,         0x000
.equ VIO_DEVICE_ID,     0x008
.equ VIO_STATUS,        0x070

.equ VIO_QUEUE_SEL,     0x030
.equ VIO_QUEUE_NUM,     0x038
.equ VIO_QUEUE_PFN,     0x040

.macro LOAD_ADDRESS reg, label
_base\@:
    # Uses \@ to make a unique constant name for every expansion
    .equ _offset\@, (\label - _base\@)
    auipc   \reg, %hi(_offset\@)
    addi    \reg, \reg, %lo(_offset\@)
.endm

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

		# 1. Select Queue 0
		sw      zero, VIO_QUEUE_SEL(t0)

		# 2. Set Queue Size (let's use 16 descriptors)
		li      t1, 16
		sw      t1, VIO_QUEUE_NUM(t0)

		# 3. Set Page Size (QEMU default is usually 4096)
		# (In legacy MMIO, we provide the Page Frame Number)
		li      t1, 0x80001000 >> 12   # Assume our queue starts at 0x80001000
		sw      t1, VIO_QUEUE_PFN(t0)

		li      t1, 0x80001000      # Descriptor Table Base


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

.align 12
virtqueue_area: 
    .zero 4096    # Space for Desc Table, Avail Ring, and Used Ring

.align 4
disk_header:
    .word 0       # type: 0 = read
    .word 0       # reserved
    .dword 0      # sector: 0 (The very start of disk.img)

disk_status:
    .byte 0xff    # Initial value

.align 4
disk_buffer:
    .zero 512     # Destination for our data

