#!/bin/sh

riscv64-unknown-elf-as -o bin/famc.o src/famc.S || exit 1
riscv64-unknown-elf-objcopy -O binary bin/famc.o bin/famc.bin || exit 1

#cat tmp/test.fam | qemu-system-riscv64 -machine virt -nographic  -bios none -device loader,file=./bin/famc.bin,addr=0x80000000 | tee ./bin/test.bin > /dev/null

(cat tmp/test.fam; printf '\004') | qemu-system-riscv64 -machine virt -nographic -bios none -device loader,file=./bin/famc.bin,addr=0x80000000 | tee ./bin/test.bin > /dev/null


echo "test.fam input:"
cat tmp/test.fam
#echo "test.bin output:"
#hexdump -v -e '4/1 "%02X " "\n"' bin/test.bin
MAGIC=$(head -c 4 bin/test.bin | xxd -p)

if [ "$MAGIC" = "13000000" ]; then
    echo "test.bin output:"
    hexdump -v -e '4/1 "%02X " "\n"' bin/test.bin
else
    echo "Error compiling test file:"
    cat bin/test.bin
    # Optional: remove the garbage binary so you don't accidentally run it
    rm bin/test.bin
fi

