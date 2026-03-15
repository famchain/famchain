.equ    UART_BASE,      0x10000000
.equ    UART_RD_MASK,   0x1
.equ    UART_WR_MASK,   0x20
.equ    UART_LSR,       5
.equ    UART_RBR,       0
.equ VIRTIO_DISK_BASE, 0x10001000
.equ VIRTIO_STATUS_OFF, 0x070

.macro LOAD_ADDRESS reg, label
_base\@:
    # Uses \@ to make a unique constant name for every expansion
    .equ _offset\@, (\label - _base\@)
    auipc   \reg, %hi(_offset\@)
    addi    \reg, \reg, %lo(_offset\@)
.endm

_start:
    li      t0, 0x10001000
    lw      s1, 0(t0)           # s1 now holds 0x74726976

    # 3. Print the Magic Value ('v', 'i', 'r', 't')
    # Byte 0: 'v' (0x76)
    andi    a0, s1, 0xFF
    jal     write_byte

    # Byte 1: 'i' (0x69)
    srli    a0, s1, 8
    andi    a0, a0, 0xFF
    jal     write_byte

    # Byte 2: 'r' (0x72)
    srli    a0, s1, 16
    andi    a0, a0, 0xFF
    jal     write_byte

    # Byte 3: 't' (0x74)
    srli    a0, s1, 24
    andi    a0, a0, 0xFF
    jal     write_byte

    # Print a newline
    li      a0, '\n'
    jal     write_byte

 li      t0, VIRTIO_DISK_BASE
    
    # 1. Reset the device (Write 0)
    # The device MUST initialize status to 0 upon reset.
    sw      x0, VIRTIO_STATUS_OFF(t0)

    # 2. Set ACKNOWLEDGE (1)
    # Tells the device the guest OS has found it.
    li      t1, 1
    sw      t1, VIRTIO_STATUS_OFF(t0)

    # 3. Set DRIVER (2)
    # Tells the device the guest OS knows how to drive it.
    # We "OR" it in, so the value becomes 3 (ACK | DRIVER).
    li      t1, 3
    sw      t1, VIRTIO_STATUS_OFF(t0)

    # 4. Verification
    # Read back to ensure the device accepted the bits.
    lw      a0, VIRTIO_STATUS_OFF(t0)

	li a0, 'x'
	jal write_byte
	li a0, '\n'
	jal write_byte

li      t0, VIRTIO_DISK_BASE
    
    # 1. Read Device Features (just to clear the register)
    lw      t2, 0x010(t0)
    
    # 2. Write Guest Features (We'll just write 0 for now to keep it simple)
    # This tells QEMU "I don't need any fancy features, just basic I/O"
    sw      x0, 0x020(t0)

    # 3. Set FEATURES_OK (8)
    # Current status is 3, so 3 | 8 = 11 (0x0B)
    li      t1, 11
    sw      t1, VIRTIO_STATUS_OFF(t0)

    # 4. Check if the device accepted FEATURES_OK
    lw      a1, VIRTIO_STATUS_OFF(t0)
    andi    t1, a1, 8
    beqz    t1, fail_features    # If bit 8 is gone, it failed

    # 5. Set DRIVER_OK (128)
    # Finalize the handshake. Status: 11 | 128 = 139 (0x8B)
    li      t1, 139
    sw      t1, VIRTIO_STATUS_OFF(t0)

    # Print 'f' to show features are OK
    li      a0, 'f'
    jal     write_byte
    li      a0, '\n'
    jal write_byte


    li      t0, VIRTIO_DISK_BASE
    
    # 1. Select Queue 0 (The only queue for a basic disk)
    li      t1, 0
    sw      t1, 0x030(t0)   # QueueSel

    # 2. Check Queue Size (Ensure 8 is supported)
    lw      t1, 0x034(t0)   # QueueNumMax
    li      t2, 8
    blt     t1, t2, fail_queue

    # 3. Set our chosen Queue Size
    sw      t2, 0x038(t0)   # QueueNum

    # 4. Set the Page Size (QEMU expects 4096)
    li      t1, 4096
    sw      t1, 0x028(t0)   # GuestPageSize

    # 5. Set the Physical Page Number (PFN)
    # PFN = Address / PageSize
    LOAD_ADDRESS t1, virtio_rings
    srli    t1, t1, 12      # Divide by 4096 to get PFN
    sw      t1, 0x040(t0)   # QueuePFN

    # Print 'q' to show queue is mapped
    li      a0, 'q'
    jal     write_byte
    li      a0, '\n'
    jal     write_byte


    li      t0, VIRTIO_DISK_BASE
    lw      a1, 0x034(t0)
    addi    a0, a1, '0'      # If it's 8, should print '8' (or higher)
    jal     write_byte


LOAD_ADDRESS t0, virtio_rings

    # Descriptor 0: The Header (Tells disk: READ Sector 0)
    LOAD_ADDRESS t1, disk_request_header
    sd      t1, 0(t0)                # addr
    li      t2, 16                   # len
    sw      t2, 8(t0)                # len
    li      t2, 1                    # flags: VIRTQ_DESC_F_NEXT (1)
    sh      t2, 12(t0)
    li      t2, 1                    # next index
    sh      t2, 14(t0)

    # Descriptor 1: The Data Buffer (Where data will go)
    LOAD_ADDRESS t1, disk_data_buffer
    sd      t1, 16(t0)               # addr (Desc 0 is 16 bytes)
    li      t2, 512                  # len
    sw      t2, 24(t0)               # len
    li      t2, 3                    # flags: NEXT (1) | WRITE (2)
    sh      t2, 28(t0)
    li      t2, 2                    # next index
    sh      t2, 30(t0)

    # Descriptor 2: The Status Byte (Device writes result here)
    LOAD_ADDRESS t1, disk_status_byte
    sd      t1, 32(t0)               # addr (Desc 1 is 16 bytes)
    li      t2, 1                    # len
    sw      t2, 40(t0)               # len
    li      t2, 2                    # flags: WRITE (2) only
    sh      t2, 44(t0)
    sh      x0, 46(t0)               # next: 0

    li a0, 'v'
    jal write_byte
    li a0, '\n'
    jal write_byte


    LOAD_ADDRESS t0, virtio_rings
    # --- 2. Update Available Ring (Starts at offset 128) ---
    addi    t3, t0, 128              
    
    # ring[0] = 0 (Start with descriptor index 0)
    li      t1, 0                    
    sh      t1, 4(t3)                

    # fence ensures the descriptors are in RAM before the device sees them
    fence   ow, rw                   

    # idx = 1 (We have submitted 1 total request chain)
    li      t1, 1                    
    sh      t1, 2(t3)                

    fence   ow, rw

    # --- 3. The Kick (Notify Queue 0) ---
    li      t4, VIRTIO_DISK_BASE
    li      t1, 0                    # Queue 0
    sw      t1, 0x050(t4)            # QueueNotify

    li      a0, 'k'                  # 'k' for Kicked
    jal     write_byte
    li      a0, '\n'
    jal     write_byte

  LOAD_ADDRESS t0, disk_status_byte
wait_for_disk:
    lbu     t1, 0(t0)
    li      t2, 0xFF

    beq     t1, t2, wait_for_disk    # Loop until it's not 0xFF
    li a0, 'u'
    jal write_byte

    # Check if success (0) or error
    bnez    t1, disk_error

    # Success! Print 'D' for Data
    li      a0, 'D'
    jal     write_byte

    # --- Print the first byte of the actual disk data ---
    LOAD_ADDRESS t0, disk_data_buffer
    lbu     a0, 0(t0)                # Grab first byte from Sector 0
    jal     write_byte
    j       finished

disk_error:
    li      a0, '!'
    jal     write_byte

finished:
    li      a0, 'p'
    jal write_byte
    li      a0, '\n'
    jal     write_byte


5: wfi
j 5b
fail_queue:
    li      a0, 'Q'
    jal     write_byte


fail_features:

    li a0, '%'
    jal write_byte

1:  wfi
    j 1b

write_byte:
        li              t0, UART_BASE
1:
        lbu             t1, UART_LSR(t0)
        andi            t1, t1, UART_WR_MASK    # mask
        beqz            t1, 1b                  # retry
        sb              a0, UART_RBR(t0)        # send to UART
        ret

.align 8
disk_request_header:
    .word   0                # Type: 0 = Read, 1 = Write
    .word   0                # Reserved
    .quad   0                # Sector Number (Sector 0)

# --- The Virtqueue Rings ---
# Alignment 12 = 4096 bytes. 
# We need enough space for:
# 1. Descriptor Table (128 bytes)
# 2. Available Ring (32 bytes)
# 3. Padding to page boundary (approx 3.9KB)
# 4. Used Ring (approx 100 bytes)
.align 12
virtio_rings:       .space 4096 * 2  # 8KB total

.align 8
disk_data_buffer:   .space 512       # Where the sector data will land
disk_status_byte:   .byte 0xFF       # Initialized to 0xFF (Device sets to 0 on success)

