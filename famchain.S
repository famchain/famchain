# --- System Constants ---
.equ UART_BASE,		0x10000000
.equ UART_LSR,		5
.equ UART_WR_MASK,	0x20
.equ VIRTIO_DISK_BASE,	0x10001000	
.equ VIO_MAGIC,		0x000
.equ VIO_DEVICE_ID,	0x008
.equ VIO_STATUS,	0x070

.equ VIO_QUEUE_SEL,	0x030
.equ VIO_QUEUE_NUM,	0x038
.equ VIO_QUEUE_PFN,	0x040

.macro LOAD_ADDRESS reg, label
_base\@:
	# Uses \@ to make a unique constant name for every expansion
	.equ _offset\@, (\label - _base\@)
	auipc	\reg, %hi(_offset\@)
	addi	\reg, \reg, %lo(_offset\@)
.endm

_start:
		li	t0, VIRTIO_DISK_BASE
		lw	t1, VIO_MAGIC(t0)	# Should be 0x74726976 ("virt")
		li	t2, 0x74726976
		bne	t1, t2, error_not_virtio
	
		lw	t1, VIO_DEVICE_ID(t0)	# Should be 2 for Block Device
		li	t2, 2
		bne	t1, t2, error_not_disk

		# 1. Reset the device
		sw	zero, VIO_STATUS(t0)

		# 2. Set ACKNOWLEDGE bit (1)
		li	t1, 1
		sw	t1, VIO_STATUS(t0)

		# 3. Set DRIVER bit (2)
		lw	t1, VIO_STATUS(t0)
		ori	t1, t1, 2
		sw	t1, VIO_STATUS(t0)

		# 4. Set FEATURES_OK bit (8)
		lw	t1, VIO_STATUS(t0)
		ori	t1, t1, 8
		sw	t1, VIO_STATUS(t0)

		# 5. Check if FEATURES_OK was accepted
		lw	t1, VIO_STATUS(t0)
		andi	t2, t1, 8
		beqz	t2, error_features_not_supported

		# 6. Set DRIVER_OK bit (4) - Device is now "Live"
		lw	t1, VIO_STATUS(t0)
		ori	t1, t1, 4
		sw	t1, VIO_STATUS(t0)

		# 1. Select Queue 0
		sw	zero, VIO_QUEUE_SEL(t0)

		# 2. Set Queue Size (let's use 16 descriptors)
		li	t1, 16
		sw	t1, VIO_QUEUE_NUM(t0)

		# 3. Set Page Size (QEMU default is usually 4096)
		# (In legacy MMIO, we provide the Page Frame Number)
		LOAD_ADDRESS t1 data
		addi	t1, t1, 512
		sw	t1, VIO_QUEUE_PFN(t0)

		li	t1, 0x80001000	# Descriptor Table Base

li      s8, 0
li	s9, 11
li s10, 0   # Total requests sent

77:
	bge s8, s9, 78f
	# --- Execute the Read ---
	# 1. Setup Descriptor 0 (Header)
	LOAD_ADDRESS t1, data # Base of Descriptor Table
	addi    t1, t1, 512
	LOAD_ADDRESS t2, disk_header
	sw s8, 8(t2)
	sw	t2, 0(t1)		# Addr
	sw	zero, 4(t1)
	li	t2, 16
	sw	t2, 8(t1)		# Len
	li	t2, 1		# NEXT flag
	sh	t2, 12(t1)		# Flags
	li	t2, 1
	sh	t2, 14(t1)		# Next index = 1


LOAD_ADDRESS t1, data # Base of Descriptor Table
addi    t1, t1, 512

# 2. Setup Descriptor 1 (Data Buffer)
LOAD_ADDRESS t2, data
sw	t2, 16(t1)		# Addr
sw	zero, 20(t1)

li	t2, 512
sw	t2, 24(t1)		# Len
li	t2, 3		# NEXT | WRITE flags
sh	t2, 28(t1)		# Flags
li	t2, 2
sh	t2, 30(t1)		# Next index = 2


LOAD_ADDRESS t1, data # Base of Descriptor Table
addi    t1, t1, 512

# 3. Setup Descriptor 2 (Status Byte)
LOAD_ADDRESS t2, disk_status
sw	t2, 32(t1)		# Addr (Table + 32)
sw	zero, 36(t1)
li	t2, 1
sw	t2, 40(t1)		# Len
li	t2, 2		# WRITE flag
sh	t2, 44(t1)		# Flags
sh	zero, 46(t1)		# Next = 0 (End)

LOAD_ADDRESS t1, data # Base of Descriptor Table
addi    t1, t1, 512
LOAD_ADDRESS t2, disk_status

# 4. Notify the Available Ring
# Available Ring starts at offset 256 (after 16 descriptors)
addi	t3, t1, 256		
li	t2, 0
sh	t2, 4(t3)		# Set ring[0] = 0 (Start at Desc 0)
addi    s10, s10, 1
sh	s10, 2(t3)		# Set idx = 1 (We have 1 chain ready)

LOAD_ADDRESS t1, disk_status
li s4, 0xFF
sb s4, 0(t1)

# 5. Kick the hardware
li	t0, 0x10001000		# VIRTIO_DISK_BASE
sw	zero, 0x050(t0)		# Notify Queue 0

# 6. Wait for disk_status to change from 0xFF
wait_read:
	LOAD_ADDRESS t1, disk_status
	lbu	t2, 0(t1)
	li	t3, 0xFF
	beq	t2, t3, wait_read

# Read complete!

# Load the first byte of the disk buffer
LOAD_ADDRESS s1, data
1:
lbu	a0, 0(s1)	# Get the first character from the 512 bytes
beqz a0, 2f
jal	write_byte	# Print it to the UART
addi s1, s1, 1
j 1b
2:


addi s8, s8, 1
j 77b
78:

                li a0, '\n'
                jal write_byte


1:		wfi	
		j 1b

error_not_virtio:
		li a0, '0'
		jal write_byte
		li a0, '\n'
1:		wfi	
		j 1b

error_not_disk:
		li a0, '1'
		jal write_byte
		li a0, '\n'
1:		wfi
		j 1b

error_features_not_supported:
		li a0, '2'
		jal write_byte
		li a0, '\n'
1:		wfi
		j 1b

write_byte: 
	li	t1, UART_BASE
101:	lbu	t2, UART_LSR(t1)
	andi	t2, t2, UART_WR_MASK
	beqz	t2, 101b
	sb	a0, 0(t1)
	ret	

disk_header:
	.word 0	# type: 0 = read
	.word 0	# reserved
	.dword 0	# sector: 0 (The very start of disk.img)

disk_status:
	.byte 0xff	# Initial value
data:
