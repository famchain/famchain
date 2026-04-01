#!/usr/bin/env python3
"""Generate bin_config.inc from a binary file.

Usage: python3 gen_bin_config.py <binary> [output_dir]

If output_dir is specified, writes bin_config.inc there.
Otherwise writes to stdout.
"""
import hashlib, struct, sys, os

if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} <binary> [output_dir]", file=sys.stderr)
    sys.exit(1)

data = open(sys.argv[1], 'rb').read()
h = hashlib.new('blake2s', data, digest_size=32).digest()
words = struct.unpack('<8I', h)

lines = [
    f"# bin_config.inc — auto-generated from {os.path.basename(sys.argv[1])}",
    f".equ\tBIN_SIZE,\t\t{len(data)}",
]
for i, w in enumerate(words):
    lines.append(f".equ\tBIN_HASH{i},\t\t0x{w:08X}")

output = '\n'.join(lines) + '\n'

if len(sys.argv) >= 3:
    path = os.path.join(sys.argv[2], 'bin_config.inc')
    with open(path, 'w') as f:
        f.write(output)
    print(f"Wrote {path}", file=sys.stderr)
else:
    print(output, end='')
