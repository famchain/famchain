#!/bin/sh
# run_tests.sh — build and run all tests

set -e

TESTS_DIR="$(dirname "$0")"
TMP_DIR="$TESTS_DIR/../tmp"
AS="riscv64-unknown-elf-as"
OBJCOPY="riscv64-unknown-elf-objcopy"
MARCH="-march=rv32i -mabi=ilp32"

run_test() {
    name="$1"
    src="$TESTS_DIR/$name.S"
    obj="$TMP_DIR/$name.o"
    bin="$TMP_DIR/$name.bin"

    echo "=== $name ==="
    $AS $MARCH -I "$TESTS_DIR/../inc" -o "$obj" "$src"
    $OBJCOPY -O binary "$obj" "$bin"

    output=$(timeout 10 qemu-system-riscv32 \
        -machine virt \
        -nographic \
        -bios none \
        -smp 1 \
        -device loader,file="$bin",addr=0x80000000 </dev/null 2>/dev/null || true)

    echo "$output"

    if echo "$output" | grep -q "FAIL"; then
        echo "*** FAILED ***"
        exit 1
    fi
    if ! echo "$output" | grep -q "PASS"; then
        echo "*** NO OUTPUT ***"
        exit 1
    fi
    echo ""
}

run_test test_blake2s

echo "All tests passed."
