#!/bin/sh

riscv64-unknown-elf-as -o bin/fam0.o src/fam0.S
riscv64-unknown-elf-objcopy -O binary bin/fam0.o bin/fam0.bin

(cat tmp/test.fam0; printf '\004') | qemu-system-riscv64 -machine virt -nographic  -bios none -device loader,file=./bin/fam0.bin,addr=0x80000000 | tee ./bin/test.bin > /dev/null
hexdump -C bin/test.bin
