_start:
	li	t0, 0x10000000
	auipc	s1, 0x0
	addi	s1, s1, 256
	mv	s2, s1
	li	t6, 0
	li 	s3, 0

# Loop
loop:
	# read byte
	lbu	t5, 5(t0)
	andi	t5, t5, 1
	beqz	t5, loop
	lbu	t1, 0(t0)

	# Check end of comment
	li	t3, '\r'
	bne	t1, t3, not_backr
	li	t6, 0
not_backr:
	li	t3, '\n'
	bne	t1, t3, not_backn
	li	t6, 0
not_backn:

	# Check start comment
	li	t3, '#'
	bne	t1, t3, skip_start_comment
	li	t6, 1
skip_start_comment:

	li	t3, '.' # End of message
	beq	t1, t3, end_loop

	bnez	t6, loop

	sb	t1, 0(s2)
	addi	s2, s2, 1

	j	loop
end_loop:

output:
	beq	s1, s2, end_output
	lbu	t3, 0(s1)
	addi	s1, s1, 1
retry:
	lbu	t1, 5(t0)
	andi	t1, t1, 0x20
	beqz	t1, retry
	li	t4, '\r'
	beq	t3, t4, convert
	sb	t3, 0(t0)
	j	output
convert:
	li	t3, '\n'
	sb	t3, 0(t0)
	j output	
end_output:

	li	t0, 0x100000	# QEMU Virt Test Device
	li	t1, 0x5555	# Shutdown command
        sw	t1, 0(t0)

