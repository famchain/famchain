_start:
	li	s6, 10		# constant used twice
	li	s5, 0x10000000
	auipc	s1, 0x0
	addi	s1, s1, 256
	mv	s2, s1
	li	s4, 0
	li 	s3, 0

# Loop
loop:
	# read byte
	lbu	t5, 5(s5)
	andi	t5, t5, 1
	beqz	t5, loop
	lbu	t1, 0(s5)

	# Check end of comment
	bne	t1, s6, not_backn # check newline
	li	s4, 0

not_backn:
	# Check start comment
	li	t3, '#'
	bne	t1, t3, skip_start_comment
	li	s4, 1

skip_start_comment:
	li	t3, 4 # End of message
	beq	t1, t3, end_loop

	bnez	s4, loop

	# skip whitespace
	li	t3, 33
	blt	t1, t3, loop

	addi	t1, t1, -48 # Subtract '0'
	bltu	t1, s6, store # if less than 10
	addi	t1, t1, -7
	li	t3, 16
	bltu	t1, t3, store
	j	loop

store:
	li	t3, 1
	beq	s3, t3, store_low
	li	s3, 1
	slli	t4, t1, 4
	j	loop

store_low:
	li	s3, 0
	or	t4, t4, t1
	sb	t4, 0(s2)
	addi	s2, s2, 1
	j	loop
end_loop:

output:
	beq	s1, s2, end_output
	lbu	t3, 0(s1)
	addi	s1, s1, 1

retry:
	lbu	t1, 5(s5)
	andi	t1, t1, 0x20
	beqz	t1, retry
	sb	t3, 0(s5)
	j	output

end_output:
	li	s5, 0x100000	# QEMU Virt Test Device
	li	t1, 0x5555	# Shutdown command
        sw	t1, 0(s5)

