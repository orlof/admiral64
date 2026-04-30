#!/usr/bin/env python3
"""Find repeated byte sequences in the assembled binary that are candidates
for factoring into shared subroutines.

For each length L (default 6..18 bytes), build a suffix-array-like scan and
report sequences that repeat ≥3 times with potential savings ≥30 bytes.
Potential savings = (L - 3) * (count - 1) - L  — i.e. each copy after the
first becomes a 3-byte JSR, minus the body bytes we'd allocate once.
"""

from __future__ import annotations

import struct
import sys
from collections import defaultdict
from pathlib import Path


def load_prg(path: Path) -> tuple[int, bytes]:
    raw = path.read_bytes()
    load = struct.unpack('<H', raw[:2])[0]
    return load, raw[2:]


def scan(body: bytes, min_len: int, max_len: int, min_count: int = 3,
         min_savings: int = 30) -> list[tuple[int, int, int, int, list[int]]]:
    """Return list of (length, count, savings, total_bytes, offsets)."""
    results: list[tuple[int, int, int, int, list[int]]] = []
    seen_keys: set[bytes] = set()

    for L in range(max_len, min_len - 1, -1):
        positions: dict[bytes, list[int]] = defaultdict(list)
        for i in range(len(body) - L + 1):
            chunk = body[i:i + L]
            positions[chunk].append(i)

        for chunk, offs in positions.items():
            if len(offs) < min_count:
                continue
            # Skip if a longer match already covered this region.
            if chunk[:min_len] in seen_keys:
                continue
            # Skip runs of identical byte (probably .fill — handle separately).
            if len(set(chunk)) <= 2:
                continue
            count = len(offs)
            # Savings if each repeat becomes a 3-byte JSR + we keep L body bytes once.
            # Original: count * L bytes. Replaced: L (body) + count * 3 (JSRs) + 1 (RTS).
            savings = count * L - (L + count * 3 + 1)
            if savings < min_savings:
                continue
            results.append((L, count, savings, count * L, offs))

        # Mark anything length ≥ L as "seen" via its prefix to suppress shorter sub-matches.
        for chunk in (k for k, v in positions.items() if len(v) >= min_count):
            seen_keys.add(chunk[:min_len])

    results.sort(key=lambda r: -r[2])
    return results


def hexdump(b: bytes) -> str:
    return ' '.join(f'{x:02X}' for x in b)


def main() -> int:
    prg = Path(sys.argv[1] if len(sys.argv) > 1 else 'build/admiral.prg')
    load, body = load_prg(prg)
    print(f"# {prg}: load=${load:04X} size={len(body)} end=${load + len(body):04X}")
    print()

    hits = scan(body, min_len=6, max_len=20, min_count=3, min_savings=20)
    print(f"# Top {min(20, len(hits))} repeated sequences (≥3 occurrences, ≥20 bytes saved):")
    print()
    print(f"{'L':>3} {'cnt':>4} {'save':>5} {'bytes':>5}  hex")
    for L, count, savings, total, offs in hits[:20]:
        sample = body[offs[0]:offs[0] + L]
        addr_list = ', '.join(f'${load + o:04X}' for o in offs[:5])
        if len(offs) > 5:
            addr_list += f', ...({len(offs)-5} more)'
        print(f"{L:>3} {count:>4} {savings:>5} {total:>5}  {hexdump(sample)}")
        print(f"                    @ {addr_list}")

    return 0


if __name__ == '__main__':
    sys.exit(main())
