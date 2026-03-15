#!/bin/sh

riscv64-unknown-elf-as -o bin/disk.o src/disk.S || exit 1
riscv64-unknown-elf-objcopy -O binary bin/disk.o bin/disk.bin || exit 1

qemu-system-riscv64 \
    -machine virt \
    -nographic \
    -bios none \
    -device loader,file=./bin/disk.bin,addr=0x80000000 \
    -drive file=./tmp/disk.img,if=none,format=raw,id=dr0 \
    -device virtio-blk-device,drive=dr0

