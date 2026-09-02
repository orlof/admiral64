"""Tests for print.asm — print_str / print_int + newline variants.

Relies on test_screen.py's knowledge of screen RAM layout. We call print_str
with a placed TYPE_STR handle and inspect the resulting screen codes.
"""

from __future__ import annotations

from conftest import RV
from test_screen import (
    SCREEN_BASE,
    SCREEN_COL_ZP,
    SCREEN_ROW_ZP,
    _screen_offset,
)
from test_str import place_str
from test_int_add import place_int


_PTSC_TABLE = [0x80, 0x00, 0xC0, 0xE0, 0x40, 0xC0, 0x80, 0x80]


def petscii_to_screen_code(b: int) -> int:
    """Mirror screen.asm's full PETSCII → screen-code lookup. Top 3 bits of
    the byte index a fixed offset table; result is `(table[b >> 5] + b) & 0xFF`.
    The single special case is PETSCII $FF (π) → screen $5E (also π).
    Internal storage is PETSCII uppercase ($41-$5A), which the general formula
    maps to screen codes $01-$1A directly (A..Z in the unshifted charset).
    """
    if b == 0xFF:
        return 0x5E
    return (_PTSC_TABLE[b >> 5] + b) & 0xFF


def _screen_codes(text: str) -> list[int]:
    return [petscii_to_screen_code(ord(c)) for c in text]


# --- print_str ---------------------------------------------------------------

def test_print_str_writes_payload(h):
    h.call("screen_init")
    s = place_str(h, 0x8900, [ord("H"), ord("I")])
    h.rs_push(s)
    h.call("print_str")

    # 'H' → $08, 'I' → $09.
    assert h.mpu.memory[_screen_offset(0, 0)] == 0x08
    assert h.mpu.memory[_screen_offset(0, 1)] == 0x09
    assert h.mpu.memory[SCREEN_COL_ZP] == 2
    assert h.mpu.memory[SCREEN_ROW_ZP] == 0


def test_print_str_empty_string_is_noop(h):
    h.call("screen_init")
    s = place_str(h, 0x8900, [])
    h.rs_push(s)
    h.call("print_str")
    assert h.mpu.memory[SCREEN_COL_ZP] == 0
    assert h.mpu.memory[SCREEN_ROW_ZP] == 0


def test_print_str_with_embedded_newline(h):
    h.call("screen_init")
    # "A\rB" — A at (0,0), CR advances to row 1, B at (1,0).
    s = place_str(h, 0x8900, [ord("A"), 0x0D, ord("B")])
    h.rs_push(s)
    h.call("print_str")
    assert h.mpu.memory[_screen_offset(0, 0)] == 0x01
    assert h.mpu.memory[_screen_offset(1, 0)] == 0x02
    assert h.mpu.memory[SCREEN_ROW_ZP] == 1
    assert h.mpu.memory[SCREEN_COL_ZP] == 1


def test_print_str_consumes_stack_arg(h):
    h.call("screen_init")
    rsp_initial = h.rsp
    s = place_str(h, 0x8900, [ord("X")])
    h.rs_push(s)
    h.call("print_str")
    assert h.rsp == rsp_initial, f"print_str leaked RS: {h.rsp:04X} vs {rsp_initial:04X}"


# --- print_int ---------------------------------------------------------------

def test_print_int_renders_decimal(h):
    h.call("screen_init")
    # 1000 → "1000"
    x = place_int(h, 0x8900, [0xE8, 0x03])
    h.rs_push(x)
    h.call("print_int")
    expected = _screen_codes("1000")
    for col, code in enumerate(expected):
        assert h.mpu.memory[_screen_offset(0, col)] == code, f"col {col}"
    assert h.mpu.memory[SCREEN_COL_ZP] == len(expected)


def test_print_int_negative(h):
    h.call("screen_init")
    # -128 → "-128"
    x = place_int(h, 0x8900, [0x80])
    h.rs_push(x)
    h.call("print_int")
    expected = _screen_codes("-128")
    for col, code in enumerate(expected):
        assert h.mpu.memory[_screen_offset(0, col)] == code


def test_print_int_zero(h):
    h.call("screen_init")
    x = place_int(h, 0x8900, [0x00])
    h.rs_push(x)
    h.call("print_int")
    assert h.mpu.memory[_screen_offset(0, 0)] == 0x30  # '0'
    assert h.mpu.memory[SCREEN_COL_ZP] == 1


def test_print_int_consumes_stack_arg(h):
    h.call("screen_init")
    rsp_initial = h.rsp
    x = place_int(h, 0x8900, [0x2A])  # 42
    h.rs_push(x)
    h.call("print_int")
    assert h.rsp == rsp_initial


# --- println variants --------------------------------------------------------

def test_println_str_adds_newline(h):
    h.call("screen_init")
    s = place_str(h, 0x8900, [ord("A"), ord("B")])
    h.rs_push(s)
    h.call("println_str")
    assert h.mpu.memory[_screen_offset(0, 0)] == 0x01  # 'A'
    assert h.mpu.memory[_screen_offset(0, 1)] == 0x02  # 'B'
    assert h.mpu.memory[SCREEN_ROW_ZP] == 1
    assert h.mpu.memory[SCREEN_COL_ZP] == 0


def test_println_int_adds_newline(h):
    h.call("screen_init")
    x = place_int(h, 0x8900, [0x05])
    h.rs_push(x)
    h.call("println_int")
    assert h.mpu.memory[_screen_offset(0, 0)] == 0x35  # '5'
    assert h.mpu.memory[SCREEN_ROW_ZP] == 1
    assert h.mpu.memory[SCREEN_COL_ZP] == 0
