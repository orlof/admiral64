"""Tests for int_sgn — return the sign of a signed int."""

from __future__ import annotations

from test_int_add import place_int


def run_sgn(h, a_bytes: list[int]) -> int:
    rsp_initial = h.rsp
    a = place_int(h, 0x8800, a_bytes)
    h.rs_push(a)
    h.call("int_sgn")
    assert h.rsp == rsp_initial, "int_sgn violated stack discipline"
    result = h.mpu.a
    return result - 256 if result >= 128 else result


def test_zero(h):
    assert run_sgn(h, [0x00]) == 0


def test_one(h):
    assert run_sgn(h, [0x01]) == 1


def test_positive_byte(h):
    assert run_sgn(h, [0x7F]) == 1


def test_negative_one(h):
    assert run_sgn(h, [0xFF]) == -1


def test_min_byte(h):
    assert run_sgn(h, [0x80]) == -1


def test_positive_two_byte(h):
    assert run_sgn(h, [0x80, 0x00]) == 1


def test_large_positive(h):
    assert run_sgn(h, [0xE8, 0x03]) == 1


def test_negative_two_byte(h):
    assert run_sgn(h, [0x00, 0x80]) == -1
