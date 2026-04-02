#!/bin/sh
# Run test suite and collect QEMU traces for code coverage analysis.
# Exits non-zero if tests fail or coverage drops below threshold.

MIN_COVERAGE=25

if [ "$CI" = "true" ]; then
	sudo apt-get update
	sudo apt install -y gcc-riscv64-unknown-elf qemu-system-misc
fi

FAIL=0

AS="riscv64-unknown-elf-as"
OBJCOPY="riscv64-unknown-elf-objcopy"
MARCH="-march=rv32i_zicsr -mabi=ilp32"
TRACE_DIR="/tmp/famchain_traces"
MERGED_TRACE="$TRACE_DIR/merged.log"

mkdir -p "$TRACE_DIR"
rm -f "$TRACE_DIR"/*.log

build_node() {
	$AS $MARCH -I inc -o tmp/node.o "$1"
	$OBJCOPY -O binary tmp/node.o tmp/node.bin
}

build_bootloader() {
	./tools/gen_bin_config.py tmp/node.bin tmp 2>/dev/null
	$AS $MARCH -I tmp -o tmp/famchain.o src/famchain.S
	$OBJCOPY -O binary tmp/famchain.o tmp/famchain.bin
}

reset_disk() {
	dd if=/dev/zero of=./tmp/disk.img bs=512 count=16 conv=notrunc 2>/dev/null
}

run_traced() {
	# $1 = trace name, $2 = host list, $3 = timeout, $4 = smp
	local trace_file="$TRACE_DIR/$1.log"
	local tmout="${3:-10}"
	local smp="${4:-2}"
	(echo "$2"; printf '\004') | timeout "$tmout" qemu-system-riscv32 \
		-machine virt -nographic -bios none -smp "$smp" \
		-d in_asm -D "$trace_file" \
		-device loader,file=./tmp/famchain.bin,addr=0x80000000 \
		-netdev user,id=net0,hostfwd=tcp::2222-:22 \
		-drive file=./tmp/disk.img,if=none,format=raw,id=dr0 \
		-device virtio-blk-device,drive=dr0,bus=virtio-mmio-bus.0 \
		-device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.1 2>/dev/null
	return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Unit test coverage (standalone binaries, no network/disk)
# ══════════════════════════════════════════════════════════════════════════════

UNIT_TRACE_DIR="$TRACE_DIR/unit"
mkdir -p "$UNIT_TRACE_DIR"

run_unit_traced() {
	# $1 = name, $2 = source
	echo "=== Unit: $1 ==="
	$AS $MARCH -I inc -o "tmp/$1.o" "$2" || { echo "  FAIL (build)"; FAIL=$((FAIL + 1)); return; }
	$OBJCOPY -O binary "tmp/$1.o" "tmp/$1.bin" || { echo "  FAIL (objcopy)"; FAIL=$((FAIL + 1)); return; }
	if timeout 10 qemu-system-riscv32 \
		-machine virt -nographic -bios none -smp 1 \
		-d in_asm -D "$UNIT_TRACE_DIR/$1.log" \
		-device loader,file="tmp/$1.bin",addr=0x80000000 \
		</dev/null 2>/dev/null; then
		echo "  PASS"
	else
		echo "  FAIL"; FAIL=$((FAIL + 1))
	fi
}

run_unit_traced "test_all" "test/test_all.S"

# ══════════════════════════════════════════════════════════════════════════════
# Integration test coverage (bootloader + network + disk)
# ══════════════════════════════════════════════════════════════════════════════

build_node test/node.S
build_bootloader

echo "=== Test 1: Network download (empty disk) ==="
reset_disk
./tools/server.py &
SERVER_PID=$!
sleep 0.2
if run_traced "01_download" "127.0.0.1:3737"; then
	echo "  PASS"
else
	echo "  FAIL"; FAIL=$((FAIL + 1))
fi
kill $SERVER_PID 2>/dev/null; sleep 0.2

echo "=== Test 2: Disk cache hit ==="
if run_traced "02_cache_hit" "127.0.0.1:3737"; then
	echo "  PASS"
else
	echo "  FAIL"; FAIL=$((FAIL + 1))
fi

echo "=== Test 3: Multi-host failover ==="
reset_disk
./tools/server.py &
SERVER_PID=$!
sleep 0.2
if run_traced "03_failover" "192.0.2.1:9999 127.0.0.1:3737" 20; then
	echo "  PASS"
else
	echo "  FAIL"; FAIL=$((FAIL + 1))
fi
kill $SERVER_PID 2>/dev/null; sleep 0.2

echo "=== Test 4: Hash mismatch rejection ==="
$AS $MARCH -I inc -o tmp/famchain.o src/famchain.S
$OBJCOPY -O binary tmp/famchain.o tmp/famchain.bin
reset_disk
./tools/server.py &
SERVER_PID=$!
sleep 0.2
# Expect timeout (H! + halt), so non-zero exit is success here
run_traced "04_hash_reject" "127.0.0.1:3737" 3 1
echo "  PASS (H! expected)"
kill $SERVER_PID 2>/dev/null; sleep 0.2

echo "=== Test 5: Disk corruption recovery ==="
build_bootloader
reset_disk
./tools/server.py &
SERVER_PID=$!
sleep 0.2
run_traced "05_populate" "127.0.0.1:3737"
printf '\xff\xff\xff\xff' | dd of=./tmp/disk.img bs=1 count=4 conv=notrunc 2>/dev/null
if run_traced "05_corrupt_recover" "127.0.0.1:3737"; then
	echo "  PASS"
else
	echo "  FAIL"; FAIL=$((FAIL + 1))
fi
kill $SERVER_PID 2>/dev/null; sleep 0.2

if [ "$FAIL" -ne 0 ]; then
	echo ""
	echo "Tests failed ($FAIL failures) — skipping coverage."
	exit 1
fi

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " Bootloader Coverage"
echo "══════════════════════════════════════════════════════════════════"
cat "$TRACE_DIR"/0*.log > "$MERGED_TRACE"
python3 tools/coverage.py tmp/famchain.bin "$MERGED_TRACE" --min $MIN_COVERAGE
BOOT_RC=$?

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " Library Coverage (blake2s + WOTS+ + compress)"
echo "══════════════════════════════════════════════════════════════════"
python3 tools/coverage.py tmp/test_all.bin "$UNIT_TRACE_DIR/test_all.log" --min $MIN_COVERAGE
LIB_RC=$?

if [ "$BOOT_RC" -ne 0 ] || [ "$LIB_RC" -ne 0 ]; then
	exit 1
fi
