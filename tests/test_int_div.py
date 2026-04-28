"""Tests for int_div — signed integer truncating division (quotient)."""

from __future__ import annotations

from conftest import ERR_OOM, RV
from test_int_add import place_int, read_int

ERR_DIV_ZERO = 0x02


def run_div(h, a_bytes: list[int], b_bytes: list[int]) -> list[int]:
    rsp_initial = h.rsp
    a = place_int(h, 0x8500, a_bytes)
    b = place_int(h, 0x6100, b_bytes)
    h.rs_push(a)
    h.rs_push(b)
    h.call("int_div")
    assert h.rsp == rsp_initial
    return read_int(h, h.read_word(RV))


def run_div_panic(h, a_bytes: list[int], b_bytes: list[int]) -> int:
    a = place_int(h, 0x8500, a_bytes)
    b = place_int(h, 0x6100, b_bytes)
    h.rs_push(a)
    h.rs_push(b)
    h.call("int_div", expect_panic=True)
    return h.mpu.memory[0x27]  # ERROR_CODE


# --- div-by-zero panics -----------------------------------------------------

def test_div_by_zero_panics(h):
    assert run_div_panic(h, [0x05], [0x00]) == ERR_DIV_ZERO


def test_zero_div_by_zero_panics(h):
    assert run_div_panic(h, [0x00], [0x00]) == ERR_DIV_ZERO


# --- zero dividend -----------------------------------------------------------

def test_0_div_1(h):
    assert run_div(h, [0x00], [0x01]) == [0x00]


def test_0_div_large(h):
    assert run_div(h, [0x00], [0xE8, 0x03]) == [0x00]


# --- divide by 1 / self -----------------------------------------------------

def test_5_div_1(h):
    assert run_div(h, [0x05], [0x01]) == [0x05]


def test_5_div_5(h):
    assert run_div(h, [0x05], [0x05]) == [0x01]


def test_neg5_div_5(h):
    assert run_div(h, [0xFB], [0x05]) == [0xFF]        # -1


def test_neg5_div_neg5(h):
    assert run_div(h, [0xFB], [0xFB]) == [0x01]


# --- smaller dividend → q = 0 ----------------------------------------------

def test_3_div_10(h):
    assert run_div(h, [0x03], [0x0A]) == [0x00]


def test_neg3_div_10(h):
    # -3 / 10 truncates toward zero → 0 (not -1).
    assert run_div(h, [0xFD], [0x0A]) == [0x00]


# --- small positive × positive ---------------------------------------------

def test_10_div_3(h):
    # 10 / 3 = 3 rem 1
    assert run_div(h, [0x0A], [0x03]) == [0x03]


def test_100_div_7(h):
    # 100 / 7 = 14 rem 2
    assert run_div(h, [0x64], [0x07]) == [0x0E]


def test_127_div_2(h):
    # 127 / 2 = 63
    assert run_div(h, [0x7F], [0x02]) == [0x3F]


# --- signed combinations (truncating) ---------------------------------------

def test_neg10_div_3(h):
    # -10 / 3 → -3 (truncating). -10 = 0xF6.
    assert run_div(h, [0xF6], [0x03]) == [0xFD]


def test_10_div_neg3(h):
    # 10 / -3 → -3. -3 = 0xFD.
    assert run_div(h, [0x0A], [0xFD]) == [0xFD]


def test_neg10_div_neg3(h):
    # -10 / -3 → 3.
    assert run_div(h, [0xF6], [0xFD]) == [0x03]


# --- boundary: -128 -------------------------------------------------------

def test_neg128_div_1(h):
    # -128 / 1 = -128. Result [0x80].
    assert run_div(h, [0x80], [0x01]) == [0x80]


def test_neg128_div_neg1(h):
    # -128 / -1 = 128. Needs 2-byte positive: [0x80, 0x00].
    assert run_div(h, [0x80], [0xFF]) == [0x80, 0x00]


def test_neg128_div_2(h):
    # -128 / 2 = -64.
    assert run_div(h, [0x80], [0x02]) == [0xC0]


# --- multi-byte --------------------------------------------------------------

def test_1000_div_10(h):
    # 1000 / 10 = 100 (0x64).
    assert run_div(h, [0xE8, 0x03], [0x0A]) == [0x64]


def test_65535_div_255(h):
    # 65535 / 255 = 257 = 0x0101. As signed-positive: [0x01, 0x01] — MSB=0x01
    # bit 7 clear → positive, can't shrink (below has bit 7 clear too? actually
    # [0x01, 0x01] low=0x01 → signed 257 when MSB=0x01 has bit7 clear).
    # 65535 as signed-positive is 3 bytes: [0xFF, 0xFF, 0x00].
    assert run_div(h, [0xFF, 0xFF, 0x00], [0xFF, 0x00]) == [0x01, 0x01]


def test_1000_div_neg10(h):
    # 1000 / -10 = -100.
    # -100 signed 1 byte: 0x9C. Keep as 1-byte since -128..127 fits -100.
    assert run_div(h, [0xE8, 0x03], [0xF6]) == [0x9C]


def test_large_positive_div_itself(h):
    # 1000 / 1000 = 1.
    assert run_div(h, [0xE8, 0x03], [0xE8, 0x03]) == [0x01]
