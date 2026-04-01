#!/bin/sh

# Build fam0 from seed binary
(cat src/fam0.fam0; printf '\004') | qemu-system-riscv32 \
	-machine virt \
	-nographic \
	-bios none \
	-device loader,file=./fam0.seed,addr=0x80000000 \
	| tee ./tmp/fam0.bin > /dev/null

cmp ./tmp/fam0.bin ./fam0.seed || { echo "binaries don't match!"; exit 1; }

echo "Bootstrap successful!";
