"""End-to-end test for tools/pack_object.py: pack a .admiral file as a
serialized dict, drop it on the mocked 1541, and LOAD it (no `()`) into a
fresh harness to exercise the resulting object.

Verifies that the on-disk format produced by pack_object matches what Admiral's
LOAD expects, AND that the extension dict behaves the same whether built from
source-at-load (the old shape) or unpickled from a SAVE record (the new shape).
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from pack_object import pack  # noqa: E402


def test_pack_then_load_hires_dict(hd):
    """Pack examples/hires.admiral as a serialized HIRES dict, then LOAD it via
    a fresh harness's mocked disk and exercise SHOW/COLOR/PLOT — same RAM
    effects as the inline-source path in test_gfx."""
    blob = pack(
        prg=ROOT / "build" / "admiral.prg",
        vs=ROOT / "build" / "admiral.vs",
        src=ROOT / "examples" / "hires.admiral",
        save_name="HIRES",
    )
    # The pack() call left its own MPU state; we use a fresh `hd` harness for
    # the round-trip half. Seed the mock disk with the just-packed bytes.
    hd.kernal_mock.add_file(b"HIRES", blob)

    # Graphics config — bitmap/matrix/row-table addresses must be reserved.
    hd.mpu.memory[hd.sym["GFX_CONFIG"]] = 1
    hd.call("_heap_apply")
    hd.call("alloc_init")

    # NOTE: no () after LOAD — the file IS the dict, not a callable source.
    src = ('H = LOAD("HIRES")\n'
           'H.SHOW()\n'
           'H.COLOR(FG=7, BG=6)\n'
           'H.PLOT(X=0, Y=0)\n'
           'H.DRAW(X0=0, Y0=0, X1=3, Y1=0)\n'
           '0')
    payload = list(src.encode())
    handle = hd.alloc_str(len(payload))
    hd.write_bytes(hd.read_word(handle) + 2, payload)
    hd.rs_push(handle)
    hd.call("parser_eval", max_steps=30_000_000)

    # SHOW set VIC registers; COLOR filled the matrix; PLOT and DRAW set bits.
    assert hd.mpu.memory[0xD018] == 0x78
    assert hd.mpu.memory[0xDC00] == 0x76                # (7<<4)|6
    assert hd.mpu.memory[0xE000] == 0xF0                # PLOT(0,0) | DRAW(0..3, 0)
