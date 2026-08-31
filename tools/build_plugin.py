#!/usr/bin/env python3
"""Build a v2 TYPE_CODE plugin from a plugins/*.asm source.

Pipeline:
  1. Assemble the source at three bases with KickAssembler:
       A = $1000 (reference), B = $1100 (hi-byte delta), C = $1001 (lo delta).
  2. Diff the binaries. Every internal absolute 16-bit reference shows up as
     a lo-byte diff (C vs A, +1) at offset p AND a hi-byte diff (B vs A, +1)
     at offset p+1. Anything else is an unrelocatable reference → hard error:
       - a B-diff without a matching C-diff at p-1  → stray hi-byte
         (e.g. `lda #>label`) the relocator would corrupt
       - a C-diff without a matching B-diff at p+1  → stray lo-byte
         (e.g. `lda #<label`) the relocator would silently miss
  3. Append the fixup table ([nfix][offset...] little-endian) at the end of
     the reference binary — the source's trailing `fixup_table:` label (whose
     payload-relative offset sits at +5) must equal the binary length.
  4. Wrap the payload as a single TYPE_CODE record for LOAD("name"):
       ID=0x0001, TYPE=0x2D, SIZE (LE), payload, terminator 0x0000
     (same stream framing as tools/pack_str_record.py).

Payload contract (must match src/plugin_rt.asm):
  +0 jsr SYS_RELOC   +3 .word linked_base   +5 .word fixups_off   +7 entry

Usage: build_plugin.py <src.asm> <out.bin> [--kickass JAR] [--libdir DIR]
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

TYPE_CODE = 0x2D
BASE_A = 0x1000
BASE_B = 0x1100  # +$0100 → every absolute ref's hi byte shifts by 1
BASE_C = 0x1001  # +$0001 → every absolute ref's lo byte shifts by 1


def assemble(kickass: str, src: Path, base: int, libdir: Path, outdir: Path) -> bytes:
    out = outdir / f"plugin_{base:04x}.prg"
    cmd = [
        "java", "-jar", kickass,
        str(src),
        "-libdir", str(libdir),
        "-odir", str(outdir),
        "-o", str(out),
        f":base={base}",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"KickAssembler failed for base ${base:04X}:\n{r.stdout}{r.stderr}")
    data = out.read_bytes()
    load = data[0] | (data[1] << 8)
    if load != base:
        sys.exit(f"unexpected load address ${load:04X} (wanted ${base:04X})")
    return data[2:]


def find_fixups(a: bytes, b: bytes, c: bytes) -> list[int]:
    if not (len(a) == len(b) == len(c)):
        sys.exit(f"binary sizes differ across bases: {len(a)}/{len(b)}/{len(c)} "
                 "— base-dependent .if/.fill in the source?")
    hi = {p for p in range(len(a)) if a[p] != b[p]}
    lo = {p for p in range(len(a)) if a[p] != c[p]}

    fixups = []
    for p in sorted(lo):
        if (c[p] - a[p]) & 0xFF != 1:
            sys.exit(f"offset {p}: lo-byte delta {c[p]-a[p]} != 1 — not a base ref")
        if p + 1 not in hi:
            sys.exit(f"offset {p}: lone lo-byte reference (e.g. `lda #<label`) "
                     "— the relocator cannot patch 8-bit refs")
        fixups.append(p)
    for p in sorted(hi):
        if (b[p] - a[p]) & 0xFF != 1:
            sys.exit(f"offset {p}: hi-byte delta {b[p]-a[p]} != 1 — not a base ref")
        if p - 1 not in lo:
            sys.exit(f"offset {p}: lone hi-byte reference (e.g. `lda #>label`) "
                     "— the relocator cannot patch 8-bit refs")

    # linked_base at +3..+4 is handled by SYS_RELOC itself, not the fixup list.
    if 3 not in fixups:
        sys.exit("offset 3: linked_base word did not vary with base — header broken?")
    fixups.remove(3)
    return fixups


def check_header(a: bytes) -> None:
    if len(a) < 7:
        sys.exit("payload shorter than the 7-byte v2 header")
    if a[0] != 0x20:
        sys.exit(f"payload[0] = ${a[0]:02X}, expected JSR ($20) to SYS_RELOC")
    fix_off = a[5] | (a[6] << 8)
    if fix_off != len(a):
        sys.exit(f"fixups_off {fix_off} != binary length {len(a)} — "
                 "`fixup_table:` must be the last label with nothing after it")


def pack_record(payload: bytes) -> bytes:
    if len(payload) > 0xFFFF:
        sys.exit(f"payload too large: {len(payload)}")
    out = bytearray()
    out += b"\x01\x00"
    out.append(TYPE_CODE)
    out += bytes([len(payload) & 0xFF, len(payload) >> 8])
    out += payload
    out += b"\x00\x00"
    return bytes(out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("src", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--kickass",
                    default=os.path.expanduser("~/bin/KickAssembler/KickAss.jar"))
    ap.add_argument("--libdir", type=Path, default=Path("src"))
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as td:
        outdir = Path(td)
        a = assemble(args.kickass, args.src, BASE_A, args.libdir, outdir)
        b = assemble(args.kickass, args.src, BASE_B, args.libdir, outdir)
        c = assemble(args.kickass, args.src, BASE_C, args.libdir, outdir)

    check_header(a)
    fixups = find_fixups(a, b, c)

    payload = bytearray(a)
    payload += bytes([len(fixups) & 0xFF, len(fixups) >> 8])
    for off in fixups:
        payload += bytes([off & 0xFF, off >> 8])

    args.out.write_bytes(pack_record(bytes(payload)))
    print(f"{args.src.name}: {len(a)} code bytes, {len(fixups)} fixups "
          f"→ {args.out} ({len(payload)} payload)")


if __name__ == "__main__":
    main()
