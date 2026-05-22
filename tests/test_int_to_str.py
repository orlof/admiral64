"""Tests for int_to_str — signed integer → decimal ASCII string.

Verifies the returned string's payload (raw ASCII bytes) against the expected
digit sequence. Sign byte '-' is encoded as 0x2D, digits 0..9 as 0x30..0x39.
"""

from __future__ import annotations

from conftest import RV
from test_int_add import place_int, H_TYPE
from test_str import read_str


def ascii_bytes(s: str) -> list[int]:
    return [ord(c) for c in s]


def run_to_str(h, payload_bytes: list[int], max_steps: int = 100_000) -> list[int]:
    """Place an int with the given payload, call int_to_str, return the
    resulting string's payload bytes."""
    rsp_initial = h.rsp
    x = place_int(h, 0x8500, payload_bytes)
    h.rs_push(x)
    h.call("int_to_str", max_steps=max_steps)
    assert h.rsp == rsp_initial, (
        f"int_to_str violated stack discipline: expected RSP=${rsp_initial:04X}, "
        f"got ${h.rsp:04X}"
    )
    return read_str(h, h.read_word(RV))


def run_to_str_and_handle(h, payload_bytes: list[int]) -> tuple[list[int], int]:
    """Like run_to_str but also returns the string handle address (for callers
    that want to check H_TYPE etc.)."""
    x = place_int(h, 0x8500, payload_bytes)
    h.rs_push(x)
    h.call("int_to_str")
    handle = h.read_word(RV)
    return read_str(h, handle), handle


# --- zero ---------------------------------------------------------------------

def test_zero(h):
    assert run_to_str(h, [0x00]) == ascii_bytes("0")


# --- single-digit positive ----------------------------------------------------

def test_1(h):
    assert run_to_str(h, [0x01]) == ascii_bytes("1")


def test_9(h):
    assert run_to_str(h, [0x09]) == ascii_bytes("9")


# --- two-digit positive -------------------------------------------------------

def test_10(h):
    assert run_to_str(h, [0x0A]) == ascii_bytes("10")


def test_99(h):
    assert run_to_str(h, [0x63]) == ascii_bytes("99")


# --- three-digit positive -----------------------------------------------------

def test_100(h):
    assert run_to_str(h, [0x64]) == ascii_bytes("100")


def test_127_max_signed_byte(h):
    assert run_to_str(h, [0x7F]) == ascii_bytes("127")


# --- single-digit negative ----------------------------------------------------

def test_neg1(h):
    # -1 = 0xFF
    assert run_to_str(h, [0xFF]) == ascii_bytes("-1")


def test_neg9(h):
    # -9 = 0xF7
    assert run_to_str(h, [0xF7]) == ascii_bytes("-9")


# --- two-digit negative -------------------------------------------------------

def test_neg10(h):
    # -10 = 0xF6
    assert run_to_str(h, [0xF6]) == ascii_bytes("-10")


def test_neg128_min_signed_byte(h):
    # -128 = 0x80. Magnitude 128 requires 2 bytes: [0x80, 0x00].
    assert run_to_str(h, [0x80]) == ascii_bytes("-128")


# --- multi-byte positive ------------------------------------------------------

def test_1000(h):
    assert run_to_str(h, [0xE8, 0x03]) == ascii_bytes("1000")


def test_32767_max_signed_short(h):
    assert run_to_str(h, [0xFF, 0x7F]) == ascii_bytes("32767")


def test_65535_as_3byte_positive(h):
    # 65535 as signed-positive is 3 bytes: [0xFF, 0xFF, 0x00].
    assert run_to_str(h, [0xFF, 0xFF, 0x00]) == ascii_bytes("65535")


# --- multi-byte negative ------------------------------------------------------

def test_neg1000(h):
    # -1000 in 2 bytes: [0x18, 0xFC]
    assert run_to_str(h, [0x18, 0xFC]) == ascii_bytes("-1000")


def test_neg32768_min_signed_short(h):
    # -32768 = 0x8000 little-endian. Magnitude 32768 = [0x00, 0x80, 0x00].
    assert run_to_str(h, [0x00, 0x80]) == ascii_bytes("-32768")


# --- return type is TYPE_STR --------------------------------------------------

def test_returns_type_str(h):
    from conftest import TYPE_STR
    _bytes, handle = run_to_str_and_handle(h, [0x2A])  # 42
    assert h.mpu.memory[handle + H_TYPE] == TYPE_STR


# --- GC pressure: allocate many temporaries during conversion -----------------

def test_large_value_under_tight_gc_pressure(h):
    # Pre-fill heap so that int_divmod's Q/R allocations during digit
    # extraction force gc_collect to run mid-conversion. Result must still
    # be correct.
    garbage1 = h.alloc_int(500)  # unrooted garbage
    garbage2 = h.alloc_int(500)  # unrooted garbage
    del garbage1, garbage2
    assert run_to_str(h, [0xFF, 0xFF, 0x00]) == ascii_bytes("65535")


# --- wide payloads: regression on the byte-index sign-bit aliasing ------------
# Two prior bugs only fired on big integers:
#   1. int_divmod's outer loop used bmi/bpl on X as the byte index, treating
#      any X >= $80 (i.e. dividend payload >= 129 bytes) as underflow → Q
#      came back all zeros.
#   2. int_to_str's digit counter was 8-bit (B1), so any value rendering to
#      > 255 decimal digits got truncated.
# NOTE: arbitrary-precision tests (e.g. 2**1024) were removed with the move to
# fixed 32-bit integers — such values now wrap mod 2³². Boundary coverage for
# the 32-bit range lives in test_int_boundary.py.
