"""Tests for int_cmp — three-way signed comparison."""

from __future__ import annotations

from test_int_add import place_int


def run_cmp(h, a_bytes: list[int], b_bytes: list[int]) -> int:
    rsp_initial = h.rsp
    a = place_int(h, 0x8500, a_bytes)
    b = place_int(h, 0x9100, b_bytes)
    h.rs_push(a)
    h.rs_push(b)
    h.call("int_cmp")
    assert h.rsp == rsp_initial, "int_cmp violated stack discipline"
    result = h.mpu.a
    return result - 256 if result >= 128 else result


# --- Equal values -----------------------------------------------------------


def test_0_eq_0(h):
    assert run_cmp(h, [0x00], [0x00]) == 0


def test_1_eq_1(h):
    assert run_cmp(h, [0x01], [0x01]) == 0


def test_neg1_eq_neg1(h):
    assert run_cmp(h, [0xFF], [0xFF]) == 0


def test_multi_byte_eq(h):
    assert run_cmp(h, [0xE8, 0x03], [0xE8, 0x03]) == 0


# --- Same-length, same-sign, differing bytes --------------------------------


def test_1_lt_2(h):
    assert run_cmp(h, [0x01], [0x02]) == -1


def test_2_gt_1(h):
    assert run_cmp(h, [0x02], [0x01]) == 1


def test_neg1_gt_neg2(h):
    assert run_cmp(h, [0xFF], [0xFE]) == 1


def test_neg2_lt_neg1(h):
    assert run_cmp(h, [0xFE], [0xFF]) == -1


def test_same_length_multi(h):
    assert run_cmp(h, [0xE8, 0x03], [0xE7, 0x03]) == 1


# --- Different lengths, same sign -------------------------------------------


def test_127_lt_128(h):
    assert run_cmp(h, [0x7F], [0x80, 0x00]) == -1


def test_128_gt_127(h):
    assert run_cmp(h, [0x80, 0x00], [0x7F]) == 1


def test_neg1_gt_neg128_longer(h):
    assert run_cmp(h, [0xFF], [0x7F, 0xFF]) == 1


def test_neg129_lt_neg1(h):
    assert run_cmp(h, [0x7F, 0xFF], [0xFF]) == -1


# --- Different signs --------------------------------------------------------


def test_0_gt_neg1(h):
    assert run_cmp(h, [0x00], [0xFF]) == 1


def test_neg1_lt_0(h):
    assert run_cmp(h, [0xFF], [0x00]) == -1


def test_pos_gt_neg(h):
    assert run_cmp(h, [0x01], [0xFF]) == 1


def test_neg_lt_pos(h):
    assert run_cmp(h, [0xFF], [0x01]) == -1


def test_large_cross_sign(h):
    assert run_cmp(h, [0xFF, 0x7F], [0x00, 0x80]) == 1
    assert run_cmp(h, [0x00, 0x80], [0xFF, 0x7F]) == -1
