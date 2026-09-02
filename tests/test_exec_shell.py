"""EXEC() builtin + the user-space SHELL (examples/shell.admiral).

EXEC runs source in the ROOT scope with REPL semantics (auto-print, `_`
binding) and always returns NONE. SHELL is a plain string record driven via
the GETIN stub; the kernel error handler restarts it after a panic.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

import pytest

from conftest import RV, ERROR_CODE_ZP
from test_str import place_str, read_str
from test_parser import _eval, _eval_str, _stub_getin_queue

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCREEN = 0x0400


# --- EXEC --------------------------------------------------------------------

def test_exec_runs_in_root_scope(h):
    assert _eval(h, 'X = 1\nEXEC("X = X + 1")\nX') == 2


def test_exec_returns_none(h):
    # EXEC("1+2") auto-prints but the call itself yields NONE — usable as a
    # bare statement without poisoning `_`-style storage.
    assert _eval(h, 'A = 5\nEXEC("9")\nA') == 5


def test_exec_autoprints_value(h):
    _eval(h, 'EXEC("1 + 2")\n0')
    # "3" printed at top-left (fresh screen in py65).
    assert h.mpu.memory[SCREEN] == 0x33          # '3'


def test_exec_binds_underscore(h):
    assert _eval(h, 'EXEC("6 * 7")\n_ + 0') == 42


def test_exec_outer_parse_resumes(h):
    # The outer program continues correctly after EXEC (lexer save/restore).
    assert _eval(h, 'X = 5\nEXEC("Y = 1")\nX + Y') == 6


def test_exec_from_function_writes_root_scope(h):
    # Python-exec-style: EXEC targets the ROOT scope even from inside a
    # function call's local scope.
    src = ('F = "EXEC(\\"Z = 7\\")\\nRETURN 1"\n'
           'F()\n'
           'Z')
    assert _eval(h, src) == 7


def test_exec_type_panics(h):
    from conftest import ERR_TYPE
    payload = list('EXEC(123)'.encode("ascii"))
    handle = place_str(h, 0x8800, payload)
    h.rs_push(handle)
    with pytest.raises(Exception):
        h.call("parser_eval", max_steps=2_000_000)
    assert h.mpu.memory[ERROR_CODE_ZP] == ERR_TYPE


def test_exec_nested(h):
    assert _eval(h, 'EXEC("EXEC(\\"N = 3\\")\\nN = N + 1")\nN') == 4


# --- SHELL (driven at the repl level with the GETIN stub) --------------------

@pytest.fixture(scope="session")
def shell_record() -> bytes:
    out = ROOT / "build" / "shell_test.bin"
    r = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "pack_str_record.py"),
         str(ROOT / "examples" / "shell.admiral"), str(out)],
        cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return out.read_bytes()


def _run_shell(h, shell_record, keys: bytes, steps=40_000_000):
    """Bind SHELL from the record, start it, feed keys, run `steps` steps.

    The shell loops forever (WHILE 1 + INPUT), so this never 'returns' —
    the caller inspects screen / scope afterwards.
    """
    h.kernal_mock.files[b"SHELL"] = shell_record
    _stub_getin_queue(h, keys)
    src = 'SHELL = LOAD("SHELL")\nSHELL()'
    handle = place_str(h, 0x8800, list(src.encode("ascii")))
    h.rs_push(handle)
    sentinel = 0xFFFE
    h.mpu.memory[0x0100 + h.mpu.sp] = (sentinel >> 8) & 0xFF
    h.mpu.sp = (h.mpu.sp - 1) & 0xFF
    h.mpu.memory[0x0100 + h.mpu.sp] = sentinel & 0xFF
    h.mpu.sp = (h.mpu.sp - 1) & 0xFF
    h.mpu.pc = h.sym["parser_eval"]
    # Seed the panic-recovery snapshot that repl_main captures on real
    # hardware (this test bypasses repl_main). error_handler unwinds here.
    RSP = h.read_word(0x04)
    FSP = h.read_word(0x02)
    FP = h.read_word(0x06)
    h.mpu.memory[h.sym["repl_rec_s"]] = h.mpu.sp
    h.write_word(h.sym["repl_rec_rsp"], RSP)
    h.write_word(h.sym["repl_rec_fsp"], FSP)
    h.write_word(h.sym["repl_rec_fp"], FP)
    for _ in range(steps):
        if h.kernal_mock.step_hook():
            continue
        if h.mpu.pc == sentinel + 1:
            break
        h.mpu.step()


def _screen_text(h, row):
    return bytes(h.mpu.memory[SCREEN + row * 40:SCREEN + row * 40 + 20])


def test_shell_executes_lines(hd, shell_record):
    _run_shell(hd, shell_record, b"PRINT 5\r\x00")
    # Prompt "] " echoed, then 5 printed on the next row.
    flat = bytes(h for r in range(6) for h in _screen_text(hd, r))
    assert 0x35 in flat                       # '5' rendered somewhere early


def test_shell_variables_persist_across_lines(hd, shell_record):
    _run_shell(hd, shell_record, b"V = 8\rPRINT V\r\x00")
    flat = bytes(h for r in range(8) for h in _screen_text(hd, r))
    assert 0x38 in flat                       # '8'


def test_shell_restarts_after_panic(hd, shell_record):
    # Line 1 panics (unknown name); the error handler restarts SHELL, and
    # line 2 must still execute — with V surviving in the root scope? V is
    # set after the crash here; the point is the second line runs at all.
    _run_shell(hd, shell_record, b"FOO\rPRINT 7\r\x00", steps=60_000_000)
    flat = bytes(h for r in range(12) for h in _screen_text(hd, r))
    assert 0x3F in flat                       # '?' of ?ERR
    assert 0x37 in flat                       # '7' printed post-restart
