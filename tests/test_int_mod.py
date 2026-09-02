"""Tests for int_mod — signed integer truncating remainder.

Truncating semantics: sign(a % b) == sign(a).
"""

from __future__ import annotations

from conftest import RV
from test_int_add import place_int, read_int


def run_mod(h, a_bytes: list[int], b_bytes: list[int]) -> list[int]:
    rsp_initial = h.rsp
    a = place_int(h, 0x8900, a_bytes)
    b = place_int(h, 0x9100, b_bytes)
    h.rs_push(a)
    h.rs_push(b)
    h.call("int_mod")
    assert h.rsp == rsp_initial
    return read_int(h, h.read_word(RV))


# --- zero dividend -----------------------------------------------------------

def test_0_mod_1(h):
    assert run_mod(h, [0x00], [0x01]) == [0x00]


def test_0_mod_large(h):
    assert run_mod(h, [0x00], [0xE8, 0x03]) == [0x00]


# --- divide by 1 / self -----------------------------------------------------

def test_5_mod_1(h):
    assert run_mod(h, [0x05], [0x01]) == [0x00]


def test_5_mod_5(h):
    assert run_mod(h, [0x05], [0x05]) == [0x00]


# --- smaller dividend → r = a ----------------------------------------------

def test_3_mod_10(h):
    assert run_mod(h, [0x03], [0x0A]) == [0x03]


def test_neg3_mod_10(h):
    # -3 mod 10 → -3 (truncating: sign follows dividend).
    assert run_mod(h, [0xFD], [0x0A]) == [0xFD]


# --- small positive ---------------------------------------------------------

def test_10_mod_3(h):
    # 10 mod 3 = 1
    assert run_mod(h, [0x0A], [0x03]) == [0x01]


def test_100_mod_7(h):
    # 100 mod 7 = 2
    assert run_mod(h, [0x64], [0x07]) == [0x02]


def test_127_mod_2(h):
    # 127 mod 2 = 1
    assert run_mod(h, [0x7F], [0x02]) == [0x01]


# --- signed combinations (sign of dividend) --------------------------------

def test_neg10_mod_3(h):
    # -10 mod 3 → -1 (since -10 = 3 * (-3) + (-1))
    assert run_mod(h, [0xF6], [0x03]) == [0xFF]


def test_10_mod_neg3(h):
    # 10 mod -3 → 1 (since 10 = (-3) * (-3) + 1)
    assert run_mod(h, [0x0A], [0xFD]) == [0x01]


def test_neg10_mod_neg3(h):
    # -10 mod -3 → -1
    assert run_mod(h, [0xF6], [0xFD]) == [0xFF]


# --- boundary ---------------------------------------------------------------

def test_neg128_mod_1(h):
    assert run_mod(h, [0x80], [0x01]) == [0x00]


def test_neg128_mod_neg1(h):
    assert run_mod(h, [0x80], [0xFF]) == [0x00]


def test_neg128_mod_3(h):
    # -128 mod 3 = -2 (since -128 = 3*(-42) + (-2))
    assert run_mod(h, [0x80], [0x03]) == [0xFE]


# --- multi-byte ---------------------------------------------------------

def test_1000_mod_10(h):
    assert run_mod(h, [0xE8, 0x03], [0x0A]) == [0x00]


def test_1000_mod_7(h):
    # 1000 mod 7 = 6
    assert run_mod(h, [0xE8, 0x03], [0x07]) == [0x06]


def test_1000_mod_neg7(h):
    # 1000 mod -7 → 6 (sign of dividend)
    assert run_mod(h, [0xE8, 0x03], [0xF9]) == [0x06]


def test_neg1000_mod_7(h):
    # -1000 mod 7 → -6
    assert run_mod(h, [0x18, 0xFC], [0x07]) == [0xFA]
