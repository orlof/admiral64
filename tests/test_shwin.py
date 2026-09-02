"""SHWIN — spawn a second shell in a window (examples/shwin.admiral).

Demonstrates a task that opens its own window (bottom-right quarter) and runs
the standard SHELL inside it. NOTE: with no keyboard focus yet, two live
shells race for keystrokes — this test only checks that the windowed shell
starts and draws its frame; interactive dual-shell use awaits the focus layer.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

import pytest

from test_str import place_str
from test_parser import _stub_getin_queue

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCREEN = 0x0400


def scr(h, col, row):
    return h.mpu.memory[SCREEN + row * 40 + col]


@pytest.fixture
def hs(hd):
    for name in ("shell", "shwin"):
        out = ROOT / "build" / f"{name}_test.bin"
        r = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "pack_str_record.py"),
             str(ROOT / "examples" / f"{name}.admiral"), str(out)],
            cwd=ROOT, capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr
        hd.kernal_mock.files[name.upper().encode()] = out.read_bytes()
    return hd


def test_shwin_opens_shell_window_in_bottom_right(hs):
    h = hs
    _stub_getin_queue(h, bytes([0] * 60))          # empty polls: shell INPUT yields
    src = 'SPAWN(LOAD("SHWIN"))\nX=0\nWHILE X<50:\n X=X+1'
    handle = place_str(h, 0x8A00, list(src.encode("ascii")))
    h.rs_push(handle)
    sentinel = 0xFFFE
    h.mpu.memory[0x0100 + h.mpu.sp] = (sentinel >> 8) & 0xFF
    h.mpu.sp = (h.mpu.sp - 1) & 0xFF
    h.mpu.memory[0x0100 + h.mpu.sp] = sentinel & 0xFF
    h.mpu.sp = (h.mpu.sp - 1) & 0xFF
    h.mpu.pc = h.sym["parser_eval"]
    pend = h.sym["TASK_SWITCH_PENDING"]
    n = 0
    for _ in range(60_000_000):
        if h.kernal_mock.step_hook():
            continue
        if h.mpu.pc == sentinel + 1:
            break
        n += 1
        if n % 600 == 0:
            h.mpu.memory[pend] = 1                  # periodic timer tick
        h.mpu.step()
    # Bottom-right quarter window frame, drawn by the spawned task.
    assert scr(h, 20, 13) == 0x70                   # top-left corner
    assert scr(h, 39, 13) == 0x6E                   # top-right corner
    assert scr(h, 20, 24) == 0x6D                   # bottom-left corner
    assert scr(h, 21, 13) == 0x13                   # 'S' of the "SHELL" title
