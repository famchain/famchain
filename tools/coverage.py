#!/usr/bin/env python3
"""Code coverage for bare-metal RISC-V binaries via QEMU trace.

Usage:
    1. Run QEMU with: -d in_asm -D trace.log
    2. python3 coverage.py <binary> <trace.log> [--base 0x80000000]

Reports which instructions/functions were executed vs total.
"""
import re
import subprocess
import sys
import os

def get_labels(binfile):
    """Get label addresses from nm if .o file exists, otherwise from objdump."""
    ofile = binfile.replace('.bin', '.o')
    labels = {}
    if os.path.exists(ofile):
        result = subprocess.run(
            ['riscv64-unknown-elf-nm', ofile],
            capture_output=True, text=True
        )
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[1] in ('t', 'T'):
                addr = int(parts[0], 16)
                name = parts[2]
                # Skip internal macro labels
                if name.startswith('_base') or name.startswith('_offset'):
                    continue
                labels[addr] = name
    return labels

def get_all_pcs(binfile):
    """Get all instruction PCs from objdump."""
    result = subprocess.run(
        ['riscv64-unknown-elf-objdump', '-D', '-m', 'riscv:rv32', '-b', 'binary', binfile],
        capture_output=True, text=True
    )
    pcs = set()
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or line[0] not in '0123456789abcdef':
            continue
        parts = line.split('\t')
        if len(parts) < 3:
            continue
        try:
            pc = int(parts[0].rstrip(':'), 16)
            pcs.add(pc)
        except ValueError:
            continue
    return pcs

def parse_trace(tracefile, base):
    """Parse QEMU -d in_asm trace log for executed PCs."""
    executed = set()
    pc_pattern = re.compile(r'^0x([0-9a-f]+):')
    with open(tracefile, 'r') as f:
        for line in f:
            m = pc_pattern.match(line.strip())
            if m:
                addr = int(m.group(1), 16)
                if addr >= base:
                    executed.add(addr - base)
    return executed

def find_function(pc, labels):
    """Find which function a PC belongs to."""
    best_name = None
    best_addr = -1
    for addr, name in labels.items():
        if addr <= pc and addr > best_addr:
            best_addr = addr
            best_name = name
    return best_name or f"<unknown@0x{pc:x}>"

def find_data_start(binfile):
    """Detect where data section starts (same heuristic as bin2fam0.py)."""
    result = subprocess.run(
        ['riscv64-unknown-elf-objdump', '-D', '-m', 'riscv:rv32', '-b', 'binary', binfile],
        capture_output=True, text=True
    )
    invalid_markers = {'.insn', 'unimp', '???'}
    fp_prefixes = {'fsw', 'flw', 'fsd', 'fld', 'fmv', 'fadd', 'fsub', 'fmul', 'fdiv'}

    pcs_valid = {}
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or line[0] not in '0123456789abcdef':
            continue
        parts = line.split('\t')
        if len(parts) < 3:
            continue
        try:
            pc = int(parts[0].rstrip(':'), 16)
            asm = '\t'.join(parts[2:]).strip()
            mnemonic = asm.split()[0] if asm else '???'
            is_valid = (mnemonic not in invalid_markers and
                       mnemonic not in fp_prefixes and
                       not (mnemonic.startswith('f') and mnemonic not in ('fence',)))
            pcs_valid[pc] = is_valid
        except (ValueError, IndexError):
            continue

    # Find the final code-to-data transition.
    # Skip small embedded data (IV tables etc.) — only trigger on a sustained
    # run of bad instructions near the end of the binary.
    sorted_pcs = sorted(pcs_valid.keys())
    WINDOW = 16
    # Scan backwards from the end to find where code last resumes
    for i in range(len(sorted_pcs) - 1, -1, -1):
        if pcs_valid[sorted_pcs[i]]:
            # Found last valid instruction. Data starts after the next
            # sustained run of bad instructions following it.
            for j in range(i + 1, len(sorted_pcs)):
                if not pcs_valid[sorted_pcs[j]]:
                    end = min(j + WINDOW, len(sorted_pcs))
                    bad = sum(1 for k in range(j, end) if not pcs_valid[sorted_pcs[k]])
                    if bad >= (end - j) * 3 // 4:
                        return sorted_pcs[j]
            return max(pcs_valid.keys()) + 4
    return max(pcs_valid.keys()) + 4 if pcs_valid else 0

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <binary> <trace.log> [--base 0x80000000] [--min 95]", file=sys.stderr)
        sys.exit(1)

    binfile = sys.argv[1]
    tracefile = sys.argv[2]
    base = 0x80000000
    min_coverage = 0.0
    for i, arg in enumerate(sys.argv):
        if arg == '--base' and i + 1 < len(sys.argv):
            base = int(sys.argv[i + 1], 0)
        if arg == '--min' and i + 1 < len(sys.argv):
            min_coverage = float(sys.argv[i + 1])

    # Get all instruction PCs and data boundary
    all_pcs = get_all_pcs(binfile)
    data_start = find_data_start(binfile)
    code_pcs = {pc for pc in all_pcs if pc < data_start}

    # Get labels
    labels = get_labels(binfile)

    # Parse trace
    executed = parse_trace(tracefile, base)
    executed_code = executed & code_pcs

    # Identify embedded data islands: label ranges where most instructions are invalid.
    # Also detect via pcs_valid from objdump — data bytes often decode as invalid.
    all_pcs_valid = {}
    result = subprocess.run(
        ['riscv64-unknown-elf-objdump', '-D', '-m', 'riscv:rv32', '-b', 'binary', binfile],
        capture_output=True, text=True
    )
    invalid_markers = {'.insn', 'unimp', '???'}
    fp_prefixes = {'fsw', 'flw', 'fsd', 'fld', 'fmv', 'fadd', 'fsub', 'fmul', 'fdiv'}
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or line[0] not in '0123456789abcdef':
            continue
        parts = line.split('\t')
        if len(parts) < 3:
            continue
        try:
            pc = int(parts[0].rstrip(':'), 16)
            asm = '\t'.join(parts[2:]).strip()
            mnemonic = asm.split()[0] if asm else '???'
            is_valid = (mnemonic not in invalid_markers and
                       mnemonic not in fp_prefixes and
                       not (mnemonic.startswith('f') and mnemonic not in ('fence',)))
            all_pcs_valid[pc] = is_valid
        except (ValueError, IndexError):
            continue

    # Known data label prefixes (constants, strings, test vectors)
    DATA_PREFIXES = ('tv_', 'tn_', '_str_', '_b2s_iv', '_b2s_h_init', '_b2s_sigma',
                     'b2s_iv', 'b2s_sigma', 'b2s_g_idx', 'expected_hash',
                     '_wots_domain', '_test_data')

    data_labels = set()
    func_addrs = sorted(labels.keys())
    for i, addr in enumerate(func_addrs):
        name = labels[addr]
        end = func_addrs[i + 1] if i + 1 < len(func_addrs) else data_start
        if addr >= data_start:
            continue
        # Exclude by name pattern
        if any(name.startswith(p) or name == p for p in DATA_PREFIXES):
            data_labels.add(name)
            continue
        # Exclude by content heuristic: mostly invalid instructions = data
        range_pcs = [pc for pc in sorted(all_pcs_valid.keys()) if addr <= pc < end]
        if not range_pcs:
            continue
        invalid_count = sum(1 for pc in range_pcs if not all_pcs_valid.get(pc, True))
        if invalid_count > len(range_pcs) * 0.4:
            data_labels.add(name)

    # Exclude data islands from code PCs
    for i, addr in enumerate(func_addrs):
        if labels.get(addr) in data_labels:
            end = func_addrs[i + 1] if i + 1 < len(func_addrs) else data_start
            code_pcs -= {pc for pc in code_pcs if addr <= pc < end}

    # Recompute coverage with data excluded
    total = len(code_pcs)
    hit = len(executed_code & code_pcs)
    missed = code_pcs - executed_code
    pct = (hit / total * 100) if total > 0 else 0

    print(f"Code coverage: {hit}/{total} instructions ({pct:.1f}%)")
    if data_labels:
        print(f"Data labels excluded: {len(data_labels)} ({', '.join(sorted(data_labels)[:5])}{'...' if len(data_labels) > 5 else ''})")
    print()

    # Per-function coverage
    func_ranges = []
    for i, addr in enumerate(func_addrs):
        end = func_addrs[i + 1] if i + 1 < len(func_addrs) else data_start
        if addr < data_start and labels[addr] not in data_labels:
            func_ranges.append((addr, end, labels[addr]))

    print(f"{'Function':<30s} {'Hit':>5s} {'Total':>5s} {'Pct':>6s}  {'Status'}")
    print("─" * 70)

    uncovered_funcs = []
    for start, end, name in func_ranges:
        func_pcs = {pc for pc in code_pcs if start <= pc < end}
        func_hit = func_pcs & executed_code
        func_total = len(func_pcs)
        func_count = len(func_hit)
        if func_total == 0:
            continue
        func_pct = func_count / func_total * 100
        if func_pct == 100:
            status = "✓"
        elif func_pct == 0:
            status = "✗ UNCOVERED"
            uncovered_funcs.append(name)
        else:
            status = "~ partial"
        print(f"{name:<30s} {func_count:>5d} {func_total:>5d} {func_pct:>5.1f}%  {status}")

    # List missed instructions by function
    if missed:
        print()
        print("Uncovered instructions:")
        print("─" * 70)
        by_func = {}
        for pc in sorted(missed):
            func = find_function(pc, labels)
            by_func.setdefault(func, []).append(pc)

        # Find each function's base address for offset display
        func_bases = {}
        for addr, name in labels.items():
            func_bases[name] = addr

        for func, pcs in sorted(by_func.items(), key=lambda x: x[1][0]):
            base = func_bases.get(func, 0)
            pc_strs = [f"{func}+{(pc - base) // 4}" for pc in pcs[:8]]
            suffix = f" ... +{len(pcs)-8} more" if len(pcs) > 8 else ""
            print(f"  {', '.join(pc_strs)}{suffix}")

    # Exit with failure if below minimum coverage threshold
    if min_coverage > 0:
        print()
        if pct >= min_coverage:
            print(f"Coverage {pct:.1f}% >= {min_coverage}% threshold: PASS")
        else:
            print(f"Coverage {pct:.1f}% < {min_coverage}% threshold: FAIL")
            sys.exit(1)

if __name__ == '__main__':
    main()
