#!/usr/bin/env python3
"""Pack a text source file into Admiral's serialization stream as a single
TYPE_STR record, suitable for `LOAD("name")` to deserialize.

Stream layout (matches src/disk.asm `disk_serialize_w0`):
    ID    : 2 bytes LE — any non-zero handle pointer (we use 0x0001)
    TYPE  : 1 byte     — 0x21 = TYPE_STR
    SIZE  : 2 bytes LE — payload length in bytes (max 65535; STR O_LEN field
                         is 16-bit but practical alloc-time limit is heap-bound)
    DATA  : N bytes    — the string payload (PETSCII, $0D-separated lines)
    TERM  : 2 bytes    — 0x0000 (end-of-stream)

ASCII LF ($0A) is translated to PETSCII CR ($0D) so the C64 lexer sees its
native line separator. Otherwise bytes pass through unchanged — uppercase
A-Z map 1:1 between ASCII and PETSCII in the default unshifted display mode.
"""

import sys
from pathlib import Path

TYPE_STR = 0x21


def pack(text: bytes) -> bytes:
    payload = text.replace(b"\n", b"\r")
    if len(payload) > 0xFFFF:
        sys.exit(f"payload too large: {len(payload)} bytes")
    out = bytearray()
    out += b"\x01\x00"                                 # ID = 1
    out += bytes([TYPE_STR])                            # TYPE = STR
    out += bytes([len(payload) & 0xFF, len(payload) >> 8])  # SIZE LE
    out += payload                                      # DATA
    out += b"\x00\x00"                                  # terminator ID
    return bytes(out)


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <input.txt> <output.bin>")
    src = Path(sys.argv[1]).read_bytes()
    Path(sys.argv[2]).write_bytes(pack(src))


if __name__ == "__main__":
    main()
