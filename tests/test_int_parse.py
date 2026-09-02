"""Tests for int_parse_dec / int_parse_hex / int_parse_bin.

These take a raw byte span (W0 = ptr, A = length) and produce a TYPE_INT
handle. Used by Stage 8's TK_INT / TK_HEX / TK_BIN NUDs.
"""

from __future__ import annotations

import pytest

from conftest import RV, W0, TYPE_INT
from test_int_add import H_PTR, H_SIZE, H_TYPE, O_HEADER, O_LEN


def _read_int(h, handle: int) -> int:
    """Read a handle as a small signed integer.

    TYPE_INT is the inline 32-bit value. For boxed types (BOOL, STR, ...) this
    reads the payload bytes as a signed little-endian int — the historical
    behavior many tests rely on (BOOL → 0/1, 1-char STR → its byte value).
    """
    if h.mpu.memory[handle + H_TYPE] == TYPE_INT:
        lo = h.read_word(handle + H_PTR)
        hi = h.read_word(handle + H_SIZE)
        val = lo | (hi << 16)
        if val & 0x8000_0000:
            val -= 0x1_0000_0000
        return val
    obj = h.read_word(handle + H_PTR)
    length = h.read_word(obj + O_LEN)
    payload = bytes(h.read_bytes(obj + O_HEADER, length))
    if not payload:
        return 0
    return int.from_bytes(payload, "little", signed=True)


def _stage_span(h, text: str, addr: int = 0x8900) -> int:
    """Place raw byte span at addr, set W0 = addr. Returns length."""
    payload = list(text.encode("ascii"))
    for i, b in enumerate(payload):
        h.mpu.memory[addr + i] = b
    h.write_word(W0, addr)
    return len(payload)


def _parse(h, label: str, text: str) -> int:
    length = _stage_span(h, text)
    h.call(label, a=length)
    return _read_int(h, h.read_word(RV))


# --- int_parse_dec ----------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("0", 0),
    ("1", 1),
    ("9", 9),
    ("10", 10),
    ("99", 99),
    ("100", 100),
    ("255", 255),
    ("256", 256),
    ("1000", 1000),
    ("65535", 65535),
    ("65536", 65536),
    ("123456", 123456),
    ("1000000", 1000000),
    ("16777215", 16777215),       # 2^24 - 1, fits in 3 bytes
    ("16777216", 16777216),       # 2^24, needs 4 bytes
    ("2147483647", 2147483647),   # max int32
])
def test_int_parse_dec(h, text, expected):
    assert _parse(h, "int_parse_dec", text) == expected


def test_int_parse_dec_returns_type_int(h):
    _stage_span(h, "42")
    h.call("int_parse_dec", a=2)
    handle = h.read_word(RV)
    assert h.mpu.memory[handle + H_TYPE] == TYPE_INT


# --- int_parse_hex ----------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("0x0", 0),
    ("0x1", 1),
    ("0x9", 9),
    ("0xa", 10),
    ("0xA", 10),
    ("0xf", 15),
    ("0xF", 15),
    ("0x10", 16),
    ("0xff", 255),
    ("0xFF", 255),
    ("0x100", 256),
    ("0xDeadBeef", 0xDEADBEEF - 0x1_0000_0000),  # 32-bit signed: -559038737
    ("0X1A", 26),
    ("0x12345678", 0x12345678),
])
def test_int_parse_hex(h, text, expected):
    assert _parse(h, "int_parse_hex", text) == expected


# --- int_parse_bin ----------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("0b0", 0),
    ("0b1", 1),
    ("0b10", 2),
    ("0b11", 3),
    ("0b101", 5),
    ("0b11111111", 255),
    ("0b100000000", 256),
    ("0B1010", 10),
    ("0b1111111111111111", 65535),
])
def test_int_parse_bin(h, text, expected):
    assert _parse(h, "int_parse_bin", text) == expected
