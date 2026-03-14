#!/bin/sh

riscv64-unknown-elf-as -o bin/famos.o src/famos.S || exit 1
riscv64-unknown-elf-objcopy -O binary bin/famos.o bin/famos.bin || exit 1

qemu-system-riscv64 \
	-machine virt \
	-nographic \
	-bios none \
	-smp 4 \
	-device loader,file=./bin/famos.bin,addr=0x80000000 

