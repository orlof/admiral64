"""Window manager (src/wm.asm): WINDOW/USE/CLOSE/AT/REFRESH + write-through.

Screen state is inspected straight from $0400 in py65; MAP/buffers via the
window dicts. Screen codes: 'A'=$01, 'B'=$02, space=$20, border corners
$70/$6E/$6D/$7D, horizontal $40, vertical $5D.
"""
from __future__ import annotations

import pytest

from conftest import RV, ERROR_CODE_ZP, ERR_TYPE
from test_str import place_str
from test_parser import _eval, _eval_str

SCREEN = 0x0400


def scr(h, col, row):
    return h.mpu.memory[SCREEN + row * 40 + col]


def run(h, src, max_steps=8_000_000):
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=max_steps)
    return h.read_word(RV)


# --- creation ----------------------------------------------------------------

def test_window_returns_dict_with_fields(h):
    assert _eval(h, 'P = WINDOW(5, 3, 10, 5, "T")\nP.X + P.Y + P.W + P.H') \
        == 5 + 3 + 10 + 5


def test_window_binds_root(h):
    assert _eval(h, 'P = WINDOW(0, 0, 10, 3)\nROOT.W') == 40


def test_border_glyphs_and_title(h):
    run(h, 'P = WINDOW(5, 3, 10, 5, "TI")')
    assert scr(h, 5, 3) == 0x70          # top-left corner
    assert scr(h, 14, 3) == 0x6E         # top-right corner
    assert scr(h, 5, 7) == 0x6D          # bottom-left corner
    assert scr(h, 14, 7) == 0x7D         # bottom-right corner
    assert scr(h, 5, 5) == 0x5D          # left side
    assert scr(h, 14, 5) == 0x5D         # right side
    assert scr(h, 6, 3) == 0x14          # 'T' of the title
    assert scr(h, 7, 3) == 0x09          # 'I'
    assert scr(h, 8, 3) == 0x40          # horizontal run after the title


def test_titled_window_clears_interior(h):
    # Put junk on the screen where the interior will be, then open a window.
    h.mpu.memory[SCREEN + 4 * 40 + 6] = 0x33
    run(h, 'P = WINDOW(5, 3, 10, 5, "T")')
    assert scr(h, 6, 4) == 0x20


def test_bad_geometry_panics(h):
    for src in ('WINDOW(35, 0, 10, 5, "T")',     # x+w > 40
                'WINDOW(0, 22, 5, 5, "T")',      # y+h > 25
                'WINDOW(0, 0, 2, 5, "T")',       # bordered w < 3
                'WINDOW(0, 0, 0, 5)'):           # w == 0
        payload = list(src.encode("ascii"))
        handle = place_str(h, 0x8500, payload)
        h.rs_push(handle)
        with pytest.raises(Exception):
            h.call("parser_eval", max_steps=8_000_000)
        assert h.mpu.memory[ERROR_CODE_ZP] == ERR_TYPE


# --- output + write-through --------------------------------------------------

def test_print_lands_in_window_interior(h):
    run(h, 'P = WINDOW(5, 3, 10, 5, "T")\nPRINT "AB"')
    assert scr(h, 6, 4) == 0x01          # 'A' at interior origin
    assert scr(h, 7, 4) == 0x02          # 'B'


def test_use_switches_target_and_returns_previous(h):
    assert _eval(h, 'P = WINDOW(5, 3, 10, 5, "T")\nQ = USE(ROOT)\nQ.X') == 5


def test_print_to_root_under_window_stays_hidden(h):
    src = ('P = WINDOW(0, 0, 12, 4, "T")\n'
           'USE(ROOT)\n'
           'AT(ROOT, 1, 1)\n'
           'PRINT "HELLO"')
    run(h, src)
    # Cells under the window: screen still shows the window, not HELLO.
    assert scr(h, 1, 1) != 0x08          # 'H' hidden (window owns the cell)
    # But ROOT's buffer holds the text (verified after CLOSE below).


def test_close_reveals_underlying_window_content(h):
    src = ('P = WINDOW(0, 0, 12, 4, "T")\n'
           'USE(ROOT)\n'
           'AT(ROOT, 1, 1)\n'
           'PRINT "HELLO"\n'
           'CLOSE(P)')
    run(h, src)
    assert scr(h, 1, 1) == 0x08          # 'H'
    assert scr(h, 5, 1) == 0x0F          # 'O'


def test_write_through_outside_overlap(h):
    src = ('P = WINDOW(0, 0, 12, 4, "T")\n'
           'USE(ROOT)\n'
           'AT(ROOT, 0, 10)\n'
           'PRINT "XY"')
    run(h, src)
    assert scr(h, 0, 10) == 0x18         # 'X' visible (ROOT owns row 10)
    assert scr(h, 1, 10) == 0x19         # 'Y'


def test_at_moves_cursor_of_current_window(h):
    src = ('P = WINDOW(5, 3, 20, 6, "T")\n'
           'AT(P, 3, 2)\n'
           'PRINT "Z"')
    run(h, src)
    assert scr(h, 6 + 3, 4 + 2) == 0x1A  # 'Z' at interior (3,2)


def test_close_root_panics(h):
    payload = list('P = WINDOW(0,0,5,3)\nCLOSE(ROOT)'.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    with pytest.raises(Exception):
        h.call("parser_eval", max_steps=8_000_000)
    assert h.mpu.memory[ERROR_CODE_ZP] == ERR_TYPE


def test_close_current_falls_back_to_root(h):
    # After closing the current window, PRINT goes to ROOT (fullscreen).
    src = ('P = WINDOW(5, 3, 10, 5, "T")\n'
           'CLOSE(P)\n'
           'AT(ROOT, 0, 20)\n'
           'PRINT "Q"')
    run(h, src)
    assert scr(h, 0, 20) == 0x11         # 'Q'


def test_root_inherits_screen_contents(h):
    # Whatever was on screen before wm_start becomes ROOT's buffer.
    h.mpu.memory[SCREEN + 22 * 40 + 3] = 0x2A   # some glyph low-right
    run(h, 'P = WINDOW(0, 0, 10, 3, "T")')
    assert scr(h, 3, 22) == 0x2A         # still visible (ROOT owns it)


def test_window_scrolls_inside_itself(h):
    # 3 interior rows; each PRINT ends in a newline, so after the 4th print
    # two scrolls have happened: rows = CC, DD, blank.
    src = ('P = WINDOW(5, 3, 12, 5, "T")\n'
           'PRINT "AA"\nPRINT "BB"\nPRINT "CC"\nPRINT "DD"')
    run(h, src, max_steps=12_000_000)
    assert scr(h, 6, 4) == 0x03          # 'C' on interior row 0
    assert scr(h, 6, 5) == 0x04          # 'D' on interior row 1
    assert scr(h, 6, 6) == 0x20          # blank last row
    # border intact
    assert scr(h, 5, 3) == 0x70
    assert scr(h, 5, 7) == 0x6D


def test_gc_pressure_keeps_window_alive(h):
    # Churn enough to trigger mark/sweep/compact; window + MAP survive and
    # write-through still lands correctly afterwards.
    src = ('P = WINDOW(5, 3, 12, 5, "T")\n'
           'i = 0\n'
           'WHILE i < 40:\n'
           '  junk = "x" * 40\n'
           '  i = i + 1\n'
           'PRINT "OK"')
    run(h, src, max_steps=60_000_000)
    assert scr(h, 6, 4) == 0x0F          # 'O'
    assert scr(h, 7, 4) == 0x0B          # 'K'


def test_repl_line_editing_mirrors_into_window(h):
    """Typed characters must be VISIBLE in a window: _rpl_redraw goes through
    the write-through path, bounded by the window width (regression for the
    invisible-typing bug found under VICE)."""
    from test_repl import _drive_read_line
    run(h, 'P = WINDOW(5, 3, 20, 8, "T")')     # current target = P's interior
    # Simulate the prompt: '>' then read a line at the current cursor.
    h.call("screen_put_char", a=0x3E)
    anchor = h.mpu.memory[0x33]                # SCREEN_ROW (window-relative)
    h.mpu.memory[h.sym["repl_line_anchor_row"]] = anchor
    _drive_read_line(h, [ord("P"), ord("R")], anchor_row=anchor)
    # Interior origin is (6,4); prompt at col 0, chars at cols 1..2 -> screen.
    assert scr(h, 6, 4) == 0x3E                # '>'
    assert scr(h, 7, 4) == 0x10                # 'P'
    assert scr(h, 8, 4) == 0x12                # 'R'


def test_repl_redraw_clips_to_window_width(h):
    """A line longer than the window is clipped at the right edge and must
    not spill into the next buffer row (was: pad loop ran to column 39)."""
    from test_repl import _drive_read_line
    run(h, 'P = WINDOW(5, 3, 12, 6, "T")')     # interior 10 wide
    h.call("screen_put_char", a=0x3E)
    anchor = h.mpu.memory[0x33]
    h.mpu.memory[h.sym["repl_line_anchor_row"]] = anchor
    _drive_read_line(h, [ord("A")] * 15, anchor_row=anchor)
    # Row 0 of the interior: '>' + 9 'A's, hard edge at the border.
    assert scr(h, 6, 4) == 0x3E
    assert scr(h, 7, 4) == 0x01
    assert scr(h, 15, 4) == 0x01               # last interior column
    assert scr(h, 16, 4) == 0x5D               # border intact
    # Next interior row untouched (no spill through the buffer stride).
    assert scr(h, 6, 5) == 0x20
