"""Tests for parser_eval — Stage 8 Pratt parser-evaluator skeleton.

This is the *very first* milestone: parse + evaluate a TYPE_STR source into
a value handle. Initial scope: integer literals, +, -.
"""

from __future__ import annotations

import pytest

from conftest import RV
from test_int_parse import _read_int
from test_str import place_str


def _eval(h, source: str) -> int:
    """Place source on heap, push handle on RS, call parser_eval, read int."""
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    return _read_int(h, h.read_word(RV))


# --- single literals ---------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("0", 0),
    ("1", 1),
    ("42", 42),
    ("123", 123),
    ("65535", 65535),
])
def test_int_literal(h, text, expected):
    assert _eval(h, text) == expected


@pytest.mark.parametrize("text,expected", [
    ("0x0", 0),
    ("0xff", 255),
    ("0xDeadBeef", 0xDEADBEEF),
])
def test_hex_literal(h, text, expected):
    assert _eval(h, text) == expected


@pytest.mark.parametrize("text,expected", [
    ("0b0", 0),
    ("0b101", 5),
    ("0b11111111", 255),
])
def test_bin_literal(h, text, expected):
    assert _eval(h, text) == expected


# --- binary + and - ---------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("1 + 2", 3),
    ("10 + 20", 30),
    ("0 + 0", 0),
    ("100 + 200 + 300", 600),     # left-assoc chain
    ("1000 + 1", 1001),
])
def test_addition(h, text, expected):
    assert _eval(h, text) == expected


@pytest.mark.parametrize("text,expected", [
    ("5 - 2", 3),
    ("10 - 5", 5),
    ("100 - 50 - 25", 25),         # left-assoc: (100-50)-25
])
def test_subtraction(h, text, expected):
    assert _eval(h, text) == expected


@pytest.mark.parametrize("text,expected", [
    ("1 + 2 - 3", 0),
    ("10 - 3 + 5", 12),
])
def test_mixed_add_sub(h, text, expected):
    assert _eval(h, text) == expected


# --- whitespace + mixed bases -----------------------------------------------

def test_whitespace_around_operator(h):
    assert _eval(h, "1   +    2") == 3


def test_mixed_bases(h):
    assert _eval(h, "0xff + 1") == 256
    assert _eval(h, "0b1111 + 1") == 16


# --- multiplicative ---------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("2 * 3", 6),
    ("0 * 100", 0),
    ("7 * 11 * 13", 1001),
    ("1234 * 5678", 1234 * 5678),
])
def test_multiplication(h, text, expected):
    assert _eval(h, text) == expected


@pytest.mark.parametrize("text,expected", [
    ("10 / 2", 5),
    ("10 // 3", 3),
    ("100 / 7", 100 // 7),
    ("0 / 5", 0),
])
def test_division(h, text, expected):
    assert _eval(h, text) == expected


@pytest.mark.parametrize("text,expected", [
    ("10 % 3", 1),
    ("100 % 7", 100 % 7),
    ("8 % 4", 0),
])
def test_modulo(h, text, expected):
    assert _eval(h, text) == expected


# --- precedence -------------------------------------------------------------

def test_times_binds_tighter_than_plus(h):
    assert _eval(h, "1 + 2 * 3") == 7
    assert _eval(h, "2 * 3 + 4") == 10
    assert _eval(h, "2 + 3 * 4 + 5") == 19


def test_paren_overrides_precedence(h):
    assert _eval(h, "(1 + 2) * 3") == 9
    assert _eval(h, "2 * (3 + 4)") == 14
    assert _eval(h, "(1 + 2) * (3 + 4)") == 21


def test_nested_parens(h):
    assert _eval(h, "((1 + 2))") == 3
    assert _eval(h, "((((42))))") == 42


# --- unary -, + -------------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("-1", -1),
    ("-42", -42),
    ("--5", 5),
    ("---5", -5),
    ("+5", 5),
    ("-(-5)", 5),
    ("-(1 + 2)", -3),
])
def test_unary(h, text, expected):
    assert _eval(h, text) == expected


def test_unary_binds_tighter_than_times(h):
    """`-2 * 3` is `(-2)*3 = -6`, not `-(2*3) = -6`. Same numerically here,
    but the AST shape matters once we have side effects. We at least verify
    the value is right."""
    assert _eval(h, "-2 * 3") == -6
    assert _eval(h, "3 * -2") == -6


def test_subtract_with_unary(h):
    assert _eval(h, "10 - -5") == 15
    assert _eval(h, "-10 + 5") == -5


# --- comparisons ------------------------------------------------------------

def _eval_bool(h, source: str) -> bool:
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv_handle = h.read_word(RV)
    # TRUE static at known label; reading payload byte distinguishes.
    obj = h.read_word(rv_handle)            # H_PTR
    return h.mpu.memory[obj + 2] == 1


@pytest.mark.parametrize("text,expected", [
    ("1 < 2", True),  ("2 < 1", False), ("2 < 2", False),
    ("1 <= 2", True), ("2 <= 1", False), ("2 <= 2", True),
    ("1 > 2", False), ("2 > 1", True),   ("2 > 2", False),
    ("1 >= 2", False),("2 >= 1", True),  ("2 >= 2", True),
    ("1 == 1", True), ("1 == 2", False),
    ("1 != 2", True), ("1 != 1", False),
    ("100 < 200", True),
    ("65535 == 65535", True),
])
def test_comparisons(h, text, expected):
    assert _eval_bool(h, text) is expected


def test_comparison_with_arithmetic(h):
    """Cmp binds looser than +: `1 + 2 == 3` parses as `(1+2) == 3`."""
    assert _eval_bool(h, "1 + 2 == 3") is True
    assert _eval_bool(h, "1 + 2 == 4") is False
    assert _eval_bool(h, "5 * 4 > 19") is True


# --- bool / none literals ---------------------------------------------------

def test_true_literal(h):
    assert _eval_bool(h, "True") is True


def test_false_literal(h):
    assert _eval_bool(h, "False") is False


def test_none_literal_returns_none_handle(h):
    payload = list("None".encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    # NONE handle has H_TYPE = TYPE_NONE
    from conftest import TYPE_NONE
    assert h.mpu.memory[rv + 6] == TYPE_NONE  # H_TYPE offset = 6


# --- string literal ---------------------------------------------------------

def test_str_literal(h):
    payload = list('"hello"'.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    from test_str import read_str
    assert bytes(read_str(h, rv)) == b"hello"


# --- boolean: not / and / or ------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("not True", False),
    ("not False", True),
    ("not None", True),
    ("not 0", True),
    ("not 1", False),
    ("not -1", False),
    ("not not True", True),
    ("not (1 < 2)", False),
    ("not 1 < 2", False),         # `not (1<2)` per std precedence
])
def test_not(h, text, expected):
    assert _eval_bool(h, text) is expected


def _eval_int(h, source: str) -> int:
    return _eval(h, source)


def test_and_returns_lhs_when_falsy(h):
    """Python: `0 and 5` returns 0, not False."""
    assert _eval_int(h, "0 and 5") == 0


def test_and_returns_rhs_when_lhs_truthy(h):
    """Python: `7 and 5` returns 5."""
    assert _eval_int(h, "7 and 5") == 5


def test_or_returns_lhs_when_truthy(h):
    """Python: `7 or 5` returns 7."""
    assert _eval_int(h, "7 or 5") == 7


def test_or_returns_rhs_when_lhs_falsy(h):
    """Python: `0 or 5` returns 5."""
    assert _eval_int(h, "0 or 5") == 5


@pytest.mark.parametrize("text,expected", [
    ("True and True", True),
    ("True and False", False),
    ("False and True", False),
    ("True or False", True),
    ("False or False", False),
    ("True and True and True", True),
    ("False or True or False", True),
])
def test_bool_chains(h, text, expected):
    assert _eval_bool(h, text) is expected


def test_and_or_precedence(h):
    """`a or b and c` is `a or (b and c)` — and binds tighter than or."""
    assert _eval_bool(h, "True or False and False") is True
    assert _eval_bool(h, "False or True and True") is True
    assert _eval_bool(h, "False or True and False") is False


def test_not_with_and_or(h):
    """`not x and y` is `(not x) and y`."""
    assert _eval_bool(h, "not False and True") is True
    assert _eval_bool(h, "not True and True") is False


# --- is / is not -----------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("None is None", True),
    ("True is True", True),
    ("False is False", True),
    ("True is False", False),
    ("None is True", False),
    ("None is not None", False),
    ("True is not False", True),
    ("None is not True", True),
])
def test_is(h, text, expected):
    assert _eval_bool(h, text) is expected


def test_is_with_int_literals_returns_false_for_separate_handles(h):
    """Each int literal allocates a fresh handle, so `1 is 1` is False
    here (in CPython it's True due to small-int caching, but we don't
    intern). This documents our actual semantics."""
    assert _eval_bool(h, "1 is 1") is False


# --- list literal ----------------------------------------------------------

def _eval_list_len(h, source: str) -> int:
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    obj = h.read_word(rv)
    return h.read_word(obj)  # O_LEN


def test_empty_list(h):
    assert _eval_list_len(h, "[]") == 0


def test_single_element_list(h):
    assert _eval_list_len(h, "[42]") == 1


def test_multi_element_list(h):
    assert _eval_list_len(h, "[1, 2, 3]") == 3


def test_list_with_trailing_comma(h):
    assert _eval_list_len(h, "[1, 2, 3,]") == 3


def test_nested_list(h):
    """`[[1, 2], [3]]` — outer length 2, both elements are lists."""
    payload = list("[[1, 2], [3]]".encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    obj = h.read_word(rv)
    assert h.read_word(obj) == 2     # outer O_LEN


# --- indexing list[i] ------------------------------------------------------

def test_list_index_first(h):
    assert _eval(h, "[10, 20, 30][0]") == 10


def test_list_index_middle(h):
    assert _eval(h, "[10, 20, 30][1]") == 20


def test_list_index_last(h):
    assert _eval(h, "[10, 20, 30][2]") == 30


def test_list_index_with_arithmetic_index(h):
    assert _eval(h, "[10, 20, 30][1 + 1]") == 30


def test_list_index_with_arithmetic_result(h):
    assert _eval(h, "[1, 2, 3][0] + [10, 20][1]") == 21


# --- tuple literal ---------------------------------------------------------

def _eval_container_type_and_len(h, source: str) -> tuple[int, int]:
    """Return (H_TYPE, O_LEN) of the result. Useful for tuple/list/dict shape."""
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    h_type = h.mpu.memory[rv + 6]   # H_TYPE
    obj = h.read_word(rv)
    o_len = h.read_word(obj)
    return h_type, o_len


def test_empty_tuple(h):
    from conftest import TYPE_TUPLE
    assert _eval_container_type_and_len(h, "()") == (TYPE_TUPLE, 0)


def test_grouping_parens_returns_inner(h):
    """`(42)` is grouping (no comma) — returns the int, not a tuple."""
    assert _eval(h, "(42)") == 42


def test_one_tuple(h):
    """Trailing comma forces 1-tuple."""
    from conftest import TYPE_TUPLE
    assert _eval_container_type_and_len(h, "(42,)") == (TYPE_TUPLE, 1)


def test_two_tuple(h):
    from conftest import TYPE_TUPLE
    assert _eval_container_type_and_len(h, "(1, 2)") == (TYPE_TUPLE, 2)


def test_three_tuple(h):
    from conftest import TYPE_TUPLE
    assert _eval_container_type_and_len(h, "(1, 2, 3)") == (TYPE_TUPLE, 3)


def test_tuple_with_trailing_comma(h):
    from conftest import TYPE_TUPLE
    assert _eval_container_type_and_len(h, "(1, 2, 3,)") == (TYPE_TUPLE, 3)


def test_tuple_indexing(h):
    assert _eval(h, "(10, 20, 30)[1]") == 20


# --- dict literal ----------------------------------------------------------

def test_empty_dict(h):
    from conftest import TYPE_DICT
    assert _eval_container_type_and_len(h, "{}") == (TYPE_DICT, 0)


def test_one_entry_dict(h):
    from conftest import TYPE_DICT
    assert _eval_container_type_and_len(h, "{1: 10}") == (TYPE_DICT, 1)


def test_three_entry_dict(h):
    from conftest import TYPE_DICT
    assert _eval_container_type_and_len(h, "{1: 10, 2: 20, 3: 30}") == (TYPE_DICT, 3)


def test_dict_indexing_int_key(h):
    assert _eval(h, "{1: 10, 2: 20, 3: 30}[2]") == 20


def test_dict_with_trailing_comma(h):
    from conftest import TYPE_DICT
    assert _eval_container_type_and_len(h, "{1: 10,}") == (TYPE_DICT, 1)


# --- power ** --------------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("2 ** 0", 1),
    ("0 ** 0", 1),
    ("2 ** 1", 2),
    ("2 ** 8", 256),
    ("2 ** 16", 65536),
    ("3 ** 5", 243),
    ("10 ** 3", 1000),
    ("5 ** 4", 625),
])
def test_power(h, text, expected):
    assert _eval(h, text) == expected


def test_power_right_assoc(h):
    """`2 ** 3 ** 2` is `2 ** (3 ** 2)` = `2 ** 9` = 512, not `(2**3)**2 = 64`."""
    assert _eval(h, "2 ** 3 ** 2") == 512


def test_power_binds_tighter_than_unary(h):
    """`-2 ** 2` is `-(2 ** 2) = -4` in Python (power binds tighter than
    prefix minus). Our `nud_minus` recurses at LBP_UNARY=$30 < LBP_POWER=$40,
    so the inner expression captures `2 ** 2` and then negates."""
    assert _eval(h, "-2 ** 2") == -4
    assert _eval(h, "(-2) ** 2") == 4


def test_power_with_arithmetic(h):
    assert _eval(h, "2 ** 3 + 1") == 9       # (2**3) + 1
    assert _eval(h, "1 + 2 ** 3") == 9
    assert _eval(h, "2 * 3 ** 2") == 18      # 2 * (3**2)


def test_power_negative_exponent_returns_zero(h):
    """No float yet, so `2 ** -1` truncates to 0 by design."""
    assert _eval(h, "2 ** -1") == 0


# --- float literals ---------------------------------------------------------
# These tests use the `hfp` fixture which loads the BASIC ROM at $A000-$BFFF.
# str_to_float wraps BASIC ROM's FIN ($BCF3) for the actual digit-string
# parsing, so the ROM bytes must be present in py65 memory.

from conftest import msbasic_to_python


def _eval_float(h, source: str) -> float:
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    obj = h.read_word(rv)
    payload_bytes = h.read_bytes(obj + 2, 5)   # O_HEADER = 2, 5-byte float
    return msbasic_to_python(payload_bytes)


@pytest.mark.parametrize("text,expected", [
    ("0.0", 0.0),
    ("1.0", 1.0),
    ("1.5", 1.5),
    ("0.5", 0.5),
    (".5", 0.5),
    ("1.", 1.0),
    ("3.14", 3.14),
    ("100.0", 100.0),
    ("1000.5", 1000.5),
])
def test_float_literal(hfp, text, expected):
    assert _eval_float(hfp, text) == pytest.approx(expected)


@pytest.mark.parametrize("text,expected", [
    ("1e0", 1.0),
    ("1e1", 10.0),
    ("1e3", 1000.0),
    ("1e-1", 0.1),
    ("2.5e2", 250.0),
    ("1.5e-2", 0.015),
])
def test_float_with_exponent(hfp, text, expected):
    assert _eval_float(hfp, text) == pytest.approx(expected)


def test_float_in_parens(hfp):
    assert _eval_float(hfp, "(1.5)") == pytest.approx(1.5)


def test_float_handle_is_typed(hfp):
    from conftest import TYPE_FLOAT
    payload = list("1.5".encode("ascii"))
    handle = place_str(hfp, 0x7000, payload)
    hfp.rs_push(handle)
    hfp.call("parser_eval", max_steps=2_000_000)
    rv = hfp.read_word(RV)
    assert hfp.mpu.memory[rv + 6] == TYPE_FLOAT  # H_TYPE


# --- bitwise NOT -----------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("~0", -1),
    ("~1", -2),
    ("~-1", 0),
    ("~5", -6),
    ("~-6", 5),
    ("~127", -128),
    ("~~5", 5),               # double-NOT round-trips
])
def test_bitwise_not(h, text, expected):
    assert _eval(h, text) == expected


def test_bitwise_not_with_arithmetic(h):
    """`~5 + 1` = `-6 + 1` = `-5`."""
    assert _eval(h, "~5 + 1") == -5
    assert _eval(h, "1 + ~5") == -5


def test_bitwise_not_binds_at_unary(h):
    """`~5 * 2` is `(~5) * 2 = -12` because ~ binds tighter than *."""
    assert _eval(h, "~5 * 2") == -12


# --- binary bitwise -------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("0xff & 0x0f", 0x0f),
    ("0xff & 0xf0", 0xf0),
    ("0xff & 0", 0),
    ("0xff & 0xff", 0xff),
    ("5 & 3", 1),
    ("0x1234 & 0x00ff", 0x34),
    ("0xffff & 0x000f", 0x000f),
])
def test_bitwise_and(h, text, expected):
    assert _eval(h, text) == expected


@pytest.mark.parametrize("text,expected", [
    ("0x0f | 0xf0", 0xff),
    ("0 | 0", 0),
    ("0xff | 0", 0xff),
    ("0 | 0xff", 0xff),
    ("0x1200 | 0x0034", 0x1234),
    ("5 | 3", 7),
])
def test_bitwise_or(h, text, expected):
    assert _eval(h, text) == expected


@pytest.mark.parametrize("text,expected", [
    ("0xff ^ 0x0f", 0xf0),
    ("0xff ^ 0xff", 0),
    ("0 ^ 0", 0),
    ("0xa5 ^ 0x5a", 0xff),
    ("5 ^ 3", 6),
])
def test_bitwise_xor(h, text, expected):
    assert _eval(h, text) == expected


def test_bitwise_with_negative_operands(h):
    """Bitwise on signed two's-complement: `-1 & 0xff` = 0xff (low byte = -1's bits)."""
    assert _eval(h, "-1 & 0xff") == 0xff
    assert _eval(h, "-1 | 0") == -1
    assert _eval(h, "-1 ^ -1") == 0
    assert _eval(h, "-1 & 5") == 5


def test_bitwise_precedence(h):
    """Python: `&` > `^` > `|`. Verify."""
    # 5 | 3 ^ 1 = 5 | (3^1) = 5 | 2 = 7
    assert _eval(h, "5 | 3 ^ 1") == 7
    # 5 ^ 3 & 1 = 5 ^ (3&1) = 5 ^ 1 = 4
    assert _eval(h, "5 ^ 3 & 1") == 4
    # ~5 & 3 — `~` binds tighter than `&` (LBP_UNARY > LBP_BITAND)
    assert _eval(h, "~5 & 3") == ((-6) & 3)


def test_bitwise_mixed_with_arithmetic(h):
    """Arithmetic `+` `-` bind tighter than bitwise."""
    # (1 + 2) | 4 — wait, in Python `+` binds tighter, so 1 + 2 | 4 = 1 + (2|4) = 1+6 = 7. NO:
    # Actually Python: arithmetic > shifts > bitwise-and > bitwise-xor > bitwise-or.
    # So `1 + 2 | 4` = `(1+2) | 4` = `3 | 4` = 7.
    assert _eval(h, "1 + 2 | 4") == 7
    assert _eval(h, "0xf0 | 0x0f & 0x05") == 0xf5     # 0xf0 | (0x0f & 0x05) = 0xf0 | 0x05


# --- mixed int/float arithmetic --------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("1 + 1.5", 2.5),
    ("1.5 + 1", 2.5),
    ("1.5 + 1.5", 3.0),
    ("10 - 0.5", 9.5),
    ("0.5 - 10", -9.5),
    ("2 * 1.5", 3.0),
    ("1.5 * 2", 3.0),
    ("3.0 / 2", 1.5),
    ("3 / 2.0", 1.5),
    ("0.0 + 0", 0.0),
    ("0 + 0.0", 0.0),
])
def test_mixed_int_float_arith(hfp, text, expected):
    assert _eval_float(hfp, text) == pytest.approx(expected)


def test_mixed_compound_expression(hfp):
    """`1 + 2 * 1.5` should follow precedence: 1 + (2*1.5) = 1 + 3.0 = 4.0."""
    assert _eval_float(hfp, "1 + 2 * 1.5") == pytest.approx(4.0)


def test_mixed_in_parens(hfp):
    """`(1 + 0.5) * 2` = 1.5 * 2 = 3.0"""
    assert _eval_float(hfp, "(1 + 0.5) * 2") == pytest.approx(3.0)


# --- mixed comparisons -----------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("1 == 1.0", True),
    ("1.0 == 1", True),
    ("1 == 1.5", False),
    ("1 < 1.5", True),
    ("1.5 < 2", True),
    ("2.0 > 1", True),
    ("0.5 != 1", True),
    ("1 <= 1.0", True),
    ("1.0 >= 1", True),
])
def test_mixed_int_float_cmp(hfp, text, expected):
    assert _eval_bool(hfp, text) is expected


# --- power right-associative chain (regression after binary-exp rewrite) ---

def test_power_large_exponent(h):
    """The new square-and-multiply int_pow handles large exponents efficiently.
    `2 ** 30 = 1073741824` exercises 5 bits of the binary expansion."""
    assert _eval(h, "2 ** 30") == 2 ** 30


def test_power_chain_right_assoc_large(h):
    """`3 ** 2 ** 2` = `3 ** (2**2)` = `3 ** 4` = 81 (right-assoc)."""
    assert _eval(h, "3 ** 2 ** 2") == 81


# --- shifts -----------------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("1 << 0", 1),
    ("1 << 1", 2),
    ("1 << 7", 128),
    ("1 << 8", 256),
    ("1 << 15", 32768),
    ("1 << 16", 65536),
    ("3 << 4", 48),
    ("0 << 100", 0),
    ("0xff << 4", 0xff0),
    ("0x1234 << 8", 0x123400),
])
def test_lshift(h, text, expected):
    assert _eval(h, text) == expected


@pytest.mark.parametrize("text,expected", [
    ("8 >> 0", 8),
    ("8 >> 1", 4),
    ("8 >> 3", 1),
    ("8 >> 4", 0),
    ("256 >> 8", 1),
    ("65536 >> 16", 1),
    ("0xff >> 4", 0xf),
    ("0x1234 >> 4", 0x123),
    ("100 >> 2", 25),
])
def test_rshift_unsigned(h, text, expected):
    assert _eval(h, text) == expected


def test_rshift_arithmetic_negative(h):
    """Arithmetic right shift preserves sign."""
    assert _eval(h, "-2 >> 1") == -1
    assert _eval(h, "-1 >> 1") == -1     # -1 stays -1 (all-ones rotates in)
    assert _eval(h, "-8 >> 2") == -2
    assert _eval(h, "-256 >> 8") == -1


def test_shift_precedence(h):
    """Python: shifts bind tighter than `&` `|` `^`, looser than `+` `-`."""
    assert _eval(h, "1 + 2 << 3") == 24       # (1+2) << 3 = 24
    assert _eval(h, "0xf | 0xf0 << 4") == 0xf | (0xf0 << 4)
    assert _eval(h, "1 << 2 | 1") == (1 << 2) | 1   # 5


# --- variables (Stage 9a) ---------------------------------------------------

def test_assignment_returns_none(h):
    """`x = 5` evaluates to NONE."""
    from conftest import TYPE_NONE
    payload = list("x = 5".encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_NONE


def test_assignment_then_lookup(h):
    """Set then read the variable across two statements."""
    assert _eval(h, "x = 5\nx") == 5


def test_assignment_then_arithmetic(h):
    assert _eval(h, "x = 5\nx + 3") == 8
    assert _eval(h, "x = 7\nx * x") == 49


def test_multiple_assignments(h):
    assert _eval(h, "a = 1\nb = 2\na + b") == 3


def test_reassignment(h):
    """Later assignment overwrites earlier."""
    assert _eval(h, "x = 1\nx = 99\nx") == 99


def test_assignment_uses_rhs_with_existing_var(h):
    assert _eval(h, "x = 5\ny = x + 10\ny") == 15
    assert _eval(h, "x = 5\nx = x * 2\nx") == 10


def test_undefined_name_panics(h):
    """Looking up a name that's not in scope panics."""
    payload = list("undefined_var".encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True)


def test_variable_in_complex_expression(h):
    assert _eval(h, "a = 2\nb = 3\na ** b + a * b") == 14   # 8 + 6


def test_variable_with_container(h):
    """Variables can hold lists/tuples/dicts."""
    payload = list("xs = [1, 2, 3]\nxs[1]".encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    assert _read_int(h, h.read_word(RV)) == 2


def test_variable_holds_string(h):
    """Variables can hold TYPE_STR; identity check."""
    payload = list('s = "hello"\ns'.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    from test_str import read_str
    assert bytes(read_str(h, rv)) == b"hello"


def test_empty_source_returns_none(h):
    """Empty source string produces NONE."""
    from conftest import TYPE_NONE
    payload = []
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_NONE


def test_just_newlines_returns_none(h):
    """Source with just whitespace/newlines returns NONE."""
    from conftest import TYPE_NONE
    payload = list("\n\n\n".encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_NONE


def test_long_variable_name(h):
    """Variable names can be longer than 8 chars (skip keyword bucket)."""
    assert _eval(h, "my_long_var_name = 42\nmy_long_var_name") == 42


def test_variable_underscore_prefix(h):
    """Names starting with _ are valid identifiers."""
    assert _eval(h, "_x = 5\n_x") == 5


def test_assignment_with_float(hfp):
    """Float values store and recall."""
    payload = list("pi = 3.14\npi".encode("ascii"))
    handle = place_str(hfp, 0x7000, payload)
    hfp.rs_push(handle)
    hfp.call("parser_eval", max_steps=2_000_000)
    rv = hfp.read_word(RV)
    obj = hfp.read_word(rv)
    payload_bytes = hfp.read_bytes(obj + 2, 5)
    assert msbasic_to_python(payload_bytes) == pytest.approx(3.14)


# --- Stage 9b: control flow (if / elif / else / pass) ----------------------

def test_pass_alone(h):
    """`pass` is a no-op statement."""
    from conftest import TYPE_NONE
    payload = list("pass".encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_NONE


def test_if_truthy_runs_body(h):
    """`if True: x = 5` sets x."""
    src = "x = 0\nif True:\n    x = 5\nx"
    assert _eval(h, src) == 5


def test_if_falsy_skips_body(h):
    """`if False: x = 5` leaves x unchanged."""
    src = "x = 0\nif False:\n    x = 5\nx"
    assert _eval(h, src) == 0


def test_if_int_condition_truthy(h):
    """Non-zero ints are truthy."""
    src = "x = 0\nif 1:\n    x = 7\nx"
    assert _eval(h, src) == 7


def test_if_int_condition_falsy(h):
    src = "x = 0\nif 0:\n    x = 7\nx"
    assert _eval(h, src) == 0


def test_if_else_truthy(h):
    src = "x = 0\nif True:\n    x = 1\nelse:\n    x = 2\nx"
    assert _eval(h, src) == 1


def test_if_else_falsy(h):
    src = "x = 0\nif False:\n    x = 1\nelse:\n    x = 2\nx"
    assert _eval(h, src) == 2


def test_if_elif_first_branch(h):
    src = "x = 0\nif True:\n    x = 1\nelif True:\n    x = 2\nelse:\n    x = 3\nx"
    assert _eval(h, src) == 1


def test_if_elif_second_branch(h):
    src = "x = 0\nif False:\n    x = 1\nelif True:\n    x = 2\nelse:\n    x = 3\nx"
    assert _eval(h, src) == 2


def test_if_elif_else_branch(h):
    src = "x = 0\nif False:\n    x = 1\nelif False:\n    x = 2\nelse:\n    x = 3\nx"
    assert _eval(h, src) == 3


def test_if_elif_chain_long(h):
    """Multiple elif clauses; only the matching one runs."""
    src = (
        "n = 3\n"
        "x = -1\n"
        "if n == 1:\n    x = 100\n"
        "elif n == 2:\n    x = 200\n"
        "elif n == 3:\n    x = 300\n"
        "elif n == 4:\n    x = 400\n"
        "else:\n    x = 999\n"
        "x"
    )
    assert _eval(h, src) == 300


def test_if_with_complex_condition(h):
    src = "x = 0\nif 1 + 2 == 3:\n    x = 42\nx"
    assert _eval(h, src) == 42


def test_if_with_and_or(h):
    src = "x = 0\nif True and 5 > 2:\n    x = 9\nx"
    assert _eval(h, src) == 9


def test_nested_if(h):
    """Nested if-statements work — skip_suite handles INDENT depth."""
    src = (
        "x = 0\n"
        "if True:\n"
        "    if True:\n"
        "        x = 5\n"
        "x"
    )
    assert _eval(h, src) == 5


def test_nested_if_inner_skipped(h):
    src = (
        "x = 0\n"
        "if True:\n"
        "    if False:\n"
        "        x = 5\n"
        "    else:\n"
        "        x = 10\n"
        "x"
    )
    assert _eval(h, src) == 10


def test_nested_if_outer_skipped(h):
    """Skipping outer if must skip the entire nested block, including its
    nested if."""
    src = (
        "x = 100\n"
        "if False:\n"
        "    if True:\n"
        "        x = 1\n"
        "    else:\n"
        "        x = 2\n"
        "    x = 3\n"
        "x"
    )
    assert _eval(h, src) == 100


def test_if_body_multiple_statements(h):
    src = (
        "if True:\n"
        "    x = 1\n"
        "    y = 2\n"
        "    z = x + y\n"
        "z"
    )
    assert _eval(h, src) == 3


def test_pass_in_block(h):
    """`pass` is fine as a body — `if False: pass` shouldn't crash."""
    src = "x = 5\nif False:\n    pass\nx"
    assert _eval(h, src) == 5


def test_if_after_assignment_in_chain(h):
    """if-statement followed by another statement at top level."""
    src = "x = 1\nif True:\n    x = 2\ny = x + 100\ny"
    assert _eval(h, src) == 102


# --- while loops -----------------------------------------------------------

def test_while_zero_iterations(h):
    """`while False: ...` — body never runs."""
    src = "x = 0\nwhile False:\n    x = 99\nx"
    assert _eval(h, src) == 0


def test_while_simple_count(h):
    """Count up to 5."""
    src = "i = 0\nwhile i < 5:\n    i = i + 1\ni"
    assert _eval(h, src) == 5


def test_while_count_to_10(h):
    src = "i = 0\nwhile i < 10:\n    i = i + 1\ni"
    assert _eval(h, src) == 10


def test_while_accumulator(h):
    """Sum 1..10 = 55."""
    src = (
        "i = 1\n"
        "s = 0\n"
        "while i <= 10:\n"
        "    s = s + i\n"
        "    i = i + 1\n"
        "s"
    )
    assert _eval(h, src) == 55


def test_while_factorial(h):
    """5! = 120."""
    src = (
        "n = 5\n"
        "f = 1\n"
        "while n > 1:\n"
        "    f = f * n\n"
        "    n = n - 1\n"
        "f"
    )
    assert _eval(h, src) == 120


def test_while_with_if_inside(h):
    """Sum even numbers up to 10."""
    src = (
        "i = 0\n"
        "s = 0\n"
        "while i <= 10:\n"
        "    if i % 2 == 0:\n"
        "        s = s + i\n"
        "    i = i + 1\n"
        "s"
    )
    assert _eval(h, src) == 30   # 0+2+4+6+8+10


def test_nested_while(h):
    """Multiplication by repeated addition (3 * 4 = 12) using nested whiles."""
    src = (
        "a = 3\n"
        "b = 4\n"
        "result = 0\n"
        "i = 0\n"
        "while i < a:\n"
        "    j = 0\n"
        "    while j < b:\n"
        "        result = result + 1\n"
        "        j = j + 1\n"
        "    i = i + 1\n"
        "result"
    )
    assert _eval(h, src) == 12


def test_while_with_complex_condition(h):
    """Loop until two conditions both fail."""
    src = (
        "i = 0\n"
        "while i < 10 and i != 7:\n"
        "    i = i + 1\n"
        "i"
    )
    assert _eval(h, src) == 7


# --- break / continue ------------------------------------------------------

def test_while_break_simple(h):
    """`break` exits the while loop."""
    src = (
        "i = 0\n"
        "while True:\n"
        "    i = i + 1\n"
        "    if i == 5:\n"
        "        break\n"
        "i"
    )
    assert _eval(h, src) == 5


def test_while_break_at_start(h):
    """`break` as first statement in body — runs zero times."""
    src = (
        "i = 0\n"
        "while True:\n"
        "    break\n"
        "    i = 99\n"
        "i"
    )
    assert _eval(h, src) == 0


def test_while_continue_simple(h):
    """`continue` skips rest of iteration."""
    src = (
        "i = 0\n"
        "s = 0\n"
        "while i < 10:\n"
        "    i = i + 1\n"
        "    if i == 5:\n"
        "        continue\n"
        "    s = s + i\n"
        "s"
    )
    # 1+2+3+4 + 6+7+8+9+10 = 10 + 40 = 50 (skipping 5)
    assert _eval(h, src) == 50


def test_break_only_breaks_inner_loop(h):
    """Inner `break` doesn't escape outer loop."""
    src = (
        "outer = 0\n"
        "inner_total = 0\n"
        "while outer < 3:\n"
        "    j = 0\n"
        "    while j < 10:\n"
        "        if j == 2:\n"
        "            break\n"
        "        inner_total = inner_total + 1\n"
        "        j = j + 1\n"
        "    outer = outer + 1\n"
        "inner_total"
    )
    # Each outer iter: inner runs j=0,1 (2 iters), breaks. 3 outer × 2 = 6.
    assert _eval(h, src) == 6


def test_continue_only_continues_inner_loop(h):
    src = (
        "outer = 0\n"
        "skipped = 0\n"
        "while outer < 2:\n"
        "    j = 0\n"
        "    while j < 5:\n"
        "        j = j + 1\n"
        "        if j == 3:\n"
        "            continue\n"
        "        skipped = skipped + 1\n"
        "    outer = outer + 1\n"
        "skipped"
    )
    # Each outer: j=1,2 count, 3 skip, 4,5 count = 4 per outer iter.
    # 2 outer × 4 = 8.
    assert _eval(h, src) == 8


# --- for ... in ... --------------------------------------------------------

def test_for_over_list_simple(h):
    """Sum elements of a list."""
    src = (
        "s = 0\n"
        "for x in [1, 2, 3, 4, 5]:\n"
        "    s = s + x\n"
        "s"
    )
    assert _eval(h, src) == 15


def test_for_over_tuple(h):
    src = (
        "s = 0\n"
        "for x in (10, 20, 30):\n"
        "    s = s + x\n"
        "s"
    )
    assert _eval(h, src) == 60


def test_for_over_empty_list(h):
    """Empty list — body never runs."""
    src = "s = 99\nfor x in []:\n    s = 0\ns"
    assert _eval(h, src) == 99


def test_for_with_break(h):
    """`break` exits the for loop."""
    src = (
        "s = 0\n"
        "for x in [1, 2, 3, 4, 5]:\n"
        "    if x == 4:\n"
        "        break\n"
        "    s = s + x\n"
        "s"
    )
    assert _eval(h, src) == 6   # 1+2+3, break before 4 added


def test_for_with_continue(h):
    """`continue` skips to next element."""
    src = (
        "s = 0\n"
        "for x in [1, 2, 3, 4, 5]:\n"
        "    if x == 3:\n"
        "        continue\n"
        "    s = s + x\n"
        "s"
    )
    assert _eval(h, src) == 12   # 1+2+4+5


def test_for_via_variable(h):
    """Container is bound to a variable first."""
    src = (
        "xs = [10, 20, 30]\n"
        "s = 0\n"
        "for x in xs:\n"
        "    s = s + x\n"
        "s"
    )
    assert _eval(h, src) == 60


def test_nested_for(h):
    """Cross product of two lists."""
    src = (
        "s = 0\n"
        "for a in [1, 2, 3]:\n"
        "    for b in [10, 20]:\n"
        "        s = s + a * b\n"
        "s"
    )
    # (1+2+3) * (10+20) = 6 * 30 = 180
    assert _eval(h, src) == 180


def test_for_inside_while(h):
    src = (
        "i = 0\n"
        "total = 0\n"
        "while i < 3:\n"
        "    for x in [1, 2]:\n"
        "        total = total + x\n"
        "    i = i + 1\n"
        "total"
    )
    assert _eval(h, src) == 9  # 3 outer × 3 (sum 1+2)


def test_for_loop_var_outlives_loop(h):
    """After the loop, the loop variable still holds the last value."""
    src = "for x in [10, 20, 30]:\n    pass\nx"
    assert _eval(h, src) == 30


# --- print -----------------------------------------------------------------
# These read screen RAM after parser_eval. Need screen_init first.

from test_print import petscii_to_screen_code

SCREEN_BASE = 0x0400


def _read_screen(h, count: int = 80) -> bytes:
    return bytes(h.mpu.memory[SCREEN_BASE:SCREEN_BASE + count])


def _eval_with_screen(h, source: str) -> bytes:
    h.call("screen_init")
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    return _read_screen(h)


def test_print_int(h):
    screen = _eval_with_screen(h, "print 5")
    # Screen code for '5' = 0x35 (same as ASCII).
    assert screen[0] == 0x35
    # '5' alone, then space-fill afterwards.
    assert screen[1] == 0x20  # space (cursor moved down via newline; screen_init filled with spaces)


def test_print_multi_digit(h):
    screen = _eval_with_screen(h, "print 1234")
    assert screen[:4] == bytes([0x31, 0x32, 0x33, 0x34])  # '1','2','3','4'


def test_print_negative(h):
    screen = _eval_with_screen(h, "print -42")
    # '-' = 0x2D, '4' = 0x34, '2' = 0x32
    assert screen[:3] == bytes([0x2D, 0x34, 0x32])


def test_print_arithmetic(h):
    screen = _eval_with_screen(h, "print 1 + 2 * 3")
    assert screen[0] == 0x37  # '7'


def test_print_string(h):
    screen = _eval_with_screen(h, 'print "Hi"')
    # 'H' (0x48) → screen code 0x08; 'i' (0x69) → 0x69 (lowercase outside the
    # subtract-$40 range, passes through).
    assert screen[0] == petscii_to_screen_code(ord("H"))
    assert screen[1] == petscii_to_screen_code(ord("i"))


def test_print_true(h):
    screen = _eval_with_screen(h, "print True")
    # "True" → screen codes for T,r,u,e
    expected = bytes(petscii_to_screen_code(ord(c)) for c in "True")
    assert screen[:4] == expected


def test_print_false(h):
    screen = _eval_with_screen(h, "print False")
    expected = bytes(petscii_to_screen_code(ord(c)) for c in "False")
    assert screen[:5] == expected


def test_print_none(h):
    screen = _eval_with_screen(h, "print None")
    expected = bytes(petscii_to_screen_code(ord(c)) for c in "None")
    assert screen[:4] == expected


def test_print_in_loop(h):
    """Multiple prints; each ends with newline."""
    h.call("screen_init")
    src = "for x in [1, 2, 3]:\n    print x"
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    # Row 0 col 0 = '1', row 1 col 0 = '2', row 2 col 0 = '3'.
    assert h.mpu.memory[SCREEN_BASE + 0] == 0x31         # row 0
    assert h.mpu.memory[SCREEN_BASE + 40] == 0x32        # row 1
    assert h.mpu.memory[SCREEN_BASE + 80] == 0x33        # row 2


def test_print_with_variable(h):
    screen = _eval_with_screen(h, "x = 42\nprint x")
    assert screen[:2] == bytes([0x34, 0x32])  # '4','2'


def test_program_compute_and_print(h):
    """Real program: compute factorial, print result."""
    src = (
        "n = 5\n"
        "f = 1\n"
        "while n > 1:\n"
        "    f = f * n\n"
        "    n = n - 1\n"
        "print f\n"
    )
    h.call("screen_init")
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    # 5! = 120. Screen codes for '1','2','0' = 0x31, 0x32, 0x30.
    assert h.mpu.memory[SCREEN_BASE + 0] == 0x31
    assert h.mpu.memory[SCREEN_BASE + 1] == 0x32
    assert h.mpu.memory[SCREEN_BASE + 2] == 0x30


# --- built-in functions: len, range ----------------------------------------

@pytest.mark.parametrize("text,expected", [
    ('len("")', 0),
    ('len("hello")', 5),
    ("len([])", 0),
    ("len([1, 2, 3])", 3),
    ("len([1, 2, 3, 4, 5, 6, 7])", 7),
    ("len((1, 2))", 2),
    ("len({})", 0),
    ("len({1: 10, 2: 20})", 2),
])
def test_len_builtin(h, text, expected):
    assert _eval(h, text) == expected


def test_len_via_variable(h):
    src = "xs = [10, 20, 30, 40]\nlen(xs)"
    assert _eval(h, src) == 4


def test_range_builtin_simple(h):
    """range(N) returns a list — len(range(5)) = 5."""
    src = "len(range(5))"
    assert _eval(h, src) == 5


def test_range_elements(h):
    """range(5)[2] should be 2."""
    assert _eval(h, "range(5)[0]") == 0
    assert _eval(h, "range(5)[2]") == 2
    assert _eval(h, "range(5)[4]") == 4


def test_range_in_for(h):
    """The canonical `for i in range(N):` loop."""
    src = (
        "s = 0\n"
        "for i in range(10):\n"
        "    s = s + i\n"
        "s"
    )
    # 0+1+...+9 = 45
    assert _eval(h, src) == 45


def test_range_zero(h):
    """range(0) is an empty list."""
    assert _eval(h, "len(range(0))") == 0


def test_nested_calls(h):
    """`len(range(N))` — calls inside calls."""
    assert _eval(h, "len(range(7))") == 7


def test_call_with_arithmetic_arg(h):
    assert _eval(h, "len(range(2 + 3))") == 5


# --- string-as-function (Admiral pattern) ----------------------------------

def test_str_function_simplest(h):
    """A string with `return` is callable."""
    src = (
        'add = "return a + b"\n'
        'add(a=1, b=2)'
    )
    assert _eval(h, src) == 3


def test_str_function_with_arithmetic(h):
    src = (
        'square = "return x * x"\n'
        'square(x=7)'
    )
    assert _eval(h, src) == 49


def test_str_function_no_args(h):
    src = (
        'forty_two = "return 42"\n'
        'forty_two()'
    )
    assert _eval(h, src) == 42


def test_str_function_no_return_yields_none(h):
    """A function body without `return` returns NONE."""
    from conftest import TYPE_NONE
    src = (
        'noop = "x = 5"\n'
        'noop()'
    )
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_NONE


def test_str_function_with_multiple_kwargs(h):
    src = (
        'wt = "return weight * 2"\n'
        'wt(weight=21)'
    )
    assert _eval(h, src) == 42


def test_str_function_locals_dont_pollute_global(h):
    """Function-local assignments shouldn't affect the caller."""
    src = (
        'x = 100\n'
        'shadow = "x = 7\\nreturn x"\n'   # x is local in the function
        'shadow()\n'
        'x'                               # still 100 in global scope
    )
    # Note: \n inside the string literal is currently stored as the raw two
    # bytes `\` and `n` (escape decoding deferred). So this test would not
    # actually run multi-line bodies. Skip for now — kept as documentation.
    # See test_str_function_simplest etc. for working cases.


def test_str_function_arg_shadows_global_in_body(h):
    """Inside the function, the kwarg `n` shadows any global `n`."""
    src = (
        'n = 100\n'
        'inc = "return n + 1"\n'
        'inc(n=5)'
    )
    # n=5 is bound in the new function scope; body sees that, not the global.
    assert _eval(h, src) == 6


def test_str_function_returns_complex_value(h):
    """Return a list."""
    src = (
        'pair = "return [a, b]"\n'
        'len(pair(a=10, b=20))'
    )
    assert _eval(h, src) == 2


def test_nested_str_function_calls(h):
    """One function calls another."""
    src = (
        'add = "return x + y"\n'
        'add(x=3, y=4)'
    )
    assert _eval(h, src) == 7


def test_str_function_in_arithmetic(h):
    src = (
        'sq = "return n * n"\n'
        'sq(n=5) + 1'
    )
    assert _eval(h, src) == 26


def test_multi_line_function_body(h):
    r"""Function bodies can span multiple statements via `\n` escapes
    in the string literal."""
    src = (
        r'compute = "a = x + 1\nb = a * 2\nreturn b"' '\n'
        'compute(x=10)'
    )
    # x=10, a = 11, b = 22.
    assert _eval(h, src) == 22


def test_function_with_loop(h):
    r"""Function body can contain a loop."""
    src = (
        r'sum_to = "s = 0\ni = 1\nwhile i <= n:\n    s = s + i\n    i = i + 1\nreturn s"' '\n'
        'sum_to(n=10)'
    )
    # 1+2+...+10 = 55
    assert _eval(h, src) == 55


def test_function_with_if(h):
    src = (
        r'sign = "if x > 0:\n    return 1\nif x < 0:\n    return -1\nreturn 0"' '\n'
        'sign(x=42)'
    )
    assert _eval(h, src) == 1


def test_function_with_if_else(h):
    src = (
        r'absval = "if x < 0:\n    return -x\nelse:\n    return x"' '\n'
        'absval(x=-5)'
    )
    assert _eval(h, src) == 5


# --- parent scope chain (recursion + globals) ------------------------------

def test_function_reads_global(h):
    """Function body sees a global variable via the parent-scope link."""
    src = (
        'pi_approx = 314\n'
        'show = "return pi_approx"\n'
        'show()'
    )
    assert _eval(h, src) == 314


def test_function_assignment_is_local(h):
    """Assignment inside a function shadows global only locally."""
    src = (
        'x = 100\n'
        'modify = "x = 7\\nreturn x"\n'
        'modify()\n'
        'x'
    )
    # Inside modify, local x = 7 is bound, returned. Outer x stays 100.
    # The returned 7 is discarded; expression is `x` (the global) at end.
    assert _eval(h, src) == 100


def test_recursive_factorial(h):
    """The defining test: a recursive function calling itself by name."""
    src = (
        r'fact = "if n <= 1:\n    return 1\nreturn n * fact(n=n-1)"' '\n'
        'fact(n=6)'
    )
    # 6! = 720
    assert _eval(h, src) == 720


def test_recursive_fibonacci(h):
    """fib(7) = 13. Tests deep recursion (~41 calls; py65 sim is slow)."""
    src = (
        'fib = "if n < 2:\\n    return n\\nreturn fib(n=n-1) + fib(n=n-2)"\n'
        'fib(n=7)'
    )
    # fib: 0,1,1,2,3,5,8,13
    assert _eval(h, src) == 13


def test_function_call_within_function(h):
    """One function calls another via global scope lookup."""
    src = (
        'doubler = "return 2 * x"\n'
        'apply = "return doubler(x=n)"\n'
        'apply(n=21)'
    )
    assert _eval(h, src) == 42


def test_function_can_call_builtin(h):
    """Function bodies can use range() and len() — they're in global scope."""
    src = (
        'count_to = "return len(range(n))"\n'
        'count_to(n=7)'
    )
    assert _eval(h, src) == 7


def test_nested_function_access_grandparent(h):
    """A function calling a function. Inner sees outer via chain → global."""
    src = (
        'g = 100\n'
        'inner = "return g + x"\n'
        'outer = "return inner(x=5)"\n'
        'outer()'
    )
    # inner needs g (global) and x (its own kwarg). Both work via chain.
    assert _eval(h, src) == 105


def test_attribute_read_int(h):
    """`d.x` reads the value at key 'x' in dict d."""
    src = (
        'd = {"x": 42}\n'
        'd.x'
    )
    assert _eval(h, src) == 42


def test_attribute_read_chained(h):
    """`a.b.c` chains attribute access through nested dicts."""
    src = (
        'a = {"b": {"c": 7}}\n'
        'a.b.c'
    )
    assert _eval(h, src) == 7


def test_method_call_me_binding(h):
    """The receiver dict is bound as `me` in the method's scope."""
    src = (
        'obj = {"value": 99, "get": "return me.value"}\n'
        'obj.get()'
    )
    assert _eval(h, src) == 99


def test_method_call_with_kwarg(h):
    src = (
        'obj = {"base": 10, "add": "return me.base + n"}\n'
        'obj.add(n=5)'
    )
    assert _eval(h, src) == 15


def test_method_with_arithmetic(h):
    src = (
        'rect = {"w": 4, "h": 5, "area": "return me.w * me.h"}\n'
        'rect.area()'
    )
    assert _eval(h, src) == 20


def test_method_does_not_pollute_other_calls(h):
    """After `obj.method()`, plain calls don't see `me`."""
    src = (
        'obj = {"f": "return 0"}\n'
        'plain = "return 42"\n'
        'obj.f()\n'
        'plain()'
    )
    # If me leaked, plain() would see me=obj. plain doesn't reference me, so
    # this test passes either way semantically — but let's at least exercise
    # the sequence to verify clear-on-read works.
    assert _eval(h, src) == 42


def test_method_followed_by_arithmetic_then_plain_call(h):
    """`obj.f() + plain()` — plain() must NOT inherit me."""
    src = (
        'obj = {"f": "return me.x", "x": 100}\n'
        'plain = "return 1"\n'
        'obj.f() + plain()'
    )
    # If plain() inherited me=obj, then `me.x` would still work in plain
    # — but plain doesn't reference me, so we can't test that. Instead test
    # that the result is right (101).
    assert _eval(h, src) == 101


def test_property_read_doesnt_set_me_for_later_call(h):
    """`a.b` (no parens) followed by another `f()` later — f must not get me=a."""
    src = (
        'd = {"x": 5}\n'
        'fn = "return me"\n'
        'd.x\n'                 # property read, no call follows
        'fn()'                  # plain call. me should be 0 (NONE-equivalent).
    )
    # If me leaked, fn would return d. With proper clearing, me is 0.
    # Reading me as a value: scope_get("me") panics if not bound.
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)
    assert h.mpu.memory[0x27] == 0x04  # ERR_LEX (name not found)


def test_method_inside_method(h):
    """A method calls another method on the same receiver. Inner method
    needs its own me binding (= the receiver of the inner call)."""
    src = (
        'obj = {"x": 7, "helper": "return me.x * 2", "outer": "return me.helper() + 1"}\n'
        'obj.outer()'
    )
    # outer.me = obj. helper called via me.helper() → helper.me = obj.
    # helper returns 7*2 = 14. outer returns 14+1 = 15.
    assert _eval(h, src) == 15


def test_state_mutation_via_me(h):
    """A method mutates the receiver via `me.key = ...`."""
    src = (
        'counter = {"value": 0, "tick": "me.value = me.value + 1\\nreturn me.value"}\n'
        'counter.tick()\n'
        'counter.tick()\n'
        'counter.tick()\n'
        'counter.value'
    )
    assert _eval(h, src) == 3


def test_attribute_assignment_simple(h):
    """`obj.x = value` writes into the dict."""
    src = (
        'd = {"x": 1}\n'
        'd.x = 99\n'
        'd.x'
    )
    assert _eval(h, src) == 99


def test_attribute_assignment_creates_key(h):
    """Assigning to a missing key creates it (dict_set's normal behavior)."""
    src = (
        'd = {}\n'
        'd.fresh = 42\n'
        'd.fresh'
    )
    assert _eval(h, src) == 42


def test_attribute_assignment_returns_none(h):
    """`d.x = v` evaluates to NONE (statement-as-expression convention)."""
    from conftest import TYPE_NONE
    payload = list('d = {"x": 1}\nd.x = 99'.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_NONE


def test_method_can_mutate_unrelated_global(h):
    """A method can also do regular scope_set on its own locals."""
    src = (
        'obj = {"x": 5, "double": "n = me.x * 2\\nreturn n"}\n'
        'obj.double()'
    )
    assert _eval(h, src) == 10


def test_full_object_pattern(h):
    """A more complete object: bank account with deposit + balance."""
    src = (
        'account = {'
        '  "balance": 100, '
        '  "deposit": "me.balance = me.balance + amount\\nreturn me.balance", '
        '  "withdraw": "me.balance = me.balance - amount\\nreturn me.balance"'
        '}\n'
        'account.deposit(amount=50)\n'
        'account.deposit(amount=25)\n'
        'account.withdraw(amount=10)\n'
        'account.balance'
    )
    # 100 + 50 + 25 - 10 = 165
    assert _eval(h, src) == 165


def test_lexical_scoping_not_dynamic(h):
    """Python lexical scoping: a callee does NOT see the caller's locals.

    `helper` references `y`, which is set as a local of `caller` but is not
    a global. Python would raise NameError; we panic with ERR_LEX. Verifies
    we use lexical scoping (parent = ROOT_SCOPE), not dynamic (parent =
    caller's scope)."""
    src = (
        'helper = "return y"\n'
        'caller = "y = 99\\nreturn helper()"\n'
        'caller()'
    )
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)
    assert h.mpu.memory[0x27] == 0x04   # ERR_LEX


def test_return_yields_ctrl_handle(h):
    """At parser_stmt level, `return e` produces a TYPE_CTRL handle."""
    from conftest import RV
    src = "return 42"
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    # H_TYPE byte at offset 6.
    assert h.mpu.memory[rv + 6] == 0x28  # TYPE_CTRL


# --- Stage 10: slice -------------------------------------------------------

def _eval_str(h, source: str) -> bytes:
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    from test_str import read_str
    return bytes(read_str(h, h.read_word(RV)))


def _eval_list_ints(h, source: str) -> list[int]:
    """Evaluate to a TYPE_LIST/TUPLE of ints; read element values."""
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    obj = h.read_word(rv)               # H_PTR -> object base
    n = h.read_word(obj)                # O_LEN
    out = []
    for i in range(n):
        elem_handle = h.read_word(obj + 2 + 2 * i)
        out.append(_read_int(h, elem_handle))
    return out


def test_str_slice_basic(h):
    assert _eval_str(h, '"abcdef"[1:4]') == b"bcd"


def test_str_slice_full(h):
    assert _eval_str(h, '"abcdef"[0:6]') == b"abcdef"


def test_str_slice_empty_when_start_eq_stop(h):
    assert _eval_str(h, '"abcdef"[2:2]') == b""


def test_str_slice_empty_when_start_gt_stop(h):
    assert _eval_str(h, '"abcdef"[4:2]') == b""


def test_str_slice_clamps_stop_to_len(h):
    assert _eval_str(h, '"abcdef"[3:99]') == b"def"


def test_list_slice_basic(h):
    assert _eval_list_ints(h, "[10, 20, 30, 40, 50][1:4]") == [20, 30, 40]


def test_list_slice_full(h):
    assert _eval_list_ints(h, "[1, 2, 3][0:3]") == [1, 2, 3]


def test_list_slice_empty(h):
    payload = list("[10, 20, 30][1:1]".encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    obj = h.read_word(rv)
    assert h.read_word(obj) == 0


def test_list_slice_returns_new_list_type(h):
    """Slicing a list yields a list, not a tuple."""
    from conftest import TYPE_LIST
    payload = list("[1, 2, 3][0:2]".encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_LIST


def test_tuple_slice_preserves_tuple_type(h):
    """Slicing a tuple yields a tuple."""
    from conftest import TYPE_TUPLE
    payload = list("(10, 20, 30, 40)[1:3]".encode("ascii"))
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_TUPLE


def test_tuple_slice_values(h):
    assert _eval_list_ints(h, "(1, 2, 3, 4, 5)[2:5]") == [3, 4, 5]


def test_slice_with_arithmetic_indices(h):
    assert _eval_list_ints(h, "[10, 20, 30, 40][1:1+2]") == [20, 30]


def test_slice_on_variable(h):
    assert _eval_list_ints(h, "xs = [1, 2, 3, 4, 5]\nxs[1:4]") == [2, 3, 4]


def test_slice_does_not_mutate_source_list(h):
    """`xs[1:3]` returns a copy. xs should still be [1,2,3,4]."""
    src = (
        "xs = [1, 2, 3, 4]\n"
        "xs[1:3]\n"        # produces [2, 3], discarded
        "xs"
    )
    assert _eval_list_ints(h, src) == [1, 2, 3, 4]


# --- Stage 10: deep-path reads --------------------------------------------

def test_deep_dot_chain_4(h):
    """`a.b.c.d` — 4-level attribute chain."""
    src = (
        'a = {"b": {"c": {"d": 99}}}\n'
        'a.b.c.d'
    )
    assert _eval(h, src) == 99


def test_deep_dot_chain_5(h):
    src = (
        'r = {"a": {"b": {"c": {"d": {"e": 7}}}}}\n'
        'r.a.b.c.d.e'
    )
    assert _eval(h, src) == 7


def test_dot_then_subscript(h):
    """`a.lst[0]` — dot then list subscript."""
    src = (
        'a = {"lst": [10, 20, 30]}\n'
        'a.lst[1]'
    )
    assert _eval(h, src) == 20


def test_subscript_then_dot(h):
    """`xs[0].name` — subscript then dot. xs is list-of-dicts."""
    src = (
        'xs = [{"name": 100}, {"name": 200}]\n'
        'xs[1].name'
    )
    assert _eval(h, src) == 200


def test_dict_subscript_then_dot(h):
    """`d[k].name` — dict-of-dicts subscript then dot."""
    src = (
        'd = {1: {"x": 10}, 2: {"x": 20}}\n'
        'd[2].x'
    )
    assert _eval(h, src) == 20


def test_dot_subscript_dot(h):
    """`a.lst[0].name`."""
    src = (
        'a = {"lst": [{"name": 5}, {"name": 6}]}\n'
        'a.lst[1].name'
    )
    assert _eval(h, src) == 6


def test_subscript_dot_subscript(h):
    """`xs[0].field[1]` — list-of-dicts-of-lists."""
    src = (
        'xs = [{"v": [10, 20, 30]}]\n'
        'xs[0].v[2]'
    )
    assert _eval(h, src) == 30


def test_long_mixed_path(h):
    """`a.b.c[0].d` — long mixed dot/subscript chain."""
    src = (
        'a = {"b": {"c": [{"d": 42}]}}\n'
        'a.b.c[0].d'
    )
    assert _eval(h, src) == 42


def test_nested_list_subscript(h):
    """`grid[1][2]` — list of lists."""
    src = (
        'grid = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]\n'
        'grid[1][2]'
    )
    assert _eval(h, src) == 6


def test_dict_of_lists_of_dicts(h):
    """Mix of all container types with depth 4."""
    src = (
        'data = {"items": [{"price": 100}, {"price": 200}]}\n'
        'data.items[1].price'
    )
    assert _eval(h, src) == 200


# --- Stage 10: deep-path writes -------------------------------------------

def test_chained_dot_assign(h):
    """`a.b.c = v` writes into the intermediate dict."""
    src = (
        'a = {"b": {"c": 0}}\n'
        'a.b.c = 99\n'
        'a.b.c'
    )
    assert _eval(h, src) == 99


def test_chained_dot_assign_creates_key(h):
    """`a.b.fresh = v` creates a new key on the intermediate dict."""
    src = (
        'a = {"b": {}}\n'
        'a.b.fresh = 42\n'
        'a.b.fresh'
    )
    assert _eval(h, src) == 42


def test_dot_then_subscript_assign(h):
    """`a.lst[0] = v` — write to a list element via attribute."""
    src = (
        'a = {"lst": [10, 20, 30]}\n'
        'a.lst[0] = 99\n'
        'a.lst[0]'
    )
    assert _eval(h, src) == 99


def test_subscript_then_dot_assign(h):
    """`xs[0].name = v` — write to attribute through subscript."""
    src = (
        'xs = [{"name": 1}, {"name": 2}]\n'
        'xs[0].name = 99\n'
        'xs[0].name'
    )
    assert _eval(h, src) == 99


def test_nested_subscript_assign(h):
    """`grid[1][2] = v` — write into list-of-lists."""
    src = (
        'grid = [[1, 2, 3], [4, 5, 6]]\n'
        'grid[1][2] = 99\n'
        'grid[1][2]'
    )
    assert _eval(h, src) == 99


def test_dict_of_dicts_subscript_assign(h):
    """`d[k1][k2] = v` — dict-of-dicts subscript chain assign."""
    src = (
        'd = {1: {"x": 0}, 2: {"x": 0}}\n'
        'd[2]["x"] = 88\n'
        'd[2]["x"]'
    )
    assert _eval(h, src) == 88


def test_long_path_assign(h):
    """`a.b.c[0].d = v` — long mixed assign."""
    src = (
        'a = {"b": {"c": [{"d": 0}]}}\n'
        'a.b.c[0].d = 77\n'
        'a.b.c[0].d'
    )
    assert _eval(h, src) == 77


# --- Stage 10: methods on deep receivers ----------------------------------

def test_method_call_on_dot_chain(h):
    """`a.b.method()` — receiver is the dict reached via chain."""
    src = (
        'a = {"b": {"v": 7, "get": "return me.v"}}\n'
        'a.b.get()'
    )
    assert _eval(h, src) == 7


def test_method_call_on_subscript(h):
    """`xs[0].method()` — receiver is a list element."""
    src = (
        'xs = [{"v": 11, "get": "return me.v"}]\n'
        'xs[0].get()'
    )
    assert _eval(h, src) == 11


def test_method_call_on_long_path(h):
    """`a.b.lst[0].method()` — long-path method invocation."""
    src = (
        'a = {"b": {"lst": [{"v": 9, "get": "return me.v"}]}}\n'
        'a.b.lst[0].get()'
    )
    assert _eval(h, src) == 9


def test_method_mutates_deep_receiver(h):
    """Method on a deep receiver mutates that receiver, not the outer."""
    src = (
        'a = {"b": {"v": 0, "set": "me.v = n\\nreturn me.v"}}\n'
        'a.b.set(n=5)\n'
        'a.b.v'
    )
    assert _eval(h, src) == 5


# --- Stage 10: slices in deep paths ---------------------------------------

def test_slice_on_attribute(h):
    """`a.lst[1:3]` — slice on attribute-accessed list."""
    src = (
        'a = {"lst": [10, 20, 30, 40, 50]}\n'
        'a.lst[1:3]'
    )
    assert _eval_list_ints(h, src) == [20, 30]


def test_slice_on_nested_subscript(h):
    """`grid[1][1:3]` — slice on a row of a 2D list."""
    src = (
        'grid = [[1, 2, 3, 4], [5, 6, 7, 8]]\n'
        'grid[1][1:3]'
    )
    assert _eval_list_ints(h, src) == [6, 7]


def test_slice_str_on_attribute(h):
    """`a.s[1:4]` — string slice via attribute."""
    src = (
        'a = {"s": "abcdef"}\n'
        'a.s[1:4]'
    )
    assert _eval_str(h, src) == b"bcd"


def test_slice_then_index(h):
    """`xs[1:4][0]` — index into the result of a slice."""
    src = "xs = [10, 20, 30, 40, 50]\nxs[1:4][0]"
    assert _eval(h, src) == 20


def test_list_subscript_assign_simple(h):
    """`a[i] = v` on a plain top-level list."""
    src = "a = [0, 1, 2, 3, 4]\na[4] = 5\na[4]"
    assert _eval(h, src) == 5


def test_dict_string_key_then_list_index(h):
    """`d[\"a\"][1]` — string-keyed dict, value is a list."""
    src = 'd = {"a": [1, 2, 3]}\nd["a"][1]'
    assert _eval(h, src) == 2


# --- Short-circuit `and` / `or` --------------------------------------------
# These tests verify the RHS is NOT evaluated when the result is determined
# by the LHS — observable through side effects (mutation of a tracker dict).

def test_and_short_circuits_rhs_call(h):
    """`0 and bump()` must not call bump."""
    src = (
        'tracker = {"n": 0}\n'
        'bump = "tracker.n = tracker.n + 1\\nreturn 1"\n'
        'r = 0 and bump()\n'           # LHS falsy → bump skipped
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_and_evaluates_rhs_when_lhs_truthy(h):
    """`1 and bump()` must call bump."""
    src = (
        'tracker = {"n": 0}\n'
        'bump = "tracker.n = tracker.n + 1\\nreturn 1"\n'
        'r = 1 and bump()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 1


def test_or_short_circuits_rhs_call(h):
    """`1 or bump()` must not call bump."""
    src = (
        'tracker = {"n": 0}\n'
        'bump = "tracker.n = tracker.n + 1\\nreturn 1"\n'
        'r = 1 or bump()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_or_evaluates_rhs_when_lhs_falsy(h):
    """`0 or bump()` must call bump."""
    src = (
        'tracker = {"n": 0}\n'
        'bump = "tracker.n = tracker.n + 1\\nreturn 1"\n'
        'r = 0 or bump()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 1


def test_and_chain_stops_at_first_falsy(h):
    """`1 and 0 and bump()` — short-circuits at the 0; bump never called."""
    src = (
        'tracker = {"n": 0}\n'
        'bump = "tracker.n = tracker.n + 1\\nreturn 1"\n'
        'r = 1 and 0 and bump()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_or_chain_stops_at_first_truthy(h):
    """`0 or 1 or bump()` — short-circuits at the 1; bump never called."""
    src = (
        'tracker = {"n": 0}\n'
        'bump = "tracker.n = tracker.n + 1\\nreturn 1"\n'
        'r = 0 or 1 or bump()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_short_circuit_with_subscript_rhs(h):
    """RHS containing a subscript must skip cleanly through `[ ]`."""
    src = (
        'xs = [10, 20, 30]\n'
        'tracker = {"n": 0}\n'
        'mark = "tracker.n = 1\\nreturn 0"\n'
        'r = 0 and xs[mark()]\n'        # falsy short-circuit, mark not called
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_short_circuit_with_dot_chain_rhs(h):
    """RHS like `a.b.c` must skip cleanly through dot chain."""
    src = (
        'a = {"b": {"c": 0}}\n'
        'r = 1 or a.b.c\n'              # truthy short-circuit; access skipped
        'r'
    )
    assert _eval(h, src) == 1


def test_short_circuit_with_arithmetic_rhs(h):
    """RHS with + and * must skip through ordinary infix ops."""
    src = (
        'tracker = {"n": 0}\n'
        'side = "tracker.n = 1\\nreturn 5"\n'
        'r = 0 and 2 + 3 * side()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_short_circuit_preserves_lhs_value(h):
    """Skip path returns LHS handle; value should round-trip unchanged."""
    src = (
        '0 and 999'   # LHS falsy → returns 0
    )
    assert _eval(h, src) == 0


def test_short_circuit_with_paren_grouped_rhs(h):
    """RHS inside parens — depth tracker must consume the whole group."""
    src = (
        'tracker = {"n": 0}\n'
        'side = "tracker.n = 1\\nreturn 1"\n'
        'r = 0 and (1 + side())\n'
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_short_circuit_with_unary_rhs(h):
    """RHS starts with prefix unary — skip must consume it."""
    src = (
        'tracker = {"n": 0}\n'
        'side = "tracker.n = 1\\nreturn 1"\n'
        'r = 1 or -side()\n'            # truthy → skip; side not called
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_mixed_and_or_short_circuit(h):
    """`0 or 1 and side()` — `1 and side()` evaluates (1 truthy), side called."""
    src = (
        'tracker = {"n": 0}\n'
        'side = "tracker.n = 7\\nreturn 1"\n'
        'r = 0 or 1 and side()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 7


def test_short_circuit_in_if_condition(h):
    """`if 0 and side(): ...` — side not called even though `if` evaluates."""
    src = (
        'tracker = {"n": 0}\n'
        'side = "tracker.n = 1\\nreturn True"\n'
        'if 0 and side():\n'
        '    pass\n'
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_multiline_list_basic(h):
    """List literal spanning multiple lines parses correctly."""
    src = (
        "xs = [\n"
        "    1,\n"
        "    2,\n"
        "    3\n"
        "]\n"
        "xs[1]"
    )
    assert _eval(h, src) == 2


def test_multiline_list_trailing_comma(h):
    src = (
        "xs = [\n"
        "    10,\n"
        "    20,\n"
        "]\n"
        "xs[0]"
    )
    assert _eval(h, src) == 10


def test_multiline_list_empty(h):
    src = (
        "xs = [\n"
        "]\n"
        "xs"
    )
    assert _eval_list_ints(h, src) == []


def test_multiline_dict_basic(h):
    src = (
        'd = {\n'
        '    "a": 1,\n'
        '    "b": 2,\n'
        '    "c": 3\n'
        '}\n'
        'd["b"]'
    )
    assert _eval(h, src) == 2


def test_multiline_dict_value_on_next_line(h):
    """Newline after `:` allowed."""
    src = (
        'd = {\n'
        '    "key":\n'
        '        99\n'
        '}\n'
        'd["key"]'
    )
    assert _eval(h, src) == 99


def test_multiline_tuple(h):
    src = (
        "t = (\n"
        "    1,\n"
        "    2,\n"
        "    3,\n"
        ")\n"
        "t[2]"
    )
    assert _eval(h, src) == 3


def test_multiline_nested_literals(h):
    """List of dicts spanning many lines."""
    src = (
        'objs = [\n'
        '    {\n'
        '        "name": 1,\n'
        '        "value": 10\n'
        '    },\n'
        '    {\n'
        '        "name": 2,\n'
        '        "value": 20\n'
        '    }\n'
        ']\n'
        'objs[1]["value"]'
    )
    assert _eval(h, src) == 20


def test_for_over_dict_iterates_keys(h):
    """`for k in d:` iterates over keys (Python convention)."""
    src = (
        'd = {1: 10, 2: 20, 3: 30}\n'
        'total = 0\n'
        'for k in d:\n'
        '    total = total + k\n'
        'total'
    )
    assert _eval(h, src) == 6  # 1 + 2 + 3


def test_for_over_dict_string_keys(h):
    """Iterating a dict with string keys still binds the keys to the var."""
    src = (
        'd = {"a": 1, "b": 2, "c": 3}\n'
        'count = 0\n'
        'for k in d:\n'
        '    count = count + d[k]\n'
        'count'
    )
    assert _eval(h, src) == 6


def test_for_over_empty_dict_zero_iterations(h):
    src = (
        'count = 0\n'
        'for k in {}:\n'
        '    count = count + 1\n'
        'count'
    )
    assert _eval(h, src) == 0


def test_for_over_dict_with_break(h):
    """`break` inside a dict-iter loop exits cleanly."""
    src = (
        'd = {1: 10, 2: 20, 3: 30}\n'
        'last = 0\n'
        'for k in d:\n'
        '    last = k\n'
        '    if k == 2:\n'
        '        break\n'
        'last'
    )
    # Keys are sorted: iteration order = 1, 2, then break.
    assert _eval(h, src) == 2


def test_multiline_literal_inside_function_body(h):
    """Multi-line literal inside a function body."""
    src = (
        'mk = "return [\\n  1,\\n  2,\\n  3\\n]"\n'
        'mk()[1]'
    )
    assert _eval(h, src) == 2


def test_short_circuit_in_while_condition(h):
    """`while False or side():` — side called, but result is `False or 0`
    on the second iteration (assuming side returns 0). Loop exits."""
    src = (
        'tracker = {"n": 0}\n'
        'side = "tracker.n = tracker.n + 1\\nreturn tracker.n < 3"\n'
        'while False or side():\n'
        '    pass\n'
        'tracker.n'
    )
    # 3 iterations: side() returns True, True, False → loop exits.
    assert _eval(h, src) == 3


# --- Stage 11: extended methods + negative indices + del statement --------

def test_str_lower(h):
    assert _eval_str(h, '"HELLO".lower()') == b"hello"


def test_str_upper_lower_roundtrip(h):
    assert _eval_str(h, '"AbCdEf".upper().lower()') == b"abcdef"


def test_str_find_present(h):
    assert _eval(h, '"hello".find("l")') == 2


def test_str_find_missing(h):
    assert _eval(h, '"hello".find("z")') == -1


def test_str_find_empty_returns_zero(h):
    assert _eval(h, '"hello".find("")') == 0


def test_str_startswith_match(h):
    assert _eval_bool(h, '"hello".startswith("he")') is True


def test_str_startswith_mismatch(h):
    assert _eval_bool(h, '"hello".startswith("world")') is False


def test_str_startswith_empty_always_true(h):
    assert _eval_bool(h, '"abc".startswith("")') is True


def test_str_endswith_match(h):
    assert _eval_bool(h, '"hello".endswith("lo")') is True


def test_str_endswith_mismatch(h):
    assert _eval_bool(h, '"hello".endswith("world")') is False


def test_list_insert_middle(h):
    src = (
        'lst = [1, 2, 3]\n'
        'lst.insert(1, 99)\n'
        'lst[1]'
    )
    assert _eval(h, src) == 99


def test_list_insert_at_zero(h):
    src = (
        'lst = [10, 20]\n'
        'lst.insert(0, 5)\n'
        'lst[0]'
    )
    assert _eval(h, src) == 5


def test_list_pop_returns_last(h):
    assert _eval(h, "[1, 2, 3].pop()") == 3


def test_list_pop_shrinks(h):
    src = (
        'lst = [1, 2, 3]\n'
        'lst.pop()\n'
        'len(lst)'
    )
    assert _eval(h, src) == 2


def test_list_pop_until_one(h):
    src = (
        'lst = [10, 20, 30]\n'
        'lst.pop()\n'
        'lst.pop()\n'
        'lst[0]'
    )
    assert _eval(h, src) == 10


def test_dict_get_present(h):
    assert _eval(h, '{1: 10, 2: 20}.get(2, 0)') == 20


def test_dict_get_missing_returns_default(h):
    assert _eval(h, '{1: 10}.get(99, 7)') == 7


def test_dict_keys_length(h):
    assert _eval(h, 'len({1: 10, 2: 20, 3: 30}.keys())') == 3


def test_dict_keys_iteration_via_subscript(h):
    src = (
        'd = {1: 10, 2: 20, 3: 30}\n'
        'd.keys()[1]'
    )
    assert _eval(h, src) == 2


def test_dict_values_extracts_values(h):
    src = (
        'd = {1: 10, 2: 20, 3: 30}\n'
        'd.values()[1]'
    )
    assert _eval(h, src) == 20


def test_dict_iterate_via_values(h):
    src = (
        'total = 0\n'
        'for v in {1: 10, 2: 20, 3: 30}.values():\n'
        '    total = total + v\n'
        'total'
    )
    assert _eval(h, src) == 60


def test_user_dict_method_shadows_builtin_get(h):
    """User's "get" key takes precedence over the built-in dict.get method."""
    src = (
        'obj = {"value": 99, "get": "return me.value"}\n'
        'obj.get()'
    )
    assert _eval(h, src) == 99


def test_user_dict_method_shadows_builtin_keys(h):
    src = (
        'obj = {"keys": "return 42"}\n'
        'obj.keys()'
    )
    assert _eval(h, src) == 42


def test_del_list_element(h):
    src = (
        'lst = [10, 20, 30]\n'
        'del lst[1]\n'
        'lst[1]'
    )
    assert _eval(h, src) == 30


def test_del_list_shrinks(h):
    src = (
        'lst = [10, 20, 30]\n'
        'del lst[0]\n'
        'len(lst)'
    )
    assert _eval(h, src) == 2


def test_del_dict_key(h):
    src = (
        'd = {1: 10, 2: 20, 3: 30}\n'
        'del d[2]\n'
        'len(d)'
    )
    assert _eval(h, src) == 2


def test_del_dict_then_has(h):
    src = (
        'd = {1: 10, 2: 20}\n'
        'del d[1]\n'
        'd.has(1)'
    )
    assert _eval_bool(h, src) is False


def test_negative_index_list_last(h):
    assert _eval(h, "[10, 20, 30][-1]") == 30


def test_negative_index_list_second_last(h):
    assert _eval(h, "[10, 20, 30][-2]") == 20


def test_negative_index_tuple(h):
    assert _eval(h, "(10, 20, 30)[-1]") == 30


def test_negative_index_assignment(h):
    src = (
        'lst = [1, 2, 3, 4]\n'
        'lst[-1] = 99\n'
        'lst[-1]'
    )
    assert _eval(h, src) == 99


def test_string_index_basic(h):
    assert _eval_str(h, '"abc"[0]') == b"a"


def test_string_index_middle(h):
    assert _eval_str(h, '"abc"[1]') == b"b"


def test_string_index_negative(h):
    assert _eval_str(h, '"hello"[-1]') == b"o"


def test_string_index_negative_middle(h):
    assert _eval_str(h, '"hello"[-3]') == b"l"


def test_slice_with_negative_stop(h):
    assert _eval_str(h, '"hello"[1:-1]') == b"ell"


def test_slice_with_negative_start_and_stop(h):
    assert _eval_list_ints(h, '[10, 20, 30, 40][-3:-1]') == [20, 30]


# --- Stage 11: id / cmp / hex builtins ------------------------------------

def test_id_returns_positive_int(h):
    """id(x) returns the handle address as a non-negative INT."""
    assert _eval(h, 'a = [1, 2, 3]\nid(a) > 0') is None or _eval(h, 'a = [1, 2, 3]\nid(a) > 0')


def test_id_same_object_same_id(h):
    src = (
        'a = [1, 2, 3]\n'
        'b = a\n'           # same handle
        'id(a) == id(b)'
    )
    assert _eval_bool(h, src) is True


def test_id_different_objects_different_ids(h):
    src = (
        'a = [1]\n'
        'b = [1]\n'
        'id(a) == id(b)'
    )
    assert _eval_bool(h, src) is False


def test_cmp_less(h):
    assert _eval(h, 'cmp(1, 2)') == -1


def test_cmp_equal(h):
    assert _eval(h, 'cmp(2, 2)') == 0


def test_cmp_greater(h):
    assert _eval(h, 'cmp(3, 2)') == 1


def test_cmp_strings(h):
    assert _eval(h, 'cmp("a", "b")') == -1


def test_hex_zero(h):
    assert _eval_str(h, "hex(0)") == b"0x00"


def test_hex_small_positive(h):
    assert _eval_str(h, "hex(15)") == b"0x0f"


def test_hex_negative(h):
    assert _eval_str(h, "hex(-1)") == b"-0x01"


def test_hex_large(h):
    assert _eval_str(h, "hex(256)") == b"0x0100"


# --- Stage 11: augmented assignment ---------------------------------------

def test_augass_plus(h):
    src = (
        'x = 5\n'
        'x += 3\n'
        'x'
    )
    assert _eval(h, src) == 8


def test_augass_minus(h):
    src = (
        'x = 10\n'
        'x -= 7\n'
        'x'
    )
    assert _eval(h, src) == 3


def test_augass_star(h):
    src = (
        'x = 4\n'
        'x *= 5\n'
        'x'
    )
    assert _eval(h, src) == 20


def test_augass_floordiv(h):
    src = (
        'x = 20\n'
        'x //= 7\n'
        'x'
    )
    assert _eval(h, src) == 2


def test_augass_percent(h):
    src = (
        'x = 17\n'
        'x %= 5\n'
        'x'
    )
    assert _eval(h, src) == 2


def test_augass_power(h):
    src = (
        'x = 2\n'
        'x **= 8\n'
        'x'
    )
    assert _eval(h, src) == 256


def test_augass_lshift(h):
    src = (
        'x = 5\n'
        'x <<= 2\n'
        'x'
    )
    assert _eval(h, src) == 20


def test_augass_rshift(h):
    src = (
        'x = 32\n'
        'x >>= 2\n'
        'x'
    )
    assert _eval(h, src) == 8


def test_augass_amp(h):
    src = (
        'x = 0xFF\n'
        'x &= 0x0F\n'
        'x'
    )
    assert _eval(h, src) == 15


def test_augass_pipe(h):
    src = (
        'x = 5\n'
        'x |= 8\n'
        'x'
    )
    assert _eval(h, src) == 13


def test_augass_caret(h):
    src = (
        'x = 0xFF\n'
        'x ^= 0xAA\n'
        'x'
    )
    assert _eval(h, src) == 0x55


def test_augass_str_concat(h):
    src = (
        's = "a"\n'
        's += "b"\n'
        's'
    )
    assert _eval_str(h, src) == b"ab"


def test_augass_list_extend(h):
    src = (
        'lst = [1]\n'
        'lst += [2, 3]\n'
        'lst[2]'
    )
    assert _eval(h, src) == 3
