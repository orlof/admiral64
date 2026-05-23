#!/usr/bin/env python3
"""Pack a .admiral file as a serialized Admiral OBJECT on disk.

The source must end with `RETURN <var>` returning the value to persist (a dict,
list, whatever). Runs the source through admiral.prg in py65 with a mocked
1541, calls SAVE on the result, and captures the on-disk bytes — the same
format LOAD will read back. Output is the binary record c1541 should add to
the .d64 image.

Usage:  pack_object.py <input.admiral> <output.bin> <save-name>

The save-name is the filename Admiral uses for the SAVE call; it determines
both the on-disk record header and (downstream) the LOAD lookup key. Use the
same name the user will type into LOAD("...").
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))

from py65.devices.mpu6502 import MPU                       # noqa: E402
from conftest import (                                     # noqa: E402
    Harness, KernalDiskMock, _load_prg, _load_symbols,
)


def pack(prg: Path, vs: Path, src: Path, save_name: str) -> bytes:
    mpu = MPU()
    mpu.sp = 0xFF
    _load_prg(mpu, prg)
    syms = _load_symbols(vs)
    mock = KernalDiskMock(mpu)
    h = Harness(mpu=mpu, sym=syms, kernal_mock=mock)
    h.call("rs_init")
    h.call("fs_init")
    h.call("_heap_apply")          # GFX_CONFIG=0 -> text heap ($FFF8 ceiling)
    h.call("alloc_init")
    h.call("rnd_init")

    # The source defines and `RETURN`s a value; at top level RETURN doesn't
    # terminate (it would in a function), so we strip the trailing
    # `RETURN <var>` and substitute a SAVE call that serializes the same var.
    source = src.read_text()
    m = re.search(r"\n\s*RETURN\s+(\w+)\s*\n?\s*\Z", source)
    if not m:
        sys.exit(f"{src}: must end with `RETURN <var>` (last 80 chars: {source[-80:]!r})")
    var = m.group(1)
    rewritten = source[: m.start()] + f'\nSAVE("{save_name}", {var})\n'

    payload = list(rewritten.encode("ascii"))
    handle = h.alloc_str(len(payload))
    h.write_bytes(h.read_word(handle) + 2, payload)
    h.rs_push(handle)
    # Big budget — eval has to assemble + SAVE the whole dict.
    h.call("parser_eval", max_steps=30_000_000)

    key = save_name.encode("ascii")
    if key not in mock.files:
        sys.exit(f"{src}: SAVE did not produce file {save_name!r} "
                 f"(disk has {list(mock.files)})")
    return mock.files[key]


def main():
    if len(sys.argv) != 4:
        sys.exit(f"usage: {sys.argv[0]} <input.admiral> <output.bin> <save-name>")
    src_path, out_path, name = sys.argv[1:]
    out = pack(
        prg=ROOT / "build" / "admiral.prg",
        vs=ROOT / "build" / "admiral.vs",
        src=Path(src_path),
        save_name=name,
    )
    Path(out_path).write_bytes(out)
    print(f"wrote {out_path} ({len(out)} bytes)")


if __name__ == "__main__":
    main()
