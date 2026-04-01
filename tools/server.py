#!/usr/bin/env python3
import socket
import struct

CHUNK_SIZE = 1400
PORT = 3737
BINARY = 'tmp/node.bin'

with open(BINARY, 'rb') as f:
    data = f.read()

chunks = [data[i:i+CHUNK_SIZE] for i in range(0, len(data), CHUNK_SIZE)]
print(f"Loaded {len(data)} bytes, {len(chunks)} chunks of up to {CHUNK_SIZE} bytes")

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(('0.0.0.0', PORT))
print(f"Listening on UDP {PORT}...")

while True:
    pkt, addr = sock.recvfrom(65535)
    if len(pkt) < 9 or pkt[:4] != b'FAMC':
        continue
    cmd = pkt[4]
    if cmd == 0x02:  # REQ_RANGE
        start, end = struct.unpack('>HH', pkt[5:9])
        print(f"REQ_RANGE {start}..{end} from {addr}")
        for seq in range(start, min(end + 1, len(chunks))):
            payload = b'FAMC' + bytes([0x82]) + struct.pack('>H', seq) + chunks[seq]
            sock.sendto(payload, addr)
            print(f"  sent chunk {seq} ({len(chunks[seq])} bytes)")

