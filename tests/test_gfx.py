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


def test_mc_plot_high_x_addresses_correctly(h):
    # Regression: x_mc >= 128 used to write to the wrong row. The byte offset
    # within a row is (x & $FC) * 2, which exceeds 255 once x >= 128 — earlier
    # MC_PLOT computed it via `lsr;lsr;asl;asl;asl` and lost the carry, writing
    # to $E000 instead of $E100. Now: x_mc=128, y=0 -> byte $E000+(128/4)*8 =
    # $E100, field 0 (shift 6) -> ink 3 lands as $C0.
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.PLOT(X=128, Y=0, INK=3)\n0")
    assert _byte(h, 0xE100) == 0xC0
    assert _byte(h, 0xE000) == 0x00          # must NOT have been touched


def test_mc_plot_far_corner(h):
    # x=156 (the last 4-column at byte_addr $E000 + (156/4)*8 = $E138; the very
    # last full MC byte on the top char-row).
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.PLOT(X=156, Y=0, INK=3)\n0")
    assert _byte(h, 0xE138) == 0xC0


def test_hires_draw_horizontal(h):
    # (0..3, 0) -> byte $E000, bits 7,6,5,4 -> $F0.
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\nH.DRAW(X0=0, Y0=0, X1=3, Y1=0)\n0", max_steps=80_000_000)
    assert _byte(h, 0xE000) == 0xF0


def test_hires_draw_diagonal(h):
    # (0,0)(1,1)(2,2) -> $E000 bit7, $E001 bit6, $E002 bit5.
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\nH.DRAW(X0=0, Y0=0, X1=2, Y1=2)\n0")
    assert _byte(h, 0xE000) == 0x80
    assert _byte(h, 0xE001) == 0x40
    assert _byte(h, 0xE002) == 0x20


def test_hires_draw_long_horizontal(h):
    # 16-pixel horizontal at y=4: spans cells 0 and 1 (bytes $E004 and $E00C).
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\nH.DRAW(X0=0, Y0=4, X1=15, Y1=4)\n0")
    assert _byte(h, 0xE004) == 0xFF
    assert _byte(h, 0xE00C) == 0xFF


def test_hires_draw_reversed(h):
    # Reverse direction (x1 < x0): (3,0)->(0,0) should plot the same 4 pixels.
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\nH.DRAW(X0=3, Y0=0, X1=0, Y1=0)\n0")
    assert _byte(h, 0xE000) == 0xF0


def test_hires_draw_vertical(h):
    # Vertical line at x=0, y=0..3: $E000..$E003 all bit7.
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\nH.DRAW(X0=0, Y0=0, X1=0, Y1=3)\n0")
    for off in range(4):
        assert _byte(h, 0xE000 + off) == 0x80, f"byte $E00{off}"


def test_hires_draw_crosses_charrow(h):
    # Diagonal (0,7)->(1,8): jumps from char row 0 (byte $E007) to char row 1
    # (byte $E140, since (y&7)=0 at y=8) — exercises the row-table lookup.
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\nH.DRAW(X0=0, Y0=7, X1=1, Y1=8)\n0")
    assert _byte(h, 0xE007) == 0x80
    assert _byte(h, 0xE140) == 0x40


def test_hires_draw_fullscreen_diagonal(h):
    # Regression: (0,0)->(319,199) used to hang. The DDY computation was
    # treating y1-y0 as signed-byte, but for y up to 199 the diff exceeds 127
    # and bit 7 wrongly read as the sign — DSY/DDY came out inverted, y
    # under-ran, charrow indexed past the row table into DLOOP, JMP (DLOOP)
    # jumped to a wild address.
    _run(h, HIRES + "\nH.SHOW()\nH.CLEAR()\nH.DRAW(X0=0, Y0=0, X1=319, Y1=199)\n0", max_steps=30_000_000)
    assert _byte(h, 0xE000) == 0x80                   # (0,0) plotted
    assert _byte(h, 0xFF3F) != 0                      # last bitmap byte touched (endpoint area)


def test_mc_draw_horizontal(h):
    # (0..3, 0) ink 3 -> byte $E000 all four fields = $FF.
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.DRAW(X0=0, Y0=0, X1=3, Y1=0, INK=3)\n0")
    assert _byte(h, 0xE000) == 0xFF


def test_mc_draw_diagonal(h):
    # (0,0)(1,1)(2,2) ink 2 -> $E000 field0 ($80), $E001 field1 ($20), $E002 field2 ($08).
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.DRAW(X0=0, Y0=0, X1=2, Y1=2, INK=2)\n0")
    assert _byte(h, 0xE000) == 0x80
    assert _byte(h, 0xE001) == 0x20
    assert _byte(h, 0xE002) == 0x08


def test_mc_draw_vertical(h):
    # Vertical at x=0, y=0..3, ink=1 -> $E000..$E003 each field0 ($40).
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.DRAW(X0=0, Y0=0, X1=0, Y1=3, INK=1)\n0")
    for off in range(4):
        assert _byte(h, 0xE000 + off) == 0x40, f"byte $E00{off}"


def test_mc_draw_reversed(h):
    # Reversed direction: (3,0)->(0,0) ink 3 -> same as forward.
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.DRAW(X0=3, Y0=0, X1=0, Y1=0, INK=3)\n0")
    assert _byte(h, 0xE000) == 0xFF


def test_mc_draw_long_horizontal_crosses_byte(h):
    # 8-pixel horizontal at y=4 ink=3: spans bytes $E004 ($00 cell 0) and $E00C
    # (cell 1), each becomes $FF.
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.DRAW(X0=0, Y0=4, X1=7, Y1=4, INK=3)\n0")
    assert _byte(h, 0xE004) == 0xFF
    assert _byte(h, 0xE00C) == 0xFF


def test_mc_draw_crosses_charrow(h):
    # (0,7)->(1,8) ink=3: jumps from char row 0 (byte $E007 field0=$C0) to
    # char row 1 ((1,8) -> byte $E140, field1=$30).
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.DRAW(X0=0, Y0=7, X1=1, Y1=8, INK=3)\n0")
    assert _byte(h, 0xE007) == 0xC0
    assert _byte(h, 0xE140) == 0x30


def test_mc_draw_high_x(h):
    # Regression: x_mc range crosses the 128 boundary. Horizontal at y=0,
    # x=120..159 ink=3 -> bytes $E0F0..$E138 all $FF (10 bytes, 4 px each).
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.DRAW(X0=120, Y0=0, X1=159, Y1=0, INK=3)\n0")
    for off in (0xF0, 0xF8, 0x100, 0x108, 0x110, 0x118, 0x120, 0x128, 0x130, 0x138):
        assert _byte(h, 0xE000 + off) == 0xFF, f"byte $E0{off:02X}"


def test_mc_draw_fullscreen_diagonal(h):
    # (0,0)->(159,199) ink=3 — biggest line case. Should terminate and plot
    # both endpoints.
    _run(h, MC + "\nM.SHOW()\nM.CLEAR()\nM.DRAW(X0=0, Y0=0, X1=159, Y1=199, INK=3)\n0", max_steps=20_000_000)
    assert _byte(h, 0xE000) != 0                # (0,0) plotted (field 0)
    # endpoint (159,199): charrow=24, y&7=7, x&3=3 -> byte ytbl[24]+($9C*2)+7
    # ytbl[24] = $E000 + 24*$140 = $FE00; + (156*2)=$138; +7 = $FF3F.
    assert _byte(h, 0xFF3F) & 0x03 != 0         # field 3 set somewhere in that byte
