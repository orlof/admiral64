"""Tests for int_mul — variable-length signed integer multiplication."""

from __future__ import annotations

from conftest import RV
from test_int_add import place_int, read_int


def run_mul(h, a_bytes: list[int], b_bytes: list[int]) -> list[int]:
    rsp_initial = h.rsp
    a = place_int(h, 0x8A00, a_bytes)
    b = place_int(h, 0x9100, b_bytes)
    h.rs_push(a)
    h.rs_push(b)
    h.call("int_mul")
    assert h.rsp == rsp_initial, (
        f"int_mul violated stack discipline: expected RSP=${rsp_initial:04X}, "
        f"got ${h.rsp:04X}"
    )
    result_handle = h.read_word(RV)
    return read_int(h, result_handle)


# --- Zero cases -------------------------------------------------------------


def test_0_times_0(h):
    assert run_mul(h, [0x00], [0x00]) == [0x00]


def test_0_times_1(h):
    assert run_mul(h, [0x00], [0x01]) == [0x00]


def test_1_times_0(h):
    assert run_mul(h, [0x01], [0x00]) == [0x00]


def test_0_times_large(h):
    assert run_mul(h, [0x00], [0xE8, 0x03]) == [0x00]


# --- Small positive × positive ---------------------------------------------


def test_1_times_1(h):
    assert run_mul(h, [0x01], [0x01]) == [0x01]


def test_2_times_3(h):
    assert run_mul(h, [0x02], [0x03]) == [0x06]


def test_10_times_10(h):
    assert run_mul(h, [0x0A], [0x0A]) == [0x64]


def test_127_times_2_grows_to_2_bytes(h):
    # 127 * 2 = 254 = 0xFE. Single byte 0xFE would be -2, so result must be
    # [0xFE, 0x00] to represent +254.
    assert run_mul(h, [0x7F], [0x02]) == [0xFE, 0x00]


def test_16_times_16(h):
    # 256 = 0x0100, little-endian [0x00, 0x01]. Cannot shrink: stripping MSB
    # would leave [0x00] = 0.
    assert run_mul(h, [0x10], [0x10]) == [0x00, 0x01]


# --- Negative × positive, positive × negative ------------------------------


def test_neg1_times_1(h):
    assert run_mul(h, [0xFF], [0x01]) == [0xFF]


def test_1_times_neg1(h):
    assert run_mul(h, [0x01], [0xFF]) == [0xFF]


def test_neg1_times_neg1(h):
    assert run_mul(h, [0xFF], [0xFF]) == [0x01]


def test_neg128_times_1(h):
    # -128 * 1 = -128 = [0x80]
    assert run_mul(h, [0x80], [0x01]) == [0x80]


def test_neg128_times_2(h):
    # -128 * 2 = -256. Signed 2-byte 0xFF00, little-endian [0x00, 0xFF].
    assert run_mul(h, [0x80], [0x02]) == [0x00, 0xFF]


def test_neg128_times_neg128(h):
    # (-128) * (-128) = 16384 = 0x4000, little-endian [0x00, 0x40].
    assert run_mul(h, [0x80], [0x80]) == [0x00, 0x40]


# --- Multi-byte inputs -----------------------------------------------------


def test_1000_times_1000(h):
    # 1000 * 1000 = 1,000,000 = 0x0F4240 → [0x40, 0x42, 0x0F] little-endian.
    # MSB=0x0F has bit 7 clear → positive, cannot shrink (below has bit 7 set).
    assert run_mul(h, [0xE8, 0x03], [0xE8, 0x03]) == [0x40, 0x42, 0x0F]


def test_256_times_256(h):
    # 256 * 256 = 65536 = 0x010000 → [0x00, 0x00, 0x01] little-endian.
    assert run_mul(h, [0x00, 0x01], [0x00, 0x01]) == [0x00, 0x00, 0x01]


def test_neg1000_times_1000(h):
    # -1000 * 1000 = -1,000,000. -1,000,000 + 2^24 = 0xF0BDC0, signed 3-byte
    # is valid because MSB=0xF0 has bit 7 set (negative). Little-endian:
    # [0xC0, 0xBD, 0xF0]. MSB=0xF0 != 0xFF so cannot shrink.
    assert run_mul(h, [0x18, 0xFC], [0xE8, 0x03]) == [0xC0, 0xBD, 0xF0]


def test_neg1000_times_neg1000(h):
    # (-1000) * (-1000) = 1,000,000 (same as test_1000_times_1000).
    assert run_mul(h, [0x18, 0xFC], [0x18, 0xFC]) == [0x40, 0x42, 0x0F]


def test_small_times_large(h):
    # 3 * 1000 = 3000 = 0x0BB8 → [0xB8, 0x0B] little-endian. MSB=0x0B bit 7
    # clear, below=0xB8 bit 7 set → cannot shrink.
    assert run_mul(h, [0x03], [0xE8, 0x03]) == [0xB8, 0x0B]


def test_large_times_small(h):
    # Same as above with operands swapped (tests swap path in inner layout).
    assert run_mul(h, [0xE8, 0x03], [0x03]) == [0xB8, 0x0B]
