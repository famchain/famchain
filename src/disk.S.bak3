# --- System Constants ---
.equ UART_BASE,         0x10000000
.equ UART_LSR,          5
.equ UART_WR_MASK,      0x20
.equ VIRTIO_DISK_BASE,  0x10001000
.equ VIO_MAGIC,         0x000
.equ VIO_DEVICE_ID,     0x008
.equ VIO_STATUS,        0x070

.section .text
.global _start

_start:
    # 1. Probe Magic Value (Check Address)
    li      t0, VIRTIO_DISK_BASE
    lw      s1, VIO_MAGIC(t0)
    
    # Print 'virt'
    andi    a0, s1, 0xFF
    jal     write_byte
    srli    a0, s1, 8
    andi    a0, a0, 0xFF
    jal     write_byte
    srli    a0, s1, 16
    andi    a0, a0, 0xFF
    jal     write_byte
    srli    a0, s1, 24
    andi    a0, a0, 0xFF
    jal     write_byte
    
    li      a0, '\n'
    jal     write_byte

    # 2. Probe Device ID (Check if it's actually a Disk)
    lw      s2, VIO_DEVICE_ID(t0)
    addi    a0, s2, '0'        # Should print '2'
    jal     write_byte
    li      a0, '\n'
    jal     write_byte

    # 3. Reset the Device
    sw      x0, VIO_STATUS(t0)
    
    # Print 'x' for Reset Success
    li      a0, 'x'
    jal     write_byte
    li      a0, '\n'
    jal     write_byte

    # 1. Set ACKNOWLEDGE (1)
    li      t1, 1
    sw      t1, VIO_STATUS(t0)

    # 2. Set DRIVER (2)
    # Total status now 3 (ACK | DRIVER)
    li      t1, 3
    sw      t1, VIO_STATUS(t0)

    # 3. Set DRIVER_OK (128)
    # Total status now 131 (ACK | DRIVER | DRIVER_OK)
    li      t1, 131
    sw      t1, VIO_STATUS(t0)

    # 4. Verify Handshake
    lw      s3, VIO_STATUS(t0)
    li      t1, 131
    bne     s3, t1, fail_handshake

    # Print 'f' for finished handshake
    li      a0, 'f'
    jal     write_byte
    li      a0, '\n'
    jal     write_byte
    
    j       next_phase

fail_handshake:
    li      a0, 'F'
    jal     write_byte
    j       halt
    
next_phase:

    # 1. Select Queue 0
    li      t1, 0
    sw      t1, 0x030(t0)        # QueueSel

    # 2. Set Queue Size to 8
    li      t1, 8
    sw      t1, 0x038(t0)        # QueueNum

    # 3. Set Page Size to 4096
    li      t1, 4096
    sw      t1, 0x028(t0)        # GuestPageSize

    # 4. Map the PFN
    # We use 'la' if your assembler allows it, otherwise use your LOAD macro
    la      t1, virtio_rings
    srli    t1, t1, 12           # PFN = Address / 4096
    sw      t1, 0x040(t0)        # QueuePFN

    # 5. Verify the PFN stuck
    lw      t2, 0x040(t0)
    beq     t1, t2, 1f
    li      a0, 'Q'              # 'Q' for Queue Map Failure
    jal     write_byte
    j       halt

1:  li      a0, 'q'              # 'q' for Queue Map Success
    jal     write_byte
    li      a0, '\n'
    jal     write_byte

    # 1. Fill Descriptor 0: The Header
    la      t0, virtio_rings
    la      t1, disk_req_header
    sd      t1, 0(t0)                # addr
    li      t2, 16                   # len
    sw      t2, 8(t0)
    li      t2, 1                    # flags: NEXT
    sh      t2, 12(t0)
    li      t2, 1                    # next index: 1
    sh      t2, 14(t0)

    # 2. Fill Descriptor 1: The Data Buffer
    la      t1, disk_data_buf
    sd      t1, 16(t0)               # addr (Desc 0 is 16 bytes)
    li      t2, 512                  # len
    sw      t2, 24(t0)
    li      t2, 3                    # flags: NEXT | WRITE (1|2)
    sh      t2, 28(t0)
    li      t2, 2                    # next index: 2
    sh      t2, 30(t0)

    # 3. Fill Descriptor 2: The Status Byte
    la      t1, disk_stat_byte
    sd      t1, 32(t0)               # addr (Desc 1 is 16 bytes)
    li      t2, 1                    # len
    sw      t2, 40(t0)
    li      t2, 2                    # flags: WRITE (2)
    sh      t2, 44(t0)
    sh      x0, 46(t0)               # next: 0

    # 4. Update Available Ring (Starts at virtio_rings + 128)
    addi    t3, t0, 128
    li      t1, 0
    sh      t1, 4(t3)                # ring[0] = Descriptor 0
    
    fence   ow, rw                   # Sync RAM
    
    li      t1, 1
    sh      t1, 2(t3)                # idx = 1 (The Doorbell)
    
    fence   ow, rw

    # 5. THE KICK
    li      t4, VIRTIO_DISK_BASE
    li      t1, 0                    # Queue 0
    sw      t1, 0x050(t4)            # QueueNotify

    # 6. POLL FOR SUCCESS
    la      s5, disk_stat_byte
wait_disk:
    lbu     t1, 0(s5)
    li      t2, 0xFF
    beq     t1, t2, wait_disk        # Spin until not 0xFF

    # 7. PRINT RESULT
    bnez    t1, read_fail            # If status != 0, error
    li      a0, 'D'                  # 'D' for Data Success
    jal     write_byte
    
    la      t0, disk_data_buf
    lbu     a0, 0(t0)                # Read first char of disk.img
    jal     write_byte
    j       halt

read_fail:
    li      a0, 'E'
    jal     write_byte
    j       halt

halt:
    wfi
    j       halt

write_byte:
    li      t1, UART_BASE
1:  lbu     t2, UART_LSR(t1)
    andi    t2, t2, UART_WR_MASK
    beqz    t2, 1b
    sb      a0, 0(t1)
    ret

# --- Add this to the very bottom of your file ---
.align 12
virtio_rings:       .zero 8192
.align 8
disk_req_header: .word 0, 0          # Type: Read (0)
                 .quad 0             # Sector: 0
disk_stat_byte:  .byte 0xFF
.align 8
disk_data_buf:   .space 512
