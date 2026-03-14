# System Constants
.equ    UART_BASE,      0x10000000
.equ    UART_RD_MASK,   0x1
.equ    UART_WR_MASK,   0x20
.equ    UART_LSR,       5
.equ    UART_RBR,       0
.equ PLIC_BASE,    0x0c000000
.equ PLIC_PRIO_10, (PLIC_BASE + 0x28)     # 10 * 4 = 40 (0x28)
.equ PLIC_MENABLE, (PLIC_BASE + 0x2000)   # Machine Mode Enable
.equ PLIC_MTHRESH, (PLIC_BASE + 0x200000) # Machine Mode Threshold
.equ PLIC_MCLAIM,  (PLIC_BASE + 0x200004) # Claim/Complete Register


.macro LOAD_ADDRESS reg, label
_base\@:
    # Uses \@ to make a unique constant name for every expansion
    .equ _offset\@, (\label - _base\@)
    auipc   \reg, %hi(_offset\@)
    addi    \reg, \reg, %lo(_offset\@)
.endm

_start:
	jal		init_plic
	li		a0, 'x'
	jal		write_byte
	li		a0, '\n'
	jal		write_byte

	LOAD_ADDRESS	t0, trap_handler
	csrw		mtvec, t0

        li              a0, 'I'
        jal             write_byte
        li              a0, '\n'
        jal             write_byte

	ebreak

	li      t0, UART_BASE
	li      t1, 1            # Bit 0 of IER is "Received Data Available"
	sb      t1, 1(t0) 

	ebreak

    # Gate 1: Enable Machine External Interrupts in the 'mie' register
    li      t0, 0x800       # Bit 11 is MEIE (Machine External Interrupt Enable)
    csrs    mie, t0

    # Gate 2: Flip the master switch in 'mstatus'
    li      t0, 8           # Bit 3 is MIE (Global Machine Interrupt Enable)
    csrs    mstatus, t0



1:	wfi
	j		1b	


init_plic:
    # 1. Set UART (ID 10) Priority to 1
    li      t0, PLIC_PRIO_10
    li      t1, 1
    sw      t1, 0(t0)

    # 2. Enable ID 10 in the Enable Mask
    li      t0, PLIC_MENABLE
    li      t1, (1 << 10)
    sw      t1, 0(t0)

    # 3. Set Threshold to 0 (Allow all priorities > 0)
    li      t0, PLIC_MTHRESH
    sw      x0, 0(t0)
    ret

write_byte:
        li              t0, UART_BASE
1:
        lbu             t1, UART_LSR(t0)
        andi            t1, t1, UART_WR_MASK    # mask
        beqz            t1, 1b                  # retry
        sb              a0, UART_RBR(t0)        # send to UART
        ret

# --- The Trap Handler ---
.align 4                 # This is critical: mtvec target MUST be 4-byte aligned
trap_handler:
    csrr    t0, mcause      # Why are we here?
    bltz    t0, handle_int  # If bit 63 is 1, it's an Interrupt (Hardware)
    
    # --- It's an Exception (like ebreak) ---
    li      a0, 'E'         # 'E' for Exception
    jal     write_byte
    csrr    t1, mepc
    addi    t1, t1, 4       # Skip the ebreak
    csrw    mepc, t1
    mret

handle_int:
    # --- It's a Hardware Interrupt ---
    # 1. Claim from PLIC
    li      s10, PLIC_MCLAIM
    lw      a1, 0(s10)       # Get ID (10)

    # 2. Clear the UART (Crucial: Read the key)
    li      t1, UART_BASE
    lbu     t2, 0(t1)        # Read key to clear hardware flag
    
    # 3. Print the '!'
    li      a0, '!'
    jal     write_byte

    # 4. Complete to PLIC
    sw      a1, 0(s10)       # Write ID back to complete
    mret

