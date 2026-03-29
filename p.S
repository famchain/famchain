.equ    UART_BASE,              0x10000000
.equ    UART_LSR,               5
.equ    UART_WR_MASK,           0x20

li              t1, UART_BASE
li		t0, '9'
sb              t0, 0(t1)
1:		wfi
j		1b
