"""Tests for int_normalize — strip redundant leading sign bytes in place."""

from __future__ import annotations

from conftest import RV
from test_int_add import place_int, read_int


def run_normalize(h, a_bytes: list[int]) -> list[int]:
    rsp_initial = h.rsp
    a = place_int(h, 0x7800, a_bytes)
    h.rs_push(a)
    h.call("int_normalize")
    assert h.rsp == rsp_initial, "int_normalize violated stack discipline"
    # int_normalize returns the SAME handle (mutated in place).
    result_handle = h.read_word(RV)
    assert result_handle == a, "int_normalize should return the same handle"
    return read_int(h, result_handle)


# --- No-ops (already canonical) ---------------------------------------------


def test_single_zero(h):
    assert run_normalize(h, [0x00]) == [0x00]


def test_single_positive(h):
    assert run_normalize(h, [0x7F]) == [0x7F]


def test_single_negative(h):
    assert run_normalize(h, [0xFF]) == [0xFF]


def test_80_00_no_shrink(h):
    assert run_normalize(h, [0x80, 0x00]) == [0x80, 0x00]


def test_FF_00_no_shrink(h):
    assert run_normalize(h, [0xFF, 0x00]) == [0xFF, 0x00]


def test_7F_FF_no_shrink(h):
    assert run_normalize(h, [0x7F, 0xFF]) == [0x7F, 0xFF]


# --- Redundant positive bytes ----------------------------------------------


def test_zero_multi_shrinks_to_one(h):
    assert run_normalize(h, [0x00, 0x00]) == [0x00]


def test_zero_three_bytes_shrinks_to_one(h):
    assert run_normalize(h, [0x00, 0x00, 0x00]) == [0x00]


def test_two_positive_shrinks(h):
    assert run_normalize(h, [0x02, 0x00]) == [0x02]


def test_two_positive_three_bytes(h):
    assert run_normalize(h, [0x02, 0x00, 0x00]) == [0x02]


def test_999_shrinks_one_byte(h):
    assert run_normalize(h, [0xE7, 0x03, 0x00]) == [0xE7, 0x03]


# --- Redundant negative bytes ----------------------------------------------


def test_neg_one_multi_shrinks(h):
    assert run_normalize(h, [0xFF, 0xFF]) == [0xFF]


def test_neg_one_three_bytes(h):
    assert run_normalize(h, [0xFF, 0xFF, 0xFF]) == [0xFF]


def test_neg_two_shrinks(h):
    assert run_normalize(h, [0xFE, 0xFF]) == [0xFE]


def test_neg_129_shrinks_one_byte(h):
    assert run_normalize(h, [0x7F, 0xFF, 0xFF]) == [0x7F, 0xFF]
