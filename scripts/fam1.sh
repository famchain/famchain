#!/bin/sh

riscv64-unknown-elf-as -o bin/fam1.o src/fam1.s || exit 1
riscv64-unknown-elf-objcopy -O binary bin/fam1.o bin/fam1.bin || exit 1

qemu-system-riscv64 \
	-machine virt -nographic \
	-bios none \
	-device loader,file=./bin/fam1.bin,addr=0x80000000 \
	| tee ./bin/test.bin > /dev/null

cat ./bin/test.bin
