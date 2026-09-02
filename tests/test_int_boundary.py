"""Boundary + wraparound tests for fixed 32-bit signed integers.

Confirmed semantics (see PLANS/fixed-32-integers.md):
  - range: -2^31 .. 2^31-1, two's-complement
  - arithmetic (+ - * ** <<) wraps mod 2^32 (no overflow trap)
  - out-of-range literals wrap (0xFFFFFFFF -> -1)
  - only division by zero panics
All values are exercised through the interpreter via parser_eval.
"""

from __future__ import annotations

from test_parser import _eval

MAX = 2**31 - 1          # 2147483647
MIN = -(2**31)           # -2147483648


def test_max_int_literal(h):
    assert _eval(h, "2147483647") == MAX


def test_min_int_via_expr(h):
    # -2147483648 is parsed as negate(2147483648); 2147483648 wraps to MIN,
    # negating MIN wraps back to MIN.
    assert _eval(h, "0 - 2147483648") == MIN


def test_hex_all_ones_is_negative_one(h):
    assert _eval(h, "0xFFFFFFFF") == -1


def test_hex_high_bit_is_negative(h):
    assert _eval(h, "0x80000000") == MIN


def test_add_overflow_wraps(h):
    assert _eval(h, "2147483647 + 1") == MIN


def test_sub_overflow_wraps(h):
    assert _eval(h, "0 - 2147483648 - 1") == MAX


def test_mul_overflow_wraps(h):
    # 2147483647 * 2 = 4294967294 -> wraps to -2 (mod 2^32, signed).
    assert _eval(h, "2147483647 * 2") == -2


def test_shift_left_into_sign_bit(h):
    assert _eval(h, "1 << 31") == MIN


def test_shift_left_out_of_range_is_zero(h):
    assert _eval(h, "1 << 32") == 0


def test_arithmetic_shift_right_preserves_sign(h):
    # -2147483648 >> 1 = -1073741824 (sign-extending).
    assert _eval(h, "(0 - 2147483648) >> 1") == -1073741824


def test_negate_int_min_wraps_to_itself(h):
    assert _eval(h, "0 - (0 - 2147483648)") == MIN


def test_pow_overflow_wraps(h):
    # 2**31 wraps to MIN; 2**32 wraps to 0.
    assert _eval(h, "2 ** 31") == MIN
    assert _eval(h, "2 ** 32") == 0


def test_decimal_literal_out_of_range_wraps(h):
    # 4294967296 == 2^32 -> 0.
    assert _eval(h, "4294967296") == 0


def test_roundtrip_through_str_and_int(h):
    assert _eval(h, 'INT(STR(0 - 2147483648))') == MIN
    assert _eval(h, 'INT(STR(2147483647))') == MAX


def test_div_by_zero_still_panics(h):
    from conftest import ERROR_CODE_ZP
    from test_str import place_str
    handle = place_str(h, 0x8900, list(b"5 // 0"))
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)
    assert h.mpu.memory[ERROR_CODE_ZP] == 0x02  # ERR_DIV_ZERO
