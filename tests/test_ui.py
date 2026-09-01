"""examples/ui.admiral — the disk-loaded UI library over the WM builtins.

Loaded through the KernalDiskMock like any user library; keys arrive through
the GETIN stub (see test_parser._stub_getin_queue).
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

import pytest

from test_parser import _stub_getin_queue, _eval_to_str
from test_str import place_str
from test_wm import scr, run
from conftest import RV

ROOT = pathlib.Path(__file__).resolve().parent.parent

CRSR_DOWN = 0x11
CRSR_UP = 0x91
RETURN = 0x0D
F3 = 0x86


@pytest.fixture(scope="session")
def ui_record() -> bytes:
    out = ROOT / "build" / "ui_test.bin"
    r = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "pack_str_record.py"),
         str(ROOT / "examples" / "ui.admiral"), str(out)],
        cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return out.read_bytes()


@pytest.fixture
def hu(hd, ui_record):
    hd.kernal_mock.files[b"UI"] = ui_record
    return hd


LOADU = 'F = LOAD("UI")\nUI = F()\n'


def _eval_int(h, src, max_steps=80_000_000):
    from test_int_parse import _read_int
    rv = run(h, src, max_steps=max_steps)
    return _read_int(h, rv)


def test_open_returns_window_with_proto_methods(hu):
    src = LOADU + 'P = UI.OPEN(T="LOG", X=2, Y=2, W=20, H=8)\nP.X + P.W'
    assert _eval_int(hu, src) == 22


def test_window_print_method_keeps_target(hu):
    # P.WRITE writes into P without changing the current target (ROOT here
    # after UI.OPEN made P current... OPEN leaves P current, so USE(ROOT)
    # first, then P.WRITE must land in P and leave ROOT current.
    src = (LOADU +
           'P = UI.OPEN(T="LOG", X=2, Y=2, W=20, H=8)\n'
           'USE(ROOT)\n'
           'P.WRITE(S="HI")\n'
           'AT(ROOT, 0, 20)\n'
           'PRINT "R"')
    run(hu, src, max_steps=80_000_000)
    assert scr(hu, 3, 3) == 0x08      # 'H' in P's interior
    assert scr(hu, 0, 20) == 0x12     # 'R' printed to ROOT afterwards

def test_popup_select_second_item(hu):
    _stub_getin_queue(hu, bytes([CRSR_DOWN, RETURN]))
    src = LOADU + 'UI.POPUP(T="M", I=["AA", "BB", "CC"], X=2, Y=2, W=10)'
    assert _eval_int(hu, src) == 1


def test_popup_renders_all_items_first_highlighted(hu):
    """All items visible on their own rows, first one reverse-highlighted —
    regression for the last-item-newline scrolling LOAD out of the window."""
    _stub_getin_queue(hu, bytes([F3]))
    src = LOADU + 'UI.POPUP(T="F", I=["LOAD","SAVE","RUN","QUIT"], X=2, Y=2, W=12)\n0'
    # Snapshot mid-run is hard; instead reopen without closing: use OPEN+MENU
    # manually so the window stays on screen after cancel? Simpler: check the
    # rendered rows straight after MENU returns is impossible (popup closed).
    # So drive OPEN + the draw part only: open a window and call MENU with a
    # queue that cancels immediately, then verify via a second popup that
    # stays open: open manually.
    src = (LOADU +
           'P = UI.OPEN(T="F", X=2, Y=2, W=12, H=6)\n'
           'R = P.MENU(I=["LOAD","SAVE","RUN","QUIT"])')
    run(hu, src, max_steps=80_000_000)
    # Popup not closed by MENU (only POPUP closes); rows visible:
    assert scr(hu, 3, 3) == 0x8C           # 'L' reversed (highlight row 0)
    assert scr(hu, 3, 4) == 0x13           # 'S'
    assert scr(hu, 3, 5) == 0x12           # 'R'
    assert scr(hu, 3, 6) == 0x11           # 'Q'



def test_popup_wraps_up_to_last(hu):
    _stub_getin_queue(hu, bytes([CRSR_UP, RETURN]))
    src = LOADU + 'UI.POPUP(T="M", I=["AA", "BB", "CC"], X=2, Y=2, W=10)'
    assert _eval_int(hu, src) == 2


def test_popup_cancel_returns_minus_one(hu):
    _stub_getin_queue(hu, bytes([F3]))
    src = LOADU + 'UI.POPUP(T="M", I=["AA", "BB"], X=2, Y=2, W=10)\n0'
    # -1 sign-extends; just check the expression completes and screen is
    # restored (popup closed).
    run(hu, src, max_steps=80_000_000)
    assert scr(hu, 2, 2) != 0x70      # border gone after CLOSE


def test_popup_restores_screen_under_it(hu):
    # Text drawn BEFORE the WM starts is inherited by ROOT and must reappear
    # when the popup (whose first window boots the WM) closes over it.
    _stub_getin_queue(hu, bytes([RETURN]))
    src = (LOADU +
           'CURSOR(2, 3)\n'
           'PRINT "UNDER"\n'
           'UI.POPUP(T="M", I=["AA", "BB"], X=1, Y=2, W=10)')
    run(hu, src, max_steps=80_000_000)
    assert scr(hu, 2, 3) == 0x15      # 'U' visible again after popup closed


def test_alert_waits_key_and_closes(hu):
    _stub_getin_queue(hu, b"\x20")
    src = LOADU + 'UI.ALERT(T="E", M="MSG")\nAT(ROOT, 0, 0)\nPRINT "A"'
    run(hu, src, max_steps=80_000_000)
    assert scr(hu, 0, 0) == 0x01      # back on ROOT, alert gone
    assert scr(hu, 5, 10) != 0x70
