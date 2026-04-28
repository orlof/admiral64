"""Tests for int_negate — variable-length signed integer negation."""

from __future__ import annotations

from conftest import RV
from test_int_add import place_int, read_int


def run_negate(h, a_bytes: list[int]) -> list[int]:
    rsp_initial = h.rsp
    a = place_int(h, 0x8500, a_bytes)
    h.rs_push(a)
    h.call("int_negate")
    assert h.rsp == rsp_initial, "int_negate violated stack discipline"
    result_handle = h.read_word(RV)
    return read_int(h, result_handle)


def test_neg_zero(h):
    assert run_negate(h, [0x00]) == [0x00]


def test_neg_one(h):
    assert run_negate(h, [0x01]) == [0xFF]


def test_neg_neg_one(h):
    assert run_negate(h, [0xFF]) == [0x01]


def test_neg_127(h):
    assert run_negate(h, [0x7F]) == [0x81]


def test_neg_min_byte_grows(h):
    assert run_negate(h, [0x80]) == [0x80, 0x00]


def test_neg_256(h):
    assert run_negate(h, [0x00, 0x01]) == [0x00, 0xFF]


def test_neg_neg_256(h):
    assert run_negate(h, [0x00, 0xFF]) == [0x00, 0x01]


def test_neg_min_2byte_grows(h):
    assert run_negate(h, [0x00, 0x80]) == [0x00, 0x80, 0x00]
