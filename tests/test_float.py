"""Tests for TYPE_FLOAT — BASIC ROM-backed floating point.

Layout: heap object O_LEN = 5, payload = 5 bytes of MS-Basic packed format
(byte 0 = exponent excess-128; byte 1 = sign-bit + mantissa MSB; bytes 2-4
= mantissa low). Operations are wrappers around BASIC ROM FP routines:
FADDT/FSUBT/FMULTT/FDIVT (register-form, operands in FAC1/FAC2 ZP).

These tests need the BASIC ROM bytes loaded at $A000-$BFFF — use the `hfp`
fixture rather than the bare `h` fixture.
"""

from __future__ import annotations

import math

import pytest

from conftest import (
    FAC1,
    FAC2,
    RV,
    TYPE_FLOAT,
    TYPE_INT,
    msbasic_to_python,
    python_to_msbasic,
)
from test_int_add import (
    H_FLAGS,
    H_NEXT,
    H_PTR,
    H_SIZE,
    H_TYPE,
    O_HEADER,
    O_LEN,
    SIZEOF_HANDLE,
    place_int,
    read_int,
)
from test_str import read_str


# --- Python-side helpers -----------------------------------------------------


def place_float(h, addr: int, packed: bytes | list[int]) -> int:
    """Hand-place a TYPE_FLOAT handle+object at `addr`. Returns handle addr."""
    payload = list(packed)
    assert len(payload) == 5, f"float payload must be 5 bytes, got {len(payload)}"
    handle_addr = addr
    object_addr = addr + SIZEOF_HANDLE
    h.write_word(handle_addr + H_PTR, object_addr)
    h.write_word(handle_addr + H_SIZE, O_HEADER + 5)
    h.write_word(handle_addr + H_NEXT, 0)
    h.mpu.memory[handle_addr + H_TYPE] = TYPE_FLOAT
    h.mpu.memory[handle_addr + H_FLAGS] = 0
    h.write_word(object_addr + O_LEN, 5)
    h.write_bytes(object_addr + O_HEADER, payload)
    return handle_addr


def place_python_float(h, addr: int, value: float) -> int:
    return place_float(h, addr, python_to_msbasic(value))


def read_float_bytes(h, handle_addr: int) -> bytes:
    obj = h.read_word(handle_addr + H_PTR)
    return bytes(h.read_bytes(obj + O_HEADER, 5))


def read_float_value(h, handle_addr: int) -> float:
    return msbasic_to_python(read_float_bytes(h, handle_addr))


# --- Python helper sanity ----------------------------------------------------


def test_helper_zero():
    assert python_to_msbasic(0.0) == bytes([0x00, 0x00, 0x00, 0x00, 0x00])


def test_helper_one():
    assert python_to_msbasic(1.0) == bytes([0x81, 0x00, 0x00, 0x00, 0x00])


def test_helper_neg_one():
    assert python_to_msbasic(-1.0) == bytes([0x81, 0x80, 0x00, 0x00, 0x00])


def test_helper_two():
    assert python_to_msbasic(2.0) == bytes([0x82, 0x00, 0x00, 0x00, 0x00])


def test_helper_half():
    assert python_to_msbasic(0.5) == bytes([0x80, 0x00, 0x00, 0x00, 0x00])


def test_helper_seven():
    # 7 = 1.75 * 2^2 → exp $83, mantissa fraction .75 = top 7 bits 0b1100000 → $60
    assert python_to_msbasic(7.0) == bytes([0x83, 0x60, 0x00, 0x00, 0x00])


def test_helper_256():
    assert python_to_msbasic(256.0) == bytes([0x89, 0x00, 0x00, 0x00, 0x00])


@pytest.mark.parametrize("v", [0.0, 1.0, -1.0, 2.0, 0.5, 7.0, -7.0, 256.0, 3.14, -0.001, 1e6, -1e6])
def test_helper_round_trip(v):
    assert msbasic_to_python(python_to_msbasic(v)) == pytest.approx(v, rel=1e-7)


# --- float_alloc -------------------------------------------------------------


def test_alloc_sets_type_tag(hfp):
    hfp.call("float_alloc")
    handle = hfp.read_word(RV)
    assert hfp.mpu.memory[handle + H_TYPE] == TYPE_FLOAT


def test_alloc_sets_h_size_with_header(hfp):
    hfp.call("float_alloc")
    handle = hfp.read_word(RV)
    assert hfp.read_word(handle + H_SIZE) == O_HEADER + 5


def test_alloc_sets_o_len_to_5(hfp):
    hfp.call("float_alloc")
    handle = hfp.read_word(RV)
    obj = hfp.read_word(handle + H_PTR)
    assert hfp.read_word(obj + O_LEN) == 5


def test_alloc_canonical_zero(hfp):
    hfp.call("float_alloc")
    handle = hfp.read_word(RV)
    assert read_float_bytes(hfp, handle) == bytes(5)


def test_alloc_value_is_zero(hfp):
    hfp.call("float_alloc")
    handle = hfp.read_word(RV)
    assert read_float_value(hfp, handle) == 0.0


# --- pack/unpack via _fp_unpack_to_fac1 / _fp_pack_from_fac1 -----------------


def test_unpack_to_fac1_one(hfp):
    """Hand-place 1.0, call _fp_unpack_to_fac1 with W2 = payload pointer."""
    f = place_python_float(hfp, 0x8900, 1.0)
    obj = hfp.read_word(f + H_PTR)
    hfp.write_word(0x14, obj + O_HEADER)  # W2 = payload pointer
    hfp.call("_fp_unpack_to_fac1")
    # FAC1: exp=$81, mantissa MSB = $00 OR $80 = $80 (hidden bit set), sign=$00
    assert hfp.mpu.memory[FAC1] == 0x81
    assert hfp.mpu.memory[FAC1 + 1] == 0x80
    assert hfp.mpu.memory[FAC1 + 2] == 0x00
    assert hfp.mpu.memory[FAC1 + 3] == 0x00
    assert hfp.mpu.memory[FAC1 + 4] == 0x00
    assert hfp.mpu.memory[FAC1 + 5] == 0x00  # positive


def test_unpack_to_fac1_neg_one(hfp):
    f = place_python_float(hfp, 0x8900, -1.0)
    obj = hfp.read_word(f + H_PTR)
    hfp.write_word(0x14, obj + O_HEADER)
    hfp.call("_fp_unpack_to_fac1")
    assert hfp.mpu.memory[FAC1] == 0x81
    assert hfp.mpu.memory[FAC1 + 1] == 0x80
    assert hfp.mpu.memory[FAC1 + 5] == 0xFF  # negative


def test_unpack_to_fac1_zero(hfp):
    f = place_python_float(hfp, 0x8900, 0.0)
    obj = hfp.read_word(f + H_PTR)
    hfp.write_word(0x14, obj + O_HEADER)
    hfp.call("_fp_unpack_to_fac1")
    # All bytes zeroed for canonical zero
    for off in range(6):
        assert hfp.mpu.memory[FAC1 + off] == 0


def test_unpack_to_fac2_one(hfp):
    f = place_python_float(hfp, 0x8900, 1.0)
    obj = hfp.read_word(f + H_PTR)
    hfp.write_word(0x14, obj + O_HEADER)
    hfp.call("_fp_unpack_to_fac2")
    assert hfp.mpu.memory[FAC2] == 0x81
    assert hfp.mpu.memory[FAC2 + 1] == 0x80


def test_pack_from_fac1_round_trip_one(hfp):
    """Set FAC1 to 1.0 manually, pack to a 5-byte heap area, verify."""
    # Unpacked 1.0 in FAC1
    hfp.mpu.memory[FAC1] = 0x81
    hfp.mpu.memory[FAC1 + 1] = 0x80
    hfp.mpu.memory[FAC1 + 2] = 0x00
    hfp.mpu.memory[FAC1 + 3] = 0x00
    hfp.mpu.memory[FAC1 + 4] = 0x00
    hfp.mpu.memory[FAC1 + 5] = 0x00
    # Destination buffer at $6000 — we'll just compare 5 bytes
    hfp.write_word(0x14, 0x8900)
    hfp.call("_fp_pack_from_fac1")
    assert hfp.read_bytes(0x8900, 5) == [0x81, 0x00, 0x00, 0x00, 0x00]


def test_pack_from_fac1_neg_one(hfp):
    hfp.mpu.memory[FAC1] = 0x81
    hfp.mpu.memory[FAC1 + 1] = 0x80
    hfp.mpu.memory[FAC1 + 5] = 0xFF  # negative
    for off in (2, 3, 4):
        hfp.mpu.memory[FAC1 + off] = 0
    hfp.write_word(0x14, 0x8900)
    hfp.call("_fp_pack_from_fac1")
    assert hfp.read_bytes(0x8900, 5) == [0x81, 0x80, 0x00, 0x00, 0x00]


def test_pack_from_fac1_zero_canonical(hfp):
    """Even if FAC1's mantissa has random bytes, exp=0 produces canonical zero."""
    hfp.mpu.memory[FAC1] = 0x00  # exp=0 → zero
    hfp.mpu.memory[FAC1 + 1] = 0xAB
    hfp.mpu.memory[FAC1 + 2] = 0xCD
    hfp.mpu.memory[FAC1 + 3] = 0xEF
    hfp.mpu.memory[FAC1 + 4] = 0x12
    hfp.mpu.memory[FAC1 + 5] = 0xFF
    hfp.write_word(0x14, 0x8900)
    hfp.call("_fp_pack_from_fac1")
    assert hfp.read_bytes(0x8900, 5) == [0, 0, 0, 0, 0]


# --- int_to_float ------------------------------------------------------------


def run_int_to_float(hfp, payload: list[int]) -> float:
    rsp_initial = hfp.rsp
    x = place_int(hfp, 0x8900, payload)
    hfp.rs_push(x)
    hfp.call("int_to_float")
    assert hfp.rsp == rsp_initial, "int_to_float violated stack discipline"
    handle = hfp.read_word(RV)
    assert hfp.mpu.memory[handle + H_TYPE] == TYPE_FLOAT
    return read_float_value(hfp, handle)


def test_int_to_float_zero_empty(hfp):
    assert run_int_to_float(hfp, []) == 0.0


def test_int_to_float_zero_one_byte(hfp):
    assert run_int_to_float(hfp, [0x00]) == 0.0


def test_int_to_float_one(hfp):
    assert run_int_to_float(hfp, [0x01]) == 1.0


def test_int_to_float_neg_one(hfp):
    assert run_int_to_float(hfp, [0xFF]) == -1.0


def test_int_to_float_seven(hfp):
    assert run_int_to_float(hfp, [0x07]) == 7.0


def test_int_to_float_127(hfp):
    assert run_int_to_float(hfp, [0x7F]) == 127.0


def test_int_to_float_neg_128(hfp):
    assert run_int_to_float(hfp, [0x80]) == -128.0


def test_int_to_float_256(hfp):
    # 256 in two bytes: low=$00, high=$01, plus a $00 sign-extension byte to
    # keep MSB bit 7 clear (positive).
    assert run_int_to_float(hfp, [0x00, 0x01, 0x00]) == 256.0


def test_int_to_float_1000(hfp):
    # 1000 = 0x03E8, fits in 2 bytes (MSB bit 7 clear).
    assert run_int_to_float(hfp, [0xE8, 0x03]) == 1000.0


def test_int_to_float_neg_1000(hfp):
    # -1000 in 2 bytes: 0xFC18.
    assert run_int_to_float(hfp, [0x18, 0xFC]) == -1000.0


def test_int_to_float_32767(hfp):
    assert run_int_to_float(hfp, [0xFF, 0x7F]) == 32767.0


def test_int_to_float_65535(hfp):
    # 65535 as 3-byte positive: $FF, $FF, $00.
    assert run_int_to_float(hfp, [0xFF, 0xFF, 0x00]) == 65535.0


def test_int_to_float_million(hfp):
    # 1_000_000 = $0F4240 (3 bytes; MSB $0F has bit 7 clear → no extension).
    assert run_int_to_float(hfp, [0x40, 0x42, 0x0F]) == 1_000_000.0


# --- float_to_int ------------------------------------------------------------


def run_float_to_int(hfp, value: float) -> list[int]:
    rsp_initial = hfp.rsp
    f = place_python_float(hfp, 0x8900, value)
    hfp.rs_push(f)
    hfp.call("float_to_int")
    assert hfp.rsp == rsp_initial, "float_to_int violated stack discipline"
    handle = hfp.read_word(RV)
    assert hfp.mpu.memory[handle + H_TYPE] == TYPE_INT
    return read_int(hfp, handle)


def test_float_to_int_zero(hfp):
    assert run_float_to_int(hfp, 0.0) == [0x00]


def test_float_to_int_one(hfp):
    assert run_float_to_int(hfp, 1.0) == [0x01]


def test_float_to_int_neg_one(hfp):
    assert run_float_to_int(hfp, -1.0) == [0xFF]


def test_float_to_int_seven(hfp):
    assert run_float_to_int(hfp, 7.0) == [0x07]


def test_float_to_int_256(hfp):
    # 256 = $0100 little-endian 2 bytes.
    assert run_float_to_int(hfp, 256.0) == [0x00, 0x01]


def test_float_to_int_1000(hfp):
    assert run_float_to_int(hfp, 1000.0) == [0xE8, 0x03]


def test_float_to_int_truncates_positive(hfp):
    assert run_float_to_int(hfp, 1.7) == [0x01]


def _decode_signed_le(bs: list[int]) -> int:
    """Two's-complement signed integer from LE bytes."""
    if not bs:
        return 0
    n = 0
    for b in reversed(bs):
        n = (n << 8) | b
    if bs[-1] & 0x80:
        n -= 1 << (8 * len(bs))
    return n


def test_float_to_int_2_to_31(hfp):
    """2³¹ wraps to INT_MIN in fixed 32-bit (low 32 bits, signed)."""
    f = place_python_float(hfp, 0x8900, 2_147_483_648.0)
    hfp.rs_push(f)
    hfp.call("float_to_int")
    bs = read_int(hfp, hfp.read_word(RV))
    assert _decode_signed_le(bs) == -2_147_483_648


def test_float_to_int_neg_2_to_31(hfp):
    """-2³¹ = -2147483648 — fits exactly as 4-byte signed."""
    f = place_python_float(hfp, 0x8900, -2_147_483_648.0)
    hfp.rs_push(f)
    hfp.call("float_to_int")
    bs = read_int(hfp, hfp.read_word(RV))
    assert _decode_signed_le(bs) == -2_147_483_648


def test_float_to_int_2_to_32(hfp):
    """2³² wraps to 0 (low 32 bits are all zero)."""
    f = place_python_float(hfp, 0x8900, 4_294_967_296.0)
    hfp.rs_push(f)
    hfp.call("float_to_int")
    bs = read_int(hfp, hfp.read_word(RV))
    assert _decode_signed_le(bs) == 0


def test_float_to_int_neg_3_billion(hfp):
    """|x| > 2³¹ wraps mod 2³²: -3e9 → 1294967296."""
    f = place_python_float(hfp, 0x8900, -3_000_000_000.0)
    hfp.rs_push(f)
    hfp.call("float_to_int")
    bs = read_int(hfp, hfp.read_word(RV))
    assert _decode_signed_le(bs) == (-3_000_000_000) & 0xFFFFFFFF


def test_float_to_int_one_e_12(hfp):
    """1e12 wraps to its low 32 bits, interpreted signed."""
    f = place_python_float(hfp, 0x8900, 1e12)
    hfp.rs_push(f)
    hfp.call("float_to_int")
    bs = read_int(hfp, hfp.read_word(RV))
    expected = 1_000_000_000_000 & 0xFFFFFFFF
    if expected & 0x8000_0000:
        expected -= 0x1_0000_0000
    assert _decode_signed_le(bs) == expected


def test_float_to_int_just_below_overflow(hfp):
    """2³¹ - 1 — exact in MS-Basic format (within 32 mantissa bits)."""
    f = place_python_float(hfp, 0x8900, 2_147_483_647.0)
    hfp.rs_push(f)
    hfp.call("float_to_int")
    bs = read_int(hfp, hfp.read_word(RV))
    n = _decode_signed_le(bs)
    # MS-Basic's 32-bit mantissa represents 2³¹-1 exactly; result should match.
    assert n == 2_147_483_647, f"got {n}"


def test_float_to_int_truncates_negative(hfp):
    # QINT truncates toward negative infinity? or zero? BASIC's INT() function
    # truncates TOWARD NEGATIVE INFINITY (so int(-1.7) = -2). But QINT is the
    # "convert to integer for storage" routine — different. Let's measure.
    result = run_float_to_int(hfp, -1.7)
    # Accept either -1 (truncate toward zero) or -2 (toward neg infinity).
    # We document whichever it is.
    assert result in ([0xFF], [0xFE]), f"unexpected: {result}"


def test_float_to_int_round_trip_small(hfp):
    """int_to_float → float_to_int round-trips for small ints."""
    for v in [0, 1, -1, 7, -7, 100, -100, 1000, -1000, 32767, -32768]:
        # We need to feed an int payload; build one for v.
        if v == 0:
            payload = [0]
        elif v >= 0:
            n = v
            bs = []
            while n > 0:
                bs.append(n & 0xFF)
                n >>= 8
            if bs[-1] & 0x80:
                bs.append(0)  # sign-extension byte
            payload = bs
        else:
            # two's-complement little-endian for negative
            n = v & 0xFFFFFFFF
            bs = []
            for _ in range(4):
                bs.append(n & 0xFF)
                n >>= 8
            payload = bs
        # int → float
        rsp = hfp.rsp
        x = place_int(hfp, 0x8900, payload)
        hfp.rs_push(x)
        hfp.call("int_to_float")
        f_handle = hfp.read_word(RV)
        # float → int
        hfp.rs_push(f_handle)
        hfp.call("float_to_int")
        result_handle = hfp.read_word(RV)
        result_bytes = read_int(hfp, result_handle)
        # Decode result_bytes as signed two's-complement little-endian.
        if not result_bytes:
            decoded = 0
        else:
            n = 0
            for b in reversed(result_bytes):
                n = (n << 8) | b
            if result_bytes[-1] & 0x80:
                n -= 1 << (8 * len(result_bytes))
            decoded = n
        assert decoded == v, f"round-trip {v} → {decoded} (bytes {result_bytes})"
        # Reset
        hfp.call("rs_init")
        hfp.call("alloc_init")


# --- float_add / sub / mul / div ---------------------------------------------


def run_binop(hfp, op_label: str, left: float, right: float) -> float:
    rsp_initial = hfp.rsp
    a = place_python_float(hfp, 0x8900, left)
    b = place_python_float(hfp, 0x9100, right)
    hfp.rs_push(a)
    hfp.rs_push(b)
    hfp.call(op_label)
    assert hfp.rsp == rsp_initial, f"{op_label} violated stack discipline"
    handle = hfp.read_word(RV)
    assert hfp.mpu.memory[handle + H_TYPE] == TYPE_FLOAT
    return read_float_value(hfp, handle)


def test_add_one_plus_one(hfp):
    assert run_binop(hfp, "float_add", 1.0, 1.0) == 2.0


def test_add_zero_plus_zero(hfp):
    assert run_binop(hfp, "float_add", 0.0, 0.0) == 0.0


def test_add_one_plus_zero(hfp):
    assert run_binop(hfp, "float_add", 1.0, 0.0) == 1.0


def test_add_zero_plus_one(hfp):
    assert run_binop(hfp, "float_add", 0.0, 1.0) == 1.0


def test_add_neg_one_plus_one(hfp):
    assert run_binop(hfp, "float_add", -1.0, 1.0) == 0.0


def test_add_one_point_five_plus_two_point_five(hfp):
    assert run_binop(hfp, "float_add", 1.5, 2.5) == 4.0


def test_add_large(hfp):
    assert run_binop(hfp, "float_add", 1e6, 1e6) == pytest.approx(2e6)


def test_sub_one_minus_one(hfp):
    assert run_binop(hfp, "float_sub", 1.0, 1.0) == 0.0


def test_sub_ten_minus_four(hfp):
    assert run_binop(hfp, "float_sub", 10.0, 4.0) == 6.0


def test_sub_negative_result(hfp):
    assert run_binop(hfp, "float_sub", 1.0, 5.0) == -4.0


def test_sub_two_negatives(hfp):
    assert run_binop(hfp, "float_sub", -3.0, -2.0) == -1.0


def test_mul_six_times_seven(hfp):
    assert run_binop(hfp, "float_mul", 6.0, 7.0) == 42.0


def test_mul_by_zero(hfp):
    assert run_binop(hfp, "float_mul", 5.0, 0.0) == 0.0


def test_mul_zero_by(hfp):
    assert run_binop(hfp, "float_mul", 0.0, 5.0) == 0.0


def test_mul_negative(hfp):
    assert run_binop(hfp, "float_mul", -2.0, 3.0) == -6.0


def test_mul_two_negatives(hfp):
    assert run_binop(hfp, "float_mul", -2.0, -3.0) == 6.0


def test_mul_fractions(hfp):
    assert run_binop(hfp, "float_mul", 0.5, 0.5) == 0.25


def test_div_one_by_two(hfp):
    assert run_binop(hfp, "float_div", 1.0, 2.0) == 0.5


def test_div_one_by_four(hfp):
    assert run_binop(hfp, "float_div", 1.0, 4.0) == 0.25


def test_div_ten_by_four(hfp):
    assert run_binop(hfp, "float_div", 10.0, 4.0) == 2.5


def test_div_negative(hfp):
    assert run_binop(hfp, "float_div", -10.0, 4.0) == -2.5


def test_div_two_negatives(hfp):
    assert run_binop(hfp, "float_div", -10.0, -4.0) == 2.5


def test_div_by_zero_panics(hfp):
    rsp_initial = hfp.rsp
    a = place_python_float(hfp, 0x8900, 1.0)
    b = place_python_float(hfp, 0x9100, 0.0)
    hfp.rs_push(a)
    hfp.rs_push(b)
    hfp.call("float_div", expect_panic=True)
    from conftest import ERROR_CODE_ZP
    assert hfp.mpu.memory[ERROR_CODE_ZP] == 0x02  # ERR_DIV_ZERO
    del rsp_initial


def test_div_one_third_close(hfp):
    """1/3 produces a recurring decimal; verify it round-trips through Python."""
    result = run_binop(hfp, "float_div", 1.0, 3.0)
    assert result == pytest.approx(1.0 / 3.0, rel=1e-7)


# --- float_neg ---------------------------------------------------------------


def run_neg(hfp, value: float) -> float:
    rsp_initial = hfp.rsp
    f = place_python_float(hfp, 0x8900, value)
    hfp.rs_push(f)
    hfp.call("float_neg")
    assert hfp.rsp == rsp_initial
    handle = hfp.read_word(RV)
    return read_float_value(hfp, handle)


def test_neg_one(hfp):
    assert run_neg(hfp, 1.0) == -1.0


def test_neg_neg_one(hfp):
    assert run_neg(hfp, -1.0) == 1.0


def test_neg_zero(hfp):
    assert run_neg(hfp, 0.0) == 0.0


def test_neg_pi(hfp):
    assert run_neg(hfp, math.pi) == pytest.approx(-math.pi)


# --- float_cmp ---------------------------------------------------------------


def run_cmp(hfp, left: float, right: float) -> int:
    rsp_initial = hfp.rsp
    a = place_python_float(hfp, 0x8900, left)
    b = place_python_float(hfp, 0x9100, right)
    hfp.rs_push(a)
    hfp.rs_push(b)
    hfp.call("float_cmp")
    assert hfp.rsp == rsp_initial
    return hfp.mpu.a


def test_cmp_one_eq_one(hfp):
    assert run_cmp(hfp, 1.0, 1.0) == 0


def test_cmp_zero_eq_zero(hfp):
    assert run_cmp(hfp, 0.0, 0.0) == 0


def test_cmp_one_lt_two(hfp):
    assert run_cmp(hfp, 1.0, 2.0) == 0xFF


def test_cmp_two_gt_one(hfp):
    assert run_cmp(hfp, 2.0, 1.0) == 0x01


def test_cmp_neg_lt_pos(hfp):
    assert run_cmp(hfp, -1.0, 1.0) == 0xFF


def test_cmp_pos_gt_neg(hfp):
    assert run_cmp(hfp, 1.0, -1.0) == 0x01


def test_cmp_neg_one_eq_neg_one(hfp):
    assert run_cmp(hfp, -1.0, -1.0) == 0


def test_cmp_neg_two_lt_neg_one(hfp):
    assert run_cmp(hfp, -2.0, -1.0) == 0xFF


def test_cmp_close_values(hfp):
    """Bit-exact compare — two slightly different values are not equal."""
    a = place_python_float(hfp, 0x8900, 1.0)
    b = place_python_float(hfp, 0x9100, 1.0 + 1e-7)
    hfp.rs_push(a)
    hfp.rs_push(b)
    hfp.call("float_cmp")
    # Exact comparison; 1.0 < 1.0+1e-7 → $FF.
    assert hfp.mpu.a == 0xFF


# --- float_to_str ------------------------------------------------------------


def run_to_str(hfp, value: float) -> str:
    rsp_initial = hfp.rsp
    f = place_python_float(hfp, 0x8900, value)
    hfp.rs_push(f)
    hfp.call("float_to_str")
    assert hfp.rsp == rsp_initial
    from conftest import TYPE_STR
    handle = hfp.read_word(RV)
    assert hfp.mpu.memory[handle + H_TYPE] == TYPE_STR
    payload = read_str(hfp, handle)
    return "".join(chr(b) for b in payload)


def test_str_zero(hfp):
    assert run_to_str(hfp, 0.0) == "0"


def test_str_one(hfp):
    assert run_to_str(hfp, 1.0) == "1"


def test_str_neg_one(hfp):
    assert run_to_str(hfp, -1.0) == "-1"


def test_str_three_point_one_four(hfp):
    s = run_to_str(hfp, 3.14)
    # BASIC's FOUT renders 3.14 to ~9 significant digits. We know it'll
    # round-trip but the exact text depends on FP precision.
    assert s.startswith("3.14") or s.startswith("3.139")


def test_str_half(hfp):
    # BASIC renders 0.5 as ".5" (no leading zero).
    s = run_to_str(hfp, 0.5)
    assert s in (".5", "0.5")


def test_str_negative_half(hfp):
    s = run_to_str(hfp, -0.5)
    assert s in ("-.5", "-0.5")


def test_str_million(hfp):
    s = run_to_str(hfp, 1e6)
    # Could be "1000000" or "1E+06" depending on BASIC's threshold.
    assert s in ("1000000", "1E+06", " 1E+06")


# --- val_eq dispatch on TYPE_FLOAT -------------------------------------------


def run_val_eq(hfp, a: int, b: int) -> int:
    hfp.rs_push(a)
    hfp.rs_push(b)
    hfp.call("val_eq")
    return hfp.mpu.a


def test_val_eq_same_handle(hfp):
    f = place_python_float(hfp, 0x8900, 1.0)
    assert run_val_eq(hfp, f, f) == 1


def test_val_eq_distinct_handles_same_value(hfp):
    a = place_python_float(hfp, 0x8900, 1.0)
    b = place_python_float(hfp, 0x9100, 1.0)
    assert run_val_eq(hfp, a, b) == 1


def test_val_eq_different_values(hfp):
    a = place_python_float(hfp, 0x8900, 1.0)
    b = place_python_float(hfp, 0x9100, 2.0)
    assert run_val_eq(hfp, a, b) == 0


def test_val_eq_int_vs_float_no_promotion(hfp):
    """Cross-type INT vs FLOAT: not equal (no promotion in v1)."""
    i = place_int(hfp, 0x8900, [0x01])
    f = place_python_float(hfp, 0x9100, 1.0)
    assert run_val_eq(hfp, i, f) == 0


def test_val_eq_float_zero_vs_static(hfp):
    """A freshly-placed 0.0 byte-equals FLOAT_ZERO."""
    f = place_python_float(hfp, 0x8900, 0.0)
    fz = hfp.sym["FLOAT_ZERO"]
    assert run_val_eq(hfp, f, fz) == 1


# --- val_cmp dispatch on TYPE_FLOAT ------------------------------------------


def run_val_cmp(hfp, a: int, b: int) -> int:
    hfp.rs_push(a)
    hfp.rs_push(b)
    hfp.call("val_cmp")
    return hfp.mpu.a


def test_val_cmp_floats_lt(hfp):
    a = place_python_float(hfp, 0x8900, 1.0)
    b = place_python_float(hfp, 0x9100, 2.0)
    assert run_val_cmp(hfp, a, b) == 0xFF


def test_val_cmp_floats_gt(hfp):
    a = place_python_float(hfp, 0x8900, 2.0)
    b = place_python_float(hfp, 0x9100, 1.0)
    assert run_val_cmp(hfp, a, b) == 1


def test_val_cmp_floats_eq(hfp):
    a = place_python_float(hfp, 0x8900, 1.0)
    b = place_python_float(hfp, 0x9100, 1.0)
    assert run_val_cmp(hfp, a, b) == 0


def test_val_cmp_int_vs_float_orders_by_type_tag(hfp):
    """No cross-type promotion: TYPE_INT ($20) < TYPE_FLOAT ($27)."""
    i = place_int(hfp, 0x8900, [0x02])
    f = place_python_float(hfp, 0x9100, 1.0)
    # i is "less" because $20 < $27.
    assert run_val_cmp(hfp, i, f) == 0xFF
    assert run_val_cmp(hfp, f, i) == 0x01


# --- GC behavior on TYPE_FLOAT (leaf type) -----------------------------------


def test_gc_collects_unrooted_floats(hfp):
    """Allocate a bunch of unrooted floats; gc should reclaim everything."""
    from conftest import HEAP_DATA_START, NEXT_DATA_ZP

    initial_next_data = hfp.read_word(NEXT_DATA_ZP)
    for _ in range(20):
        hfp.call("float_alloc")
        # Don't root RV — leave as garbage.
    after_alloc = hfp.read_word(NEXT_DATA_ZP)
    assert after_alloc > initial_next_data, "float_alloc didn't bump heap"
    hfp.call("gc_collect")
    after_gc = hfp.read_word(NEXT_DATA_ZP)
    assert after_gc == HEAP_DATA_START, (
        f"gc didn't reclaim all unrooted floats: NEXT_DATA=${after_gc:04X}"
    )


def test_gc_preserves_rooted_floats(hfp):
    """Roots survive GC, with payload intact."""
    hfp.call("float_alloc")
    handle = hfp.read_word(RV)
    # Write a recognizable value (1.0) into payload.
    obj = hfp.read_word(handle + H_PTR)
    hfp.write_bytes(obj + O_HEADER, list(python_to_msbasic(1.0)))
    hfp.rs_push(handle)

    # Burn some unrooted floats.
    for _ in range(10):
        hfp.call("float_alloc")
    hfp.call("gc_collect")

    # Same handle must still hold 1.0.
    assert read_float_value(hfp, handle) == 1.0


# --- Statics -----------------------------------------------------------------


def test_float_zero_static_value(hfp):
    fz = hfp.sym["FLOAT_ZERO"]
    assert read_float_value(hfp, fz) == 0.0


def test_float_one_static_value(hfp):
    fo = hfp.sym["FLOAT_ONE"]
    assert read_float_value(hfp, fo) == 1.0


def test_float_zero_static_type(hfp):
    fz = hfp.sym["FLOAT_ZERO"]
    assert hfp.mpu.memory[fz + H_TYPE] == TYPE_FLOAT


def test_float_one_static_type(hfp):
    fo = hfp.sym["FLOAT_ONE"]
    assert hfp.mpu.memory[fo + H_TYPE] == TYPE_FLOAT


# --- Integration: ops chain through stack discipline -------------------------


def test_chained_ops(hfp):
    """(2 + 3) * (10 - 6) = 20"""
    rsp_initial = hfp.rsp
    a = place_python_float(hfp, 0x8900, 2.0)
    b = place_python_float(hfp, 0x9100, 3.0)
    hfp.rs_push(a)
    hfp.rs_push(b)
    hfp.call("float_add")
    sum1 = hfp.read_word(RV)
    assert hfp.rsp == rsp_initial

    c = place_python_float(hfp, 0x9200, 10.0)
    d = place_python_float(hfp, 0x9300, 6.0)
    hfp.rs_push(c)
    hfp.rs_push(d)
    hfp.call("float_sub")
    diff = hfp.read_word(RV)
    assert hfp.rsp == rsp_initial

    hfp.rs_push(sum1)
    hfp.rs_push(diff)
    hfp.call("float_mul")
    assert hfp.rsp == rsp_initial
    result = hfp.read_word(RV)
    assert read_float_value(hfp, result) == 20.0
