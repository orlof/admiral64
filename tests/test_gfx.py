"""RAM-level tests for the graphics extensions (examples/{hires,mc,text}.admiral).

These run the CALL-asm routines in py65 and check their memory effects. py65 has
no VIC and no $01 banking, but the routines write plain RAM — including the VIC
registers ($D018 etc., which are just RAM here) — so SHOW/CLS/COLOR/PLOT are all
verifiable. Actual on-screen rendering is confirmed under VICE.

Each test runs in the graphics heap config (handle ceiling $DC00) so the heap
never collides with the bitmap ($E000), matrix ($DC00) or row table ($FF40).
"""

from __future__ import annotations

import os

_EX = os.path.join(os.path.dirname(__file__), "..", "examples")


def _body(fname: str, var: str) -> str:
    """Load an extension file, dropping the trailing `RETURN <var>` so the dict
    stays in scope for appended method calls."""
    return open(os.path.join(_EX, fname)).read().rsplit("RETURN " + var, 1)[0]


def _run(h, source: str, max_steps: int = 30_000_000):
    """Re-init into the graphics heap config, then evaluate `source`."""
    h.mpu.memory[h.sym["GFX_CONFIG"]] = 1
    h.call("_heap_apply")
    h.call("alloc_init")
    payload = list(source.encode("ascii"))
    handle = h.alloc_str(len(payload))
    h.write_bytes(h.read_word(handle) + 2, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=max_steps)


def _byte(h, addr: int) -> int:
    return h.mpu.memory[addr]


HIRES = _body("hires.admiral", "H")


def test_hires_show_sets_vic_and_table(h):
    _run(h, HIRES + "\nH.SHOW()\n0")
    assert _byte(h, 0xD018) == 0x78          # matrix $DC00, bitmap $E000
    assert _byte(h, 0xD011) == 0x3B          # BMM+DEN+RSEL
    assert _byte(h, 0xD016) == 0xC8          # 40-col, mono
    assert (_byte(h, 0xDD00) & 0x03) == 0x00  # VIC bank 3
    # Row table: $FF40[0] = $E000, $FF40[24] = $E000 + 24*320 = $FE00.
    assert h.read_word(0xFF40) == 0xE000
    assert h.read_word(0xFF40 + 48) == 0xE000 + 24 * 320


def test_hires_color_fills_matrix(h):
    _run(h, HIRES + "\nH.COLOR(FG=7, BG=6)\n0")
    assert _byte(h, 0xDC00) == 0x76          # (7<<4)|6
    assert _byte(h, 0xDFE7) == 0x76          # last matrix cell


def test_hires_clear_clears_bitmap(h):
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\n0")
    assert _byte(h, 0xE000) == 0x00
    assert _byte(h, 0xFF3F) == 0x00          # last bitmap byte


def test_hires_plot_sets_pixel_bits(h):
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\nH.PLOT(X=0, Y=0)\nH.PLOT(X=8, Y=0)\nH.PLOT(X=7, Y=0)\n0")
    # (0,0): byte $E000, bit 7.  (8,0): next cell byte $E008, bit 7.
    # (7,0): same byte as (0,0), bit 0 -> $E000 becomes $80|$01 = $81.
    assert _byte(h, 0xE000) == 0x81
    assert _byte(h, 0xE008) == 0x80


def test_hires_plot_uses_row_table_for_y(h):
    # (0,8) is char row 1, in-cell row 0 -> byte = ytbl[1] = $E140.
    # (0,1) is char row 0, in-cell row 1 -> byte = $E000 + 1.
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\nH.PLOT(X=0, Y=8)\nH.PLOT(X=0, Y=1)\n0")
    assert _byte(h, 0xE140) == 0x80
    assert _byte(h, 0xE001) == 0x80


TEXT = _body("text.admiral", "T")
MC = _body("mc.admiral", "M")


def test_text_show_sets_text_mode(h):
    _run(h, TEXT + "\nT.SHOW()\n0")
    assert _byte(h, 0xD018) == 0x15          # screen $0400, charset ROM
    assert _byte(h, 0xD011) == 0x1B          # text (BMM=0)
    assert _byte(h, 0xD016) == 0xC8          # MCM=0
    assert (_byte(h, 0xDD00) & 0x03) == 0x03  # VIC bank 0


def test_mc_show_sets_multicolor(h):
    _run(h, MC + "\nM.SHOW()\n0")
    assert _byte(h, 0xD018) == 0x78
    assert _byte(h, 0xD011) == 0x3B          # BMM+DEN+RSEL
    assert _byte(h, 0xD016) == 0xD8          # MCM=1
    assert (_byte(h, 0xDD00) & 0x03) == 0x00  # bank 3
    assert h.read_word(0xFF40) == 0xE000


def test_mc_color_fills_matrix_and_colorram(h):
    _run(h, MC + "\nM.COLOR(C01=1, C10=2, C11=3)\n0")
    assert _byte(h, 0xDC00) == 0x12          # (1<<4)|2
    assert _byte(h, 0xDFE7) == 0x12
    assert (_byte(h, 0xD800) & 0x0F) == 0x03  # color RAM low nibble
    assert (_byte(h, 0xDBE7) & 0x0F) == 0x03


def test_mc_plot_sets_2bit_field(h):
    # x=0 ink=2 -> byte $E000 field0 (shift 6): 2<<6 = $80.
    # x=1 ink=1 -> field1 (shift 4): 1<<4 = $10 -> $90.
    # x=4 ink=3 -> byte $E008 field0 (shift 6): 3<<6 = $C0.
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.PLOT(X=0, Y=0, INK=2)\nM.PLOT(X=1, Y=0, INK=1)\nM.PLOT(X=4, Y=0, INK=3)\n0")
    assert _byte(h, 0xE000) == 0x90
    assert _byte(h, 0xE008) == 0xC0


def test_hires_draw_horizontal(h):
    # (0..3, 0) -> byte $E000, bits 7,6,5,4 -> $F0.
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\nH.DRAW(X0=0, Y0=0, X1=3, Y1=0)\n0", max_steps=80_000_000)
    assert _byte(h, 0xE000) == 0xF0


def test_hires_draw_diagonal(h):
    # (0,0)(1,1)(2,2) -> $E000 bit7, $E001 bit6, $E002 bit5.
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\nH.DRAW(X0=0, Y0=0, X1=2, Y1=2)\n0", max_steps=80_000_000)
    assert _byte(h, 0xE000) == 0x80
    assert _byte(h, 0xE001) == 0x40
    assert _byte(h, 0xE002) == 0x20


def test_mc_draw_horizontal(h):
    # (0..3, 0) ink 3 -> byte $E000 all four fields = $FF.
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.DRAW(X0=0, Y0=0, X1=3, Y1=0, INK=3)\n0", max_steps=80_000_000)
    assert _byte(h, 0xE000) == 0xFF
