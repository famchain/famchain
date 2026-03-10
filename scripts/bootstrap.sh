#!/bin/sh

# Clean directory
rm -fr bin/*

# Build fam0 from seed binary
cat src/fam0.fam0 | qemu-system-riscv64 \
	-machine virt \
	-nographic \
	-bios none \
	-device loader,file=./fam0.seed,addr=0x80000000 \
	| tee ./bin/fam0.bin > /dev/null

cmp ./bin/fam0.bin ./fam0.seed || { echo "binaries don't match!"; exit 1; }
