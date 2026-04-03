# famchain

A 4KB network bootloader for the fam cryptocurrency, written in RISC-V 32-bit assembly. It securely bootstraps a full node from a minimal trust root.

## What it does

famchain boots bare-metal on a RISC-V machine (QEMU virt), reads a seed peer list from UART, and loads the genesis binary (full node software). On first boot it downloads the binary from peers over UDP; on subsequent boots it loads from disk cache.

The genesis binary's blake2s hash is compiled into the bootloader. No code executes until the hash is verified. The network is untrusted transport — the hash is the only trust anchor.

## Bootstrapping chain

```
fam0 (188 bytes)  →  famchain (4KB)  →  genesis binary (famnode)
hex-to-binary seed    network bootloader    full node software
```

- **fam0**: A self-hosting hex-to-binary converter. Converts famchain's source (fam0 hex format) into a runnable binary.
- **famchain**: This project. Downloads and verifies the genesis binary.
- **famnode**: The full node (wallet, miner, validator). Downloaded and executed by famchain.

All binaries are distributed in fam0 hex format — human-readable hex with disassembly comments. The only binary you need to trust is the 188-byte fam0 seed.

## Boot sequence

1. Primary hart sets up gp/sp, secondary harts park on a mailbox
2. Parse seed peer list from UART (`ip:port ip:port...\004`)
3. Initialize virtio-net and virtio-blk
4. Read binary from disk, verify blake2s hash
5. If hash matches → jump to loaded binary (cache hit)
6. If mismatch → download from seed peers via UDP (FAMC protocol)
7. Verify downloaded binary's hash
8. Jump to binary with `a0` = seed list pointer, `a1` = hart mailbox

## Trust model

**Trusted:** The fam0 seed binary (188 bytes) and the genesis binary hash compiled into famchain.

**Verified:** The genesis binary — loaded from disk or network, always blake2s-verified before execution.

**Untrusted:** The network, seed peers, disk contents. A malicious peer can delay the download (by injecting bad chunks that fail the hash check) but cannot cause execution of unauthorized code.

## Building from source

Requires `riscv64-unknown-elf-as` (or set `RISCV_PREFIX`) and `qemu-system-riscv32`.

```sh
# Bootstrap: fam0 hex → binary via fam0 seed
(cat src/famchain.fam0; printf '\004') | qemu-system-riscv32 \
    -machine virt -nographic -bios none \
    -device loader,file=./fam0.seed,addr=0x80000000

# Or build from assembly source (requires GNU as):
riscv64-unknown-elf-as -march=rv32i_zicsr -mabi=ilp32 \
    -I inc -o tmp/famchain.o src/famchain.S
riscv64-unknown-elf-objcopy -O binary tmp/famchain.o tmp/famchain.bin
```

## Verifying

Rebuild from source and compare against the distributed fam0 hex:

```sh
# Build binary from assembly
tools/gen_bin_config.py <node_binary> inc
riscv64-unknown-elf-as -march=rv32i_zicsr -mabi=ilp32 \
    -I inc -o tmp/famchain.o src/famchain.S
riscv64-unknown-elf-objcopy -O binary tmp/famchain.o tmp/famchain.bin

# Convert to fam0 format and diff
python3 tools/bin2fam0.py tmp/famchain.bin tmp/famchain_check.fam0
diff <(sed 's/ #.*//' src/famchain.fam0) <(sed 's/ #.*//' tmp/famchain_check.fam0)
```

## Running

```sh
./famchain
```

Or manually:

```sh
(echo "seed1_ip:port seed2_ip:port"; printf '\004') | qemu-system-riscv32 \
    -machine virt -nographic -bios none -smp 2 \
    -device loader,file=./tmp/famchain.bin,addr=0x80000000 \
    -netdev user,id=net0 \
    -drive file=./disk.img,if=none,format=raw,id=dr0 \
    -device virtio-blk-device,drive=dr0,bus=virtio-mmio-bus.0 \
    -device virtio-net-device,netdev=net0,bus=virtio-mmio-bus.1
```

## Network protocol

The bootloader uses a simple UDP protocol with 4-byte magic (`FAMC`):

| Message | Code | Payload |
|---------|------|---------|
| REQ_RANGE | `0x02` | start_chunk (u16 BE), end_chunk (u16 BE) |
| RSP_CHUNK | `0x82` | seq (u16 BE), data (up to 1400 bytes) |

Chunks are tracked via a bitmap. Timeout per host is ~4 seconds; on timeout, the next seed host is tried. After all chunks are received, the binary is blake2s-verified.

## Error codes

| Output | Meaning |
|--------|---------|
| `F!` | All seed hosts failed (timeout or empty seed list) |
| `H!` | Hash mismatch after network download |
| `Z!` | Virtio device initialization error |

## Testing

```sh
.ci/runtests    # 10 integration tests
.ci/runcov      # tests + code coverage (100%)
```

## License

MIT
