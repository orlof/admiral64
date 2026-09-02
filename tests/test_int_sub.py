"""Tests for int_sub — signed integer subtraction via int_negate + int_add."""

from __future__ import annotations

from conftest import RV
from test_int_add import place_int, read_int


def run_sub(h, a_bytes: list[int], b_bytes: list[int]) -> list[int]:
    rsp_initial = h.rsp
    a = place_int(h, 0x8800, a_bytes)
    b = place_int(h, 0x9100, b_bytes)
    h.rs_push(a)
    h.rs_push(b)
    h.call("int_sub")
    assert h.rsp == rsp_initial, "int_sub violated stack discipline"
    result_handle = h.read_word(RV)
    return read_int(h, result_handle)


def test_5_minus_3(h):
    assert run_sub(h, [0x05], [0x03]) == [0x02]


def test_3_minus_5(h):
    assert run_sub(h, [0x03], [0x05]) == [0xFE]


def test_0_minus_0(h):
    assert run_sub(h, [0x00], [0x00]) == [0x00]


def test_0_minus_1(h):
    assert run_sub(h, [0x00], [0x01]) == [0xFF]


def test_100_minus_neg50(h):
    assert run_sub(h, [0x64], [0xCE]) == [0x96, 0x00]


def test_neg128_minus_1(h):
    assert run_sub(h, [0x80], [0x01]) == [0x7F, 0xFF]


def test_large_minus_small(h):
    assert run_sub(h, [0xE8, 0x03], [0x01]) == [0xE7, 0x03]
