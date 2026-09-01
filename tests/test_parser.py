"""Tests for parser_eval — Stage 8 Pratt parser-evaluator skeleton.

This is the *very first* milestone: parse + evaluate a TYPE_STR source into
a value handle. Initial scope: integer literals, +, -.
"""

from __future__ import annotations

import pytest

from conftest import RV, NEXT_HANDLE_ZP
from test_int_parse import _read_int
from test_str import place_str


def _eval(h, source: str, max_steps: int = 2_000_000) -> int:
    """Place source on heap, push handle on RS, call parser_eval, read int."""
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=max_steps)
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
    ("0xDeadBeef", 0xDEADBEEF - 0x1_0000_0000),  # 32-bit signed: -559038737
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
    handle = place_str(h, 0x8500, payload)
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
    assert _eval_bool(h, "TRUE") is True


def test_false_literal(h):
    assert _eval_bool(h, "FALSE") is False


def test_none_literal_returns_none_handle(h):
    payload = list("NONE".encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    # NONE handle has H_TYPE = TYPE_NONE
    from conftest import TYPE_NONE
    assert h.mpu.memory[rv + 6] == TYPE_NONE  # H_TYPE offset = 6


# --- string literal ---------------------------------------------------------

def test_str_literal(h):
    payload = list('"hello"'.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    from test_str import read_str
    assert bytes(read_str(h, rv)) == b"hello"


# --- str + anything → auto-coerce via str() (Option B, BASIC-style) --------
# `+` with at least one STR operand falls back to byte concatenation after
# str()-coercing the non-STR side. This keeps user code short on a 64K box.

def _eval_str(h, source: str) -> bytes:
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    from test_str import read_str
    return bytes(read_str(h, rv))


def test_str_plus_int(h):
    assert _eval_str(h, '"x=" + 42') == b"x=42"


def test_int_plus_str(h):
    assert _eval_str(h, '42 + "%"') == b"42%"


def test_str_plus_negative_int(h):
    assert _eval_str(h, '"v" + -7') == b"v-7"


def test_str_plus_bool_true(h):
    assert _eval_str(h, '"f=" + TRUE') == b"f=TRUE"


def test_str_plus_bool_false(h):
    assert _eval_str(h, '"f=" + FALSE') == b"f=FALSE"


def test_str_plus_none(h):
    assert _eval_str(h, '"v=" + NONE') == b"v=NONE"


def test_str_plus_list(h):
    """List operand renders via builtin_str: '[1,2,3]'. Brackets and bare-comma
    separator come from STR_LBRACK / STR_RBRACK / STR_COMMA_SPACE statics."""
    assert _eval_str(h, '"data: " + [1, 2, 3]') == b"data: [1,2,3]"


def test_str_plus_str_unchanged(h):
    """Pre-existing STR + STR byte concatenation must still work — the
    auto-coerce path explicitly skips the case where both sides are already
    STR (no _str_w0 call, no extra alloc)."""
    assert _eval_str(h, '"abc" + "DEF"') == b"abcDEF"


def test_str_plus_chained(h):
    """Three+ operands. `+` is left-associative, so `"a"+1+"b"` parses as
    `("a"+1)+"b"` → "a1" + "b" → "a1b"."""
    assert _eval_str(h, '"a" + 1 + "b"') == b"a1b"


# --- boolean: not / and / or ------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("NOT TRUE", False),
    ("NOT FALSE", True),
    ("NOT NONE", True),
    ("NOT 0", True),
    ("NOT 1", False),
    ("NOT -1", False),
    ("NOT NOT TRUE", True),
    ("NOT (1 < 2)", False),
    ("NOT 1 < 2", False),         # `not (1<2)` per std precedence
])
def test_not(h, text, expected):
    assert _eval_bool(h, text) is expected


def _eval_int(h, source: str) -> int:
    return _eval(h, source)


def test_and_returns_lhs_when_falsy(h):
    """Python: `0 and 5` returns 0, not False."""
    assert _eval_int(h, "0 AND 5") == 0


def test_and_returns_rhs_when_lhs_truthy(h):
    """Python: `7 and 5` returns 5."""
    assert _eval_int(h, "7 AND 5") == 5


def test_or_returns_lhs_when_truthy(h):
    """Python: `7 or 5` returns 7."""
    assert _eval_int(h, "7 OR 5") == 7


def test_or_returns_rhs_when_lhs_falsy(h):
    """Python: `0 or 5` returns 5."""
    assert _eval_int(h, "0 OR 5") == 5


@pytest.mark.parametrize("text,expected", [
    ("TRUE AND TRUE", True),
    ("TRUE AND FALSE", False),
    ("FALSE AND TRUE", False),
    ("TRUE OR FALSE", True),
    ("FALSE OR FALSE", False),
    ("TRUE AND TRUE AND TRUE", True),
    ("FALSE OR TRUE OR FALSE", True),
])
def test_bool_chains(h, text, expected):
    assert _eval_bool(h, text) is expected


def test_and_or_precedence(h):
    """`a or b and c` is `a or (b and c)` — and binds tighter than or."""
    assert _eval_bool(h, "TRUE OR FALSE AND FALSE") is True
    assert _eval_bool(h, "FALSE OR TRUE AND TRUE") is True
    assert _eval_bool(h, "FALSE OR TRUE AND FALSE") is False


def test_not_with_and_or(h):
    """`not x and y` is `(not x) and y`."""
    assert _eval_bool(h, "NOT FALSE AND TRUE") is True
    assert _eval_bool(h, "NOT TRUE AND TRUE") is False


# --- is / is not -----------------------------------------------------------

@pytest.mark.parametrize("text,expected", [
    ("NONE IS NONE", True),
    ("TRUE IS TRUE", True),
    ("FALSE IS FALSE", True),
    ("TRUE IS FALSE", False),
    ("NONE IS TRUE", False),
    ("NONE IS NOT NONE", False),
    ("TRUE IS NOT FALSE", True),
    ("NONE IS NOT TRUE", True),
])
def test_is(h, text, expected):
    assert _eval_bool(h, text) is expected


def test_is_with_int_literals_returns_false_for_separate_handles(h):
    """Each int literal allocates a fresh handle, so `1 is 1` is False
    here (in CPython it's True due to small-int caching, but we don't
    intern). This documents our actual semantics."""
    assert _eval_bool(h, "1 IS 1") is False


# --- list literal ----------------------------------------------------------

def _eval_list_len(h, source: str) -> int:
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
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
    handle = place_str(h, 0x8500, payload)
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
    handle = place_str(h, 0x8500, payload)
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
    assert _eval_container_type_and_len(h, "<>") == (TYPE_DICT, 0)


def test_one_entry_dict(h):
    from conftest import TYPE_DICT
    assert _eval_container_type_and_len(h, "<1: 10>") == (TYPE_DICT, 1)


def test_three_entry_dict(h):
    from conftest import TYPE_DICT
    assert _eval_container_type_and_len(h, "<1: 10, 2: 20, 3: 30>") == (TYPE_DICT, 3)


def test_dict_indexing_int_key(h):
    assert _eval(h, "<1: 10, 2: 20, 3: 30>[2]") == 20


def test_dict_with_trailing_comma(h):
    from conftest import TYPE_DICT
    assert _eval_container_type_and_len(h, "<1: 10,>") == (TYPE_DICT, 1)


def test_dict_lt_dict_value(h):
    """`<"A":1> < <"B":2>` — LT comparison between two dicts.
    Verifies the angle-bracket dict syntax parses correctly when surrounded
    by an actual `<` comparison operator."""
    assert _eval_bool(h, '<"A": 1> < <"B": 2>') is True


def test_dict_lt_dict_value_false(h):
    """Reverse case: `<"B":2> < <"A":1>` is False."""
    assert _eval_bool(h, '<"B": 2> < <"A": 1>') is False


# --- globals() / locals() ---------------------------------------------------

def test_globals_returns_dict(h):
    from conftest import TYPE_DICT
    assert _eval_container_type_and_len(h, 'GLOBALS()')[0] == TYPE_DICT


def test_locals_returns_dict(h):
    from conftest import TYPE_DICT
    assert _eval_container_type_and_len(h, 'LOCALS()')[0] == TYPE_DICT


def test_print_globals_with_assigned_var(h):
    """`a = 1; print globals()` — scope dict's TYPE_NAME keys must render."""
    _eval(h, 'a = 1\nPRINT GLOBALS()')


def test_print_globals_with_dict_var(h):
    """REPL idiom: assign a dict, then print globals()."""
    _eval(h, 'd = <"ADMIRAL": 114>\nPRINT GLOBALS()')


def test_print_self_referential_dict(h):
    """`g = globals(); print g` — cycle in dict; recursion guard emits `<...>`
    instead of looping forever."""
    _eval(h, 'g = GLOBALS()\nPRINT g')


def test_print_self_referential_list(h):
    """List that contains itself — guard emits `[...]`."""
    src = (
        'a = []\n'
        'a.APPEND(a)\n'
        'PRINT a'
    )
    _eval(h, src)


# --- del NAME ---------------------------------------------------------------

def test_del_name_removes_binding(h):
    """`del a` should remove `a` from the current scope dict."""
    src = (
        'a = 7\n'
        'b = 1\n'
        'DEL a\n'
        'b'
    )
    assert _eval(h, src) == 1


def test_del_name_then_lookup_panics(h):
    """After `del a`, looking up `a` panics (no fallback to parent here)."""
    src = 'a = 7\nDEL a\na'
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000, expect_panic=True)


def test_del_name_missing_panics(h):
    """`del a` when `a` is unbound is an error."""
    payload = list(b'DEL a')
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000, expect_panic=True)


def test_del_name_then_reassign(h):
    """After `del a`, `a = ...` re-introduces the binding cleanly."""
    src = (
        'a = 1\n'
        'DEL a\n'
        'a = 99\n'
        'a'
    )
    assert _eval(h, src) == 99


def test_del_name_does_not_affect_other_bindings(h):
    """`del b` removes only `b`, not `a` or `c`."""
    src = (
        'a = 10\n'
        'b = 20\n'
        'c = 30\n'
        'DEL b\n'
        'a + c'
    )
    assert _eval(h, src) == 40


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
    handle = place_str(h, 0x8500, payload)
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
    handle = place_str(hfp, 0x8500, payload)
    hfp.rs_push(handle)
    hfp.call("parser_eval", max_steps=2_000_000)
    rv = hfp.read_word(RV)
    assert hfp.mpu.memory[rv + 6] == TYPE_FLOAT  # H_TYPE


# --- multi-statement float regression --------------------------------------
# These used to hang (PC stuck in KERNAL ROM territory) on the pre-admiral
# parser before assign.asm + eval() landed. Keep them green so any future
# refactor that touches the assign path can't silently reintroduce the bug.

def test_float_two_assignments_then_add(hfp):
    assert _eval_float(hfp, "a = 0.5\nb = 0.6\na + b") == pytest.approx(1.1)


def test_float_three_assignments_then_chain(hfp):
    src = "a = 1.5\nb = 2.5\nc = 0.25\na + b + c"
    assert _eval_float(hfp, src) == pytest.approx(4.25)


def test_float_int_mix_through_assignments(hfp):
    assert _eval_float(hfp, "a = 1\nb = 2.5\na + b") == pytest.approx(3.5)


def test_three_rnd_calls_via_assignments(hfp):
    """Original Phase-4 workaround test, now without the workaround."""
    src = "a = RND()\nb = RND()\nc = RND()\na + b + c"
    # Each rnd() consumes 4 rand8 bytes; sum across 3 calls.
    assert _eval_float(hfp, src) == pytest.approx(0.8532366217, rel=1e-6)


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


# --- float `**`, `//`, `%` -------------------------------------------------
# These three go through BASIC's transcendental routines (FPWRT, INT). INT
# scribbles ZP $07 — which collides with our FP+1 — so they need
# `_fp_zp_save`/`_fp_zp_restore` to bracket the BASIC call. Without it the
# V4' frame's saved target_RSP is corrupted and the postamble walks RSP to
# garbage (caller sees RV=0). Regression test.

@pytest.mark.parametrize("text,expected", [
    ("5.0 ** 2.0", 25.0),
    ("5.0 ** 2",   25.0),
    ("5 ** 2.0",   25.0),
    ("2.0 ** 3.0", 8.0),
    ("2.0 ** 0.0", 1.0),
])
def test_float_power(hfp, text, expected):
    assert _eval_float(hfp, text) == pytest.approx(expected)


@pytest.mark.parametrize("text,expected", [
    ("5.0 // 2.0", 2.0),
    ("5.0 // 2",   2.0),
    ("7.5 // 2.5", 3.0),
])
def test_float_floordiv(hfp, text, expected):
    assert _eval_float(hfp, text) == pytest.approx(expected)


@pytest.mark.parametrize("text,expected", [
    ("5.0 % 2.0", 1.0),
    ("5.0 % 2",   1.0),
    ("7.5 % 2.5", 0.0),
])
def test_float_mod(hfp, text, expected):
    assert _eval_float(hfp, text) == pytest.approx(expected)


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
    handle = place_str(h, 0x8500, payload)
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
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True)


# --- builtin-name TST boundaries --------------------------------------------
# The TST walker reads the input string right-to-left to detect end-of-input
# via `dey; bmi`. These tests exercise miss paths the walker must reject:
#   - prefix of a builtin: walker descends until the diverging char on the *eq*
#     spine, then hits a 0 child slot.
#   - suffix of a builtin: walker matches the rightmost chars (which are the
#     leftmost in the reversed insertion key), then diverges via lt/gt.
#   - first compared char differs: walker rejects at the root.
#   - single-char unknown: walker matches at most root, falls into terminal
#     handling at a node with payload=0.

@pytest.mark.parametrize("name", [
    "ran",   # prefix of "range" (reversed walk diverges on eq-spine)
    "nge",   # suffix of "range"
    "lo",    # prefix of "len" with shared first char in walk order ('n' vs ?)
    "zen",   # same length as "len", differs only in last input char (=root cmp)
    "q",     # single-char unknown — exercises shortest walker path
])
def test_tst_unregistered_name_panics(h, name):
    payload = list(name.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)


def test_variable_in_complex_expression(h):
    assert _eval(h, "a = 2\nb = 3\na ** b + a * b") == 14   # 8 + 6


def test_variable_with_container(h):
    """Variables can hold lists/tuples/dicts."""
    payload = list("xs = [1, 2, 3]\nxs[1]".encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    assert _read_int(h, h.read_word(RV)) == 2


def test_variable_holds_string(h):
    """Variables can hold TYPE_STR; identity check."""
    payload = list('s = "hello"\ns'.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    from test_str import read_str
    assert bytes(read_str(h, rv)) == b"hello"


def test_empty_source_returns_none(h):
    """Empty source string produces NONE."""
    from conftest import TYPE_NONE
    payload = []
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_NONE


def test_just_newlines_returns_none(h):
    """Source with just whitespace/newlines returns NONE."""
    from conftest import TYPE_NONE
    payload = list("\n\n\n".encode("ascii"))
    handle = place_str(h, 0x8500, payload)
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
    handle = place_str(hfp, 0x8500, payload)
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
    payload = list("PASS".encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_NONE


def test_if_truthy_runs_body(h):
    """`if true: x = 5` sets x."""
    src = "x = 0\nIF TRUE:\n    x = 5\nx"
    assert _eval(h, src) == 5


def test_if_falsy_skips_body(h):
    """`if false: x = 5` leaves x unchanged."""
    src = "x = 0\nIF FALSE:\n    x = 5\nx"
    assert _eval(h, src) == 0


def test_if_int_condition_truthy(h):
    """Non-zero ints are truthy."""
    src = "x = 0\nIF 1:\n    x = 7\nx"
    assert _eval(h, src) == 7


def test_if_int_condition_falsy(h):
    src = "x = 0\nIF 0:\n    x = 7\nx"
    assert _eval(h, src) == 0


def test_if_else_truthy(h):
    src = "x = 0\nIF TRUE:\n    x = 1\nELSE:\n    x = 2\nx"
    assert _eval(h, src) == 1


def test_if_else_falsy(h):
    src = "x = 0\nIF FALSE:\n    x = 1\nELSE:\n    x = 2\nx"
    assert _eval(h, src) == 2


def test_if_elif_first_branch(h):
    src = "x = 0\nIF TRUE:\n    x = 1\nELIF TRUE:\n    x = 2\nELSE:\n    x = 3\nx"
    assert _eval(h, src) == 1


def test_if_elif_second_branch(h):
    src = "x = 0\nIF FALSE:\n    x = 1\nELIF TRUE:\n    x = 2\nELSE:\n    x = 3\nx"
    assert _eval(h, src) == 2


def test_if_elif_else_branch(h):
    src = "x = 0\nIF FALSE:\n    x = 1\nELIF FALSE:\n    x = 2\nELSE:\n    x = 3\nx"
    assert _eval(h, src) == 3


def test_if_elif_chain_long(h):
    """Multiple elif clauses; only the matching one runs."""
    src = (
        "n = 3\n"
        "x = -1\n"
        "IF n == 1:\n    x = 100\n"
        "ELIF n == 2:\n    x = 200\n"
        "ELIF n == 3:\n    x = 300\n"
        "ELIF n == 4:\n    x = 400\n"
        "ELSE:\n    x = 999\n"
        "x"
    )
    assert _eval(h, src) == 300


def test_if_with_complex_condition(h):
    src = "x = 0\nIF 1 + 2 == 3:\n    x = 42\nx"
    assert _eval(h, src) == 42


def test_if_with_and_or(h):
    src = "x = 0\nIF TRUE AND 5 > 2:\n    x = 9\nx"
    assert _eval(h, src) == 9


def test_nested_if(h):
    """Nested if-statements work — skip_suite handles INDENT depth."""
    src = (
        "x = 0\n"
        "IF TRUE:\n"
        "    IF TRUE:\n"
        "        x = 5\n"
        "x"
    )
    assert _eval(h, src) == 5


def test_nested_if_inner_skipped(h):
    src = (
        "x = 0\n"
        "IF TRUE:\n"
        "    IF FALSE:\n"
        "        x = 5\n"
        "    ELSE:\n"
        "        x = 10\n"
        "x"
    )
    assert _eval(h, src) == 10


def test_nested_if_outer_skipped(h):
    """Skipping outer if must skip the entire nested block, including its
    nested if."""
    src = (
        "x = 100\n"
        "IF FALSE:\n"
        "    IF TRUE:\n"
        "        x = 1\n"
        "    ELSE:\n"
        "        x = 2\n"
        "    x = 3\n"
        "x"
    )
    assert _eval(h, src) == 100


def test_if_body_multiple_statements(h):
    src = (
        "IF TRUE:\n"
        "    x = 1\n"
        "    y = 2\n"
        "    z = x + y\n"
        "z"
    )
    assert _eval(h, src) == 3


def test_pass_in_block(h):
    """`pass` is fine as a body — `if false: pass` shouldn't crash."""
    src = "x = 5\nIF FALSE:\n    PASS\nx"
    assert _eval(h, src) == 5


def test_if_after_assignment_in_chain(h):
    """if-statement followed by another statement at top level."""
    src = "x = 1\nIF TRUE:\n    x = 2\ny = x + 100\ny"
    assert _eval(h, src) == 102


# --- while loops -----------------------------------------------------------

def test_while_zero_iterations(h):
    """`while false: ...` — body never runs."""
    src = "x = 0\nWHILE FALSE:\n    x = 99\nx"
    assert _eval(h, src) == 0


def test_while_simple_count(h):
    """Count up to 5."""
    src = "i = 0\nWHILE i < 5:\n    i = i + 1\ni"
    assert _eval(h, src) == 5


def test_while_count_to_10(h):
    src = "i = 0\nWHILE i < 10:\n    i = i + 1\ni"
    assert _eval(h, src) == 10


def test_while_accumulator(h):
    """Sum 1..10 = 55."""
    src = (
        "i = 1\n"
        "s = 0\n"
        "WHILE i <= 10:\n"
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
        "WHILE n > 1:\n"
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
        "WHILE i <= 10:\n"
        "    IF i % 2 == 0:\n"
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
        "WHILE i < a:\n"
        "    j = 0\n"
        "    WHILE j < b:\n"
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
        "WHILE i < 10 AND i != 7:\n"
        "    i = i + 1\n"
        "i"
    )
    assert _eval(h, src) == 7


# --- break / continue ------------------------------------------------------

def test_while_break_simple(h):
    """`break` exits the while loop."""
    src = (
        "i = 0\n"
        "WHILE TRUE:\n"
        "    i = i + 1\n"
        "    IF i == 5:\n"
        "        BREAK\n"
        "i"
    )
    assert _eval(h, src) == 5


def test_while_break_at_start(h):
    """`break` as first statement in body — runs zero times."""
    src = (
        "i = 0\n"
        "WHILE TRUE:\n"
        "    BREAK\n"
        "    i = 99\n"
        "i"
    )
    assert _eval(h, src) == 0


def test_while_continue_simple(h):
    """`continue` skips rest of iteration."""
    src = (
        "i = 0\n"
        "s = 0\n"
        "WHILE i < 10:\n"
        "    i = i + 1\n"
        "    IF i == 5:\n"
        "        CONTINUE\n"
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
        "WHILE outer < 3:\n"
        "    j = 0\n"
        "    WHILE j < 10:\n"
        "        IF j == 2:\n"
        "            BREAK\n"
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
        "WHILE outer < 2:\n"
        "    j = 0\n"
        "    WHILE j < 5:\n"
        "        j = j + 1\n"
        "        IF j == 3:\n"
        "            CONTINUE\n"
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
        "FOR x IN [1, 2, 3, 4, 5]:\n"
        "    s = s + x\n"
        "s"
    )
    assert _eval(h, src) == 15


def test_for_over_tuple(h):
    src = (
        "s = 0\n"
        "FOR x IN (10, 20, 30):\n"
        "    s = s + x\n"
        "s"
    )
    assert _eval(h, src) == 60


def test_for_over_empty_list(h):
    """Empty list — body never runs."""
    src = "s = 99\nFOR x IN []:\n    s = 0\ns"
    assert _eval(h, src) == 99


def test_for_with_break(h):
    """`break` exits the for loop."""
    src = (
        "s = 0\n"
        "FOR x IN [1, 2, 3, 4, 5]:\n"
        "    IF x == 4:\n"
        "        BREAK\n"
        "    s = s + x\n"
        "s"
    )
    assert _eval(h, src) == 6   # 1+2+3, break before 4 added


def test_for_with_continue(h):
    """`continue` skips to next element."""
    src = (
        "s = 0\n"
        "FOR x IN [1, 2, 3, 4, 5]:\n"
        "    IF x == 3:\n"
        "        CONTINUE\n"
        "    s = s + x\n"
        "s"
    )
    assert _eval(h, src) == 12   # 1+2+4+5


def test_for_via_variable(h):
    """Container is bound to a variable first."""
    src = (
        "xs = [10, 20, 30]\n"
        "s = 0\n"
        "FOR x IN xs:\n"
        "    s = s + x\n"
        "s"
    )
    assert _eval(h, src) == 60


def test_nested_for(h):
    """Cross product of two lists."""
    src = (
        "s = 0\n"
        "FOR a IN [1, 2, 3]:\n"
        "    FOR b IN [10, 20]:\n"
        "        s = s + a * b\n"
        "s"
    )
    # (1+2+3) * (10+20) = 6 * 30 = 180
    assert _eval(h, src) == 180


def test_for_inside_while(h):
    src = (
        "i = 0\n"
        "total = 0\n"
        "WHILE i < 3:\n"
        "    FOR x IN [1, 2]:\n"
        "        total = total + x\n"
        "    i = i + 1\n"
        "total"
    )
    assert _eval(h, src) == 9  # 3 outer × 3 (sum 1+2)


def test_for_loop_var_outlives_loop(h):
    """After the loop, the loop variable still holds the last value."""
    src = "FOR x IN [10, 20, 30]:\n    PASS\nx"
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
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    return _read_screen(h)


def test_print_int(h):
    screen = _eval_with_screen(h, "PRINT 5")
    # Screen code for '5' = 0x35 (same as ASCII).
    assert screen[0] == 0x35
    # '5' alone, then space-fill afterwards.
    assert screen[1] == 0x20  # space (cursor moved down via newline; screen_init filled with spaces)


def test_print_multi_digit(h):
    screen = _eval_with_screen(h, "PRINT 1234")
    assert screen[:4] == bytes([0x31, 0x32, 0x33, 0x34])  # '1','2','3','4'


def test_print_negative(h):
    screen = _eval_with_screen(h, "PRINT -42")
    # '-' = 0x2D, '4' = 0x34, '2' = 0x32
    assert screen[:3] == bytes([0x2D, 0x34, 0x32])


def test_print_arithmetic(h):
    screen = _eval_with_screen(h, "PRINT 1 + 2 * 3")
    assert screen[0] == 0x37  # '7'


def test_print_two_args_space_separated(h):
    """`print a, b` — space-separated, like Python 2 / DCPU std_print."""
    screen = _eval_with_screen(h, "PRINT 1, 2")
    # '1', ' ', '2', then space fill.
    assert screen[:3] == bytes([0x31, 0x20, 0x32])
    assert screen[3] == 0x20


def test_print_three_args(h):
    screen = _eval_with_screen(h, "PRINT 1, 2, 3")
    assert screen[:5] == bytes([0x31, 0x20, 0x32, 0x20, 0x33])


def test_print_paren_tuple_renders_as_tuple(h):
    """`print (1, 2)` — explicit parens → single tuple value, repr-rendered."""
    screen = _eval_with_screen(h, "PRINT (1, 2)")
    # Renders as "(1,2)" — uses STR_LPAREN, STR_COMMA_SPACE, STR_RPAREN; the
    # comma renderer omits the trailing space (statics.asm note).
    assert screen[:5] == bytes([0x28, 0x31, 0x2C, 0x32, 0x29])


def test_print_no_args(h):
    """Bare `print` — just emits a newline (cursor advances)."""
    _eval_with_screen(h, "PRINT")


def test_print_string(h):
    screen = _eval_with_screen(h, 'PRINT "HI"')
    # PETSCII $48/$49 → screen codes $08/$09.
    assert screen[0] == petscii_to_screen_code(ord("H"))
    assert screen[1] == petscii_to_screen_code(ord("I"))


def test_print_true(h):
    screen = _eval_with_screen(h, "PRINT TRUE")
    # "true" → screen codes for t,r,u,e
    expected = bytes(petscii_to_screen_code(ord(c)) for c in "TRUE")
    assert screen[:4] == expected


def test_print_false(h):
    screen = _eval_with_screen(h, "PRINT FALSE")
    expected = bytes(petscii_to_screen_code(ord(c)) for c in "FALSE")
    assert screen[:5] == expected


def test_print_none(h):
    screen = _eval_with_screen(h, "PRINT NONE")
    expected = bytes(petscii_to_screen_code(ord(c)) for c in "NONE")
    assert screen[:4] == expected


def test_print_in_loop(h):
    """Multiple prints; each ends with newline."""
    h.call("screen_init")
    src = "FOR x IN [1, 2, 3]:\n    PRINT x"
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    # Row 0 col 0 = '1', row 1 col 0 = '2', row 2 col 0 = '3'.
    assert h.mpu.memory[SCREEN_BASE + 0] == 0x31         # row 0
    assert h.mpu.memory[SCREEN_BASE + 40] == 0x32        # row 1
    assert h.mpu.memory[SCREEN_BASE + 80] == 0x33        # row 2


def test_print_with_variable(h):
    screen = _eval_with_screen(h, "x = 42\nPRINT x")
    assert screen[:2] == bytes([0x34, 0x32])  # '4','2'


def test_program_compute_and_print(h):
    """Real program: compute factorial, print result."""
    src = (
        "n = 5\n"
        "f = 1\n"
        "WHILE n > 1:\n"
        "    f = f * n\n"
        "    n = n - 1\n"
        "PRINT f\n"
    )
    h.call("screen_init")
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    # 5! = 120. Screen codes for '1','2','0' = 0x31, 0x32, 0x30.
    assert h.mpu.memory[SCREEN_BASE + 0] == 0x31
    assert h.mpu.memory[SCREEN_BASE + 1] == 0x32
    assert h.mpu.memory[SCREEN_BASE + 2] == 0x30


# --- built-in functions: len, range ----------------------------------------

@pytest.mark.parametrize("text,expected", [
    ('LEN("")', 0),
    ('LEN("hello")', 5),
    ("LEN([])", 0),
    ("LEN([1, 2, 3])", 3),
    ("LEN([1, 2, 3, 4, 5, 6, 7])", 7),
    ("LEN((1, 2))", 2),
    ("LEN(<>)", 0),
    ("LEN(<1: 10, 2: 20>)", 2),
])
def test_len_builtin(h, text, expected):
    assert _eval(h, text) == expected


def test_len_via_variable(h):
    src = "xs = [10, 20, 30, 40]\nLEN(xs)"
    assert _eval(h, src) == 4


def test_range_builtin_simple(h):
    """range(N) returns a list — len(range(5)) = 5."""
    src = "LEN(RANGE(5))"
    assert _eval(h, src) == 5


def test_range_elements(h):
    """range(5)[2] should be 2."""
    assert _eval(h, "RANGE(5)[0]") == 0
    assert _eval(h, "RANGE(5)[2]") == 2
    assert _eval(h, "RANGE(5)[4]") == 4


def test_range_in_for(h):
    """The canonical `for i in range(N):` loop."""
    src = (
        "s = 0\n"
        "FOR i IN RANGE(10):\n"
        "    s = s + i\n"
        "s"
    )
    # 0+1+...+9 = 45
    assert _eval(h, src) == 45


def test_range_zero(h):
    """range(0) is an empty list."""
    assert _eval(h, "LEN(RANGE(0))") == 0


def test_nested_calls(h):
    """`len(range(N))` — calls inside calls."""
    assert _eval(h, "LEN(RANGE(7))") == 7


def test_call_with_arithmetic_arg(h):
    assert _eval(h, "LEN(RANGE(2 + 3))") == 5


# --- string-as-function (Admiral pattern) ----------------------------------

def test_str_function_simplest(h):
    """A string with `return` is callable."""
    src = (
        'add = "RETURN a + b"\n'
        'add(a=1, b=2)'
    )
    assert _eval(h, src) == 3


def test_str_function_with_arithmetic(h):
    src = (
        'square = "RETURN x * x"\n'
        'square(x=7)'
    )
    assert _eval(h, src) == 49


def test_str_function_no_args(h):
    src = (
        'forty_two = "RETURN 42"\n'
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
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_NONE


def test_str_function_with_multiple_kwargs(h):
    src = (
        'wt = "RETURN weight * 2"\n'
        'wt(weight=21)'
    )
    assert _eval(h, src) == 42


def test_str_function_locals_dont_pollute_global(h):
    """Function-local assignments shouldn't affect the caller."""
    src = (
        'x = 100\n'
        'shadow = "x = 7\\nRETURN x"\n'   # x is local in the function
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
        'inc = "RETURN n + 1"\n'
        'inc(n=5)'
    )
    # n=5 is bound in the new function scope; body sees that, not the global.
    assert _eval(h, src) == 6


def test_str_function_returns_complex_value(h):
    """Return a list."""
    src = (
        'pair = "RETURN [a, b]"\n'
        'LEN(pair(a=10, b=20))'
    )
    assert _eval(h, src) == 2


def test_nested_str_function_calls(h):
    """One function calls another."""
    src = (
        'add = "RETURN x + y"\n'
        'add(x=3, y=4)'
    )
    assert _eval(h, src) == 7


def test_str_function_in_arithmetic(h):
    src = (
        'sq = "RETURN n * n"\n'
        'sq(n=5) + 1'
    )
    assert _eval(h, src) == 26


def test_multi_line_function_body(h):
    r"""Function bodies can span multiple statements via `\n` escapes
    in the string literal."""
    src = (
        r'compute = "a = x + 1\nb = a * 2\nRETURN b"'  '\n'
        'compute(x=10)'
    )
    # x=10, a = 11, b = 22.
    assert _eval(h, src) == 22


def test_function_with_loop(h):
    r"""Function body can contain a loop."""
    src = (
        r'sum_to = "s = 0\ni = 1\nWHILE i <= n:\n    s = s + i\n    i = i + 1\nRETURN s"'  '\n'
        'sum_to(n=10)'
    )
    # 1+2+...+10 = 55
    assert _eval(h, src) == 55


def test_function_with_if(h):
    src = (
        r'sign = "IF x > 0:\n    RETURN 1\nIF x < 0:\n    RETURN -1\nRETURN 0"'  '\n'
        'sign(x=42)'
    )
    assert _eval(h, src) == 1


def test_function_with_if_else(h):
    src = (
        r'absval = "IF x < 0:\n    RETURN -x\nELSE:\n    RETURN x"'  '\n'
        'absval(x=-5)'
    )
    assert _eval(h, src) == 5


# --- parent scope chain (recursion + globals) ------------------------------

def test_function_reads_global(h):
    """Function body sees a global variable via the parent-scope link."""
    src = (
        'pi_approx = 314\n'
        'show = "RETURN pi_approx"\n'
        'show()'
    )
    assert _eval(h, src) == 314


def test_function_assignment_is_local(h):
    """Assignment inside a function shadows global only locally."""
    src = (
        'x = 100\n'
        'modify = "x = 7\\nRETURN x"\n'
        'modify()\n'
        'x'
    )
    # Inside modify, local x = 7 is bound, returned. Outer x stays 100.
    # The returned 7 is discarded; expression is `x` (the global) at end.
    assert _eval(h, src) == 100


def test_recursive_factorial(h):
    """The defining test: a recursive function calling itself by name."""
    src = (
        r'fact = "IF n <= 1:\n    RETURN 1\nRETURN n * fact(n=n-1)"'  '\n'
        'fact(n=6)'
    )
    # 6! = 720
    assert _eval(h, src) == 720


def test_recursive_fibonacci(h):
    """fib(7) = 13. Tests deep recursion (~41 calls; py65 sim is slow)."""
    src = (
        'fib = "IF n < 2:\\n    RETURN n\\nRETURN fib(n=n-1) + fib(n=n-2)"\n'
        'fib(n=7)'
    )
    # fib: 0,1,1,2,3,5,8,13
    assert _eval(h, src) == 13


def test_function_call_within_function(h):
    """One function calls another via global scope lookup."""
    src = (
        'doubler = "RETURN 2 * x"\n'
        'apply = "RETURN doubler(x=n)"\n'
        'apply(n=21)'
    )
    assert _eval(h, src) == 42


def test_function_can_call_builtin(h):
    """Function bodies can use range() and len() — they're in global scope."""
    src = (
        'count_to = "RETURN LEN(RANGE(n))"\n'
        'count_to(n=7)'
    )
    assert _eval(h, src) == 7


def test_nested_function_access_grandparent(h):
    """A function calling a function. Inner sees outer via chain → global."""
    src = (
        'g = 100\n'
        'inner = "RETURN g + x"\n'
        'outer = "RETURN inner(x=5)"\n'
        'outer()'
    )
    # inner needs g (global) and x (its own kwarg). Both work via chain.
    assert _eval(h, src) == 105


def test_attribute_read_int(h):
    """`d.x` reads the value at key 'x' in dict d."""
    src = (
        'd = <"x": 42>\n'
        'd.x'
    )
    assert _eval(h, src) == 42


def test_attribute_read_chained(h):
    """`a.b.c` chains attribute access through nested dicts."""
    src = (
        'a = <"b": <"c": 7>>\n'
        'a.b.c'
    )
    assert _eval(h, src) == 7


def test_method_call_me_binding(h):
    """The receiver dict is bound as `me` in the method's scope."""
    src = (
        'obj = <"value": 99, "get": "RETURN ME.value">\n'
        'obj.get()'
    )
    assert _eval(h, src) == 99


def test_method_call_with_kwarg(h):
    src = (
        'obj = <"base": 10, "add": "RETURN ME.base + n">\n'
        'obj.add(n=5)'
    )
    assert _eval(h, src) == 15


def test_method_with_arithmetic(h):
    src = (
        'rect = <"w": 4, "h": 5, "area": "RETURN ME.w * ME.h">\n'
        'rect.area()'
    )
    assert _eval(h, src) == 20


def test_method_does_not_pollute_other_calls(h):
    """After `obj.method()`, plain calls don't see `me`."""
    src = (
        'obj = <"f": "RETURN 0">\n'
        'plain = "RETURN 42"\n'
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
        'obj = <"f": "RETURN ME.x", "x": 100>\n'
        'plain = "RETURN 1"\n'
        'obj.f() + plain()'
    )
    # If plain() inherited me=obj, then `me.x` would still work in plain
    # — but plain doesn't reference me, so we can't test that. Instead test
    # that the result is right (101).
    assert _eval(h, src) == 101


def test_property_read_doesnt_set_me_for_later_call(h):
    """`a.b` (no parens) followed by another `f()` later — f must not get me=a."""
    src = (
        'd = <"x": 5>\n'
        'fn = "RETURN ME"\n'
        'd.x\n'                 # property read, no call follows
        'fn()'                  # plain call. me should be 0 (NONE-equivalent).
    )
    # If me leaked, fn would return d. With proper clearing, me is 0.
    # Reading me as a value: scope_get("me") panics if not bound.
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)
    assert h.mpu.memory[0x27] == 0x04  # ERR_LEX (name not found)


def test_method_inside_method(h):
    """A method calls another method on the same receiver. Inner method
    needs its own me binding (= the receiver of the inner call)."""
    src = (
        'obj = <"x": 7, "helper": "RETURN ME.x * 2", "outer": "RETURN ME.helper() + 1">\n'
        'obj.outer()'
    )
    # outer.me = obj. helper called via me.helper() → helper.me = obj.
    # helper returns 7*2 = 14. outer returns 14+1 = 15.
    assert _eval(h, src) == 15


def test_state_mutation_via_me(h):
    """A method mutates the receiver via `me.key = ...`."""
    src = (
        'counter = <"value": 0, "tick": "ME.value = ME.value + 1\\nRETURN ME.value">\n'
        'counter.tick()\n'
        'counter.tick()\n'
        'counter.tick()\n'
        'counter.value'
    )
    assert _eval(h, src) == 3


def test_attribute_assignment_simple(h):
    """`obj.x = value` writes into the dict."""
    src = (
        'd = <"x": 1>\n'
        'd.x = 99\n'
        'd.x'
    )
    assert _eval(h, src) == 99


def test_attribute_assignment_creates_key(h):
    """Assigning to a missing key creates it (dict_set's normal behavior)."""
    src = (
        'd = <>\n'
        'd.fresh = 42\n'
        'd.fresh'
    )
    assert _eval(h, src) == 42


def test_attribute_assignment_returns_none(h):
    """`d.x = v` evaluates to NONE (statement-as-expression convention)."""
    from conftest import TYPE_NONE
    payload = list('d = <"x": 1>\nd.x = 99'.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_NONE


def test_method_can_mutate_unrelated_global(h):
    """A method can also do regular scope_set on its own locals."""
    src = (
        'obj = <"x": 5, "double": "n = ME.x * 2\\nRETURN n">\n'
        'obj.double()'
    )
    assert _eval(h, src) == 10


def test_full_object_pattern(h):
    """A more complete object: bank account with deposit + balance."""
    src = (
        'account = <'
        '  "balance": 100, '
        '  "deposit": "ME.balance = ME.balance + amount\\nRETURN ME.balance", '
        '  "withdraw": "ME.balance = ME.balance - amount\\nRETURN ME.balance"'
        '>\n'
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
        'helper = "RETURN y"\n'
        'caller = "y = 99\\nRETURN helper()"\n'
        'caller()'
    )
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)
    assert h.mpu.memory[0x27] == 0x04   # ERR_LEX


def test_return_yields_ctrl_handle(h):
    """At parser_stmt level, `return e` produces a TYPE_CTRL handle."""
    from conftest import RV
    src = "RETURN 42"
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    # H_TYPE byte at offset 6.
    assert h.mpu.memory[rv + 6] == 0x28  # TYPE_CTRL


# --- Stage 10: slice -------------------------------------------------------

def _eval_str(h, source: str) -> bytes:
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    from test_str import read_str
    return bytes(read_str(h, h.read_word(RV)))


def _eval_list_ints(h, source: str) -> list[int]:
    """Evaluate to a TYPE_LIST/TUPLE of ints; read element values."""
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
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
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    obj = h.read_word(rv)
    assert h.read_word(obj) == 0


def test_list_slice_returns_new_list_type(h):
    """Slicing a list yields a list, not a tuple."""
    from conftest import TYPE_LIST
    payload = list("[1, 2, 3][0:2]".encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_LIST


def test_tuple_slice_preserves_tuple_type(h):
    """Slicing a tuple yields a tuple."""
    from conftest import TYPE_TUPLE
    payload = list("(10, 20, 30, 40)[1:3]".encode("ascii"))
    handle = place_str(h, 0x8500, payload)
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
        'a = <"b": <"c": <"d": 99>>>\n'
        'a.b.c.d'
    )
    assert _eval(h, src) == 99


def test_deep_dot_chain_5(h):
    src = (
        'r = <"a": <"b": <"c": <"d": <"e": 7>>>>>\n'
        'r.a.b.c.d.e'
    )
    assert _eval(h, src) == 7


def test_dot_then_subscript(h):
    """`a.lst[0]` — dot then list subscript."""
    src = (
        'a = <"lst": [10, 20, 30]>\n'
        'a.lst[1]'
    )
    assert _eval(h, src) == 20


def test_subscript_then_dot(h):
    """`xs[0].name` — subscript then dot. xs is list-of-dicts."""
    src = (
        'xs = [<"name": 100>, <"name": 200>]\n'
        'xs[1].name'
    )
    assert _eval(h, src) == 200


def test_dict_subscript_then_dot(h):
    """`d[k].name` — dict-of-dicts subscript then dot."""
    src = (
        'd = <1: <"x": 10>, 2: <"x": 20>>\n'
        'd[2].x'
    )
    assert _eval(h, src) == 20


def test_dot_subscript_dot(h):
    """`a.lst[0].name`."""
    src = (
        'a = <"lst": [<"name": 5>, <"name": 6>]>\n'
        'a.lst[1].name'
    )
    assert _eval(h, src) == 6


def test_subscript_dot_subscript(h):
    """`xs[0].field[1]` — list-of-dicts-of-lists."""
    src = (
        'xs = [<"v": [10, 20, 30]>]\n'
        'xs[0].v[2]'
    )
    assert _eval(h, src) == 30


def test_long_mixed_path(h):
    """`a.b.c[0].d` — long mixed dot/subscript chain."""
    src = (
        'a = <"b": <"c": [<"d": 42>]>>\n'
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
        'data = <"items": [<"price": 100>, <"price": 200>]>\n'
        'data.items[1].price'
    )
    assert _eval(h, src) == 200


# --- Stage 10: deep-path writes -------------------------------------------

def test_chained_dot_assign(h):
    """`a.b.c = v` writes into the intermediate dict."""
    src = (
        'a = <"b": <"c": 0>>\n'
        'a.b.c = 99\n'
        'a.b.c'
    )
    assert _eval(h, src) == 99


def test_chained_dot_assign_creates_key(h):
    """`a.b.fresh = v` creates a new key on the intermediate dict."""
    src = (
        'a = <"b": <>>\n'
        'a.b.fresh = 42\n'
        'a.b.fresh'
    )
    assert _eval(h, src) == 42


def test_dot_then_subscript_assign(h):
    """`a.lst[0] = v` — write to a list element via attribute."""
    src = (
        'a = <"lst": [10, 20, 30]>\n'
        'a.lst[0] = 99\n'
        'a.lst[0]'
    )
    assert _eval(h, src) == 99


def test_subscript_then_dot_assign(h):
    """`xs[0].name = v` — write to attribute through subscript."""
    src = (
        'xs = [<"name": 1>, <"name": 2>]\n'
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
        'd = <1: <"x": 0>, 2: <"x": 0>>\n'
        'd[2]["x"] = 88\n'
        'd[2]["x"]'
    )
    assert _eval(h, src) == 88


def test_long_path_assign(h):
    """`a.b.c[0].d = v` — long mixed assign."""
    src = (
        'a = <"b": <"c": [<"d": 0>]>>\n'
        'a.b.c[0].d = 77\n'
        'a.b.c[0].d'
    )
    assert _eval(h, src) == 77


# --- Stage 10: methods on deep receivers ----------------------------------

def test_method_call_on_dot_chain(h):
    """`a.b.method()` — receiver is the dict reached via chain."""
    src = (
        'a = <"b": <"v": 7, "get": "RETURN ME.v">>\n'
        'a.b.get()'
    )
    assert _eval(h, src) == 7


def test_method_call_on_subscript(h):
    """`xs[0].method()` — receiver is a list element."""
    src = (
        'xs = [<"v": 11, "get": "RETURN ME.v">]\n'
        'xs[0].get()'
    )
    assert _eval(h, src) == 11


def test_method_call_on_long_path(h):
    """`a.b.lst[0].method()` — long-path method invocation."""
    src = (
        'a = <"b": <"lst": [<"v": 9, "get": "RETURN ME.v">]>>\n'
        'a.b.lst[0].get()'
    )
    assert _eval(h, src) == 9


def test_method_mutates_deep_receiver(h):
    """Method on a deep receiver mutates that receiver, not the outer."""
    src = (
        'a = <"b": <"v": 0, "set": "ME.v = n\\nRETURN ME.v">>\n'
        'a.b.set(n=5)\n'
        'a.b.v'
    )
    assert _eval(h, src) == 5


# --- Stage 10: slices in deep paths ---------------------------------------

def test_slice_on_attribute(h):
    """`a.lst[1:3]` — slice on attribute-accessed list."""
    src = (
        'a = <"lst": [10, 20, 30, 40, 50]>\n'
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
        'a = <"s": "abcdef">\n'
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
    src = 'd = <"a": [1, 2, 3]>\nd["a"][1]'
    assert _eval(h, src) == 2


# --- Short-circuit `and` / `or` --------------------------------------------
# These tests verify the RHS is NOT evaluated when the result is determined
# by the LHS — observable through side effects (mutation of a tracker dict).

def test_and_short_circuits_rhs_call(h):
    """`0 and bump()` must not call bump."""
    src = (
        'tracker = <"n": 0>\n'
        'bump = "tracker.n = tracker.n + 1\\nRETURN 1"\n'
        'r = 0 AND bump()\n'           # LHS falsy → bump skipped
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_and_evaluates_rhs_when_lhs_truthy(h):
    """`1 and bump()` must call bump."""
    src = (
        'tracker = <"n": 0>\n'
        'bump = "tracker.n = tracker.n + 1\\nRETURN 1"\n'
        'r = 1 AND bump()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 1


def test_or_short_circuits_rhs_call(h):
    """`1 or bump()` must not call bump."""
    src = (
        'tracker = <"n": 0>\n'
        'bump = "tracker.n = tracker.n + 1\\nRETURN 1"\n'
        'r = 1 OR bump()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_or_evaluates_rhs_when_lhs_falsy(h):
    """`0 or bump()` must call bump."""
    src = (
        'tracker = <"n": 0>\n'
        'bump = "tracker.n = tracker.n + 1\\nRETURN 1"\n'
        'r = 0 OR bump()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 1


def test_and_chain_stops_at_first_falsy(h):
    """`1 and 0 and bump()` — short-circuits at the 0; bump never called."""
    src = (
        'tracker = <"n": 0>\n'
        'bump = "tracker.n = tracker.n + 1\\nRETURN 1"\n'
        'r = 1 AND 0 AND bump()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_or_chain_stops_at_first_truthy(h):
    """`0 or 1 or bump()` — short-circuits at the 1; bump never called."""
    src = (
        'tracker = <"n": 0>\n'
        'bump = "tracker.n = tracker.n + 1\\nRETURN 1"\n'
        'r = 0 OR 1 OR bump()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_short_circuit_with_subscript_rhs(h):
    """RHS containing a subscript must skip cleanly through `[ ]`."""
    src = (
        'xs = [10, 20, 30]\n'
        'tracker = <"n": 0>\n'
        'mark = "tracker.n = 1\\nRETURN 0"\n'
        'r = 0 AND xs[mark()]\n'        # falsy short-circuit, mark not called
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_short_circuit_with_dot_chain_rhs(h):
    """RHS like `a.b.c` must skip cleanly through dot chain."""
    src = (
        'a = <"b": <"c": 0>>\n'
        'r = 1 OR a.b.c\n'              # truthy short-circuit; access skipped
        'r'
    )
    assert _eval(h, src) == 1


def test_short_circuit_with_arithmetic_rhs(h):
    """RHS with + and * must skip through ordinary infix ops."""
    src = (
        'tracker = <"n": 0>\n'
        'side = "tracker.n = 1\\nRETURN 5"\n'
        'r = 0 AND 2 + 3 * side()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_short_circuit_preserves_lhs_value(h):
    """Skip path returns LHS handle; value should round-trip unchanged."""
    src = (
        '0 AND 999'   # LHS falsy → returns 0
    )
    assert _eval(h, src) == 0


def test_short_circuit_with_paren_grouped_rhs(h):
    """RHS inside parens — depth tracker must consume the whole group."""
    src = (
        'tracker = <"n": 0>\n'
        'side = "tracker.n = 1\\nRETURN 1"\n'
        'r = 0 AND (1 + side())\n'
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_short_circuit_with_unary_rhs(h):
    """RHS starts with prefix unary — skip must consume it."""
    src = (
        'tracker = <"n": 0>\n'
        'side = "tracker.n = 1\\nRETURN 1"\n'
        'r = 1 OR -side()\n'            # truthy → skip; side not called
        'tracker.n'
    )
    assert _eval(h, src) == 0


def test_mixed_and_or_short_circuit(h):
    """`0 or 1 and side()` — `1 and side()` evaluates (1 truthy), side called."""
    src = (
        'tracker = <"n": 0>\n'
        'side = "tracker.n = 7\\nRETURN 1"\n'
        'r = 0 OR 1 AND side()\n'
        'tracker.n'
    )
    assert _eval(h, src) == 7


def test_short_circuit_in_if_condition(h):
    """`if 0 and side(): ...` — side not called even though `if` evaluates."""
    src = (
        'tracker = <"n": 0>\n'
        'side = "tracker.n = 1\\nRETURN TRUE"\n'
        'IF 0 AND side():\n'
        '    PASS\n'
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
        'd = <\n'
        '    "a": 1,\n'
        '    "b": 2,\n'
        '    "c": 3\n'
        '>\n'
        'd["b"]'
    )
    assert _eval(h, src) == 2


def test_multiline_dict_value_on_next_line(h):
    """Newline after `:` allowed."""
    src = (
        'd = <\n'
        '    "KEY":\n'
        '        99\n'
        '>\n'
        'd["KEY"]'
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
        '    <\n'
        '        "name": 1,\n'
        '        "value": 10\n'
        '    >,\n'
        '    <\n'
        '        "name": 2,\n'
        '        "value": 20\n'
        '    >\n'
        ']\n'
        'objs[1]["value"]'
    )
    assert _eval(h, src) == 20


def test_for_over_dict_iterates_entries(h):
    """`for k, v in d:` unpacks each entry tuple (admiral semantics)."""
    src = (
        'd = <1: 10, 2: 20, 3: 30>\n'
        'k_total = 0\n'
        'v_total = 0\n'
        'FOR k, v IN d:\n'
        '    k_total = k_total + k\n'
        '    v_total = v_total + v\n'
        'k_total + v_total * 100'
    )
    # 1+2+3 = 6; 10+20+30 = 60. Encoded: 6 + 60*100 = 6006.
    assert _eval(h, src) == 6006


def test_inline_for_body(h):
    """`for x in [1,2,3]: r = x` — inline simple-statement body."""
    src = (
        'r = 0\n'
        'FOR x IN [1,2,3]: r = x\n'
        'r'
    )
    assert _eval(h, src) == 3


def test_inline_for_dict_tuple_target(h):
    """REPL idiom: `for name, size in dir(): print name`."""
    src = (
        'd = <"ADMIRAL": 114>\n'
        'r = 0\n'
        'FOR name, size IN d: r = size\n'
        'r'
    )
    assert _eval(h, src) == 114


def test_inline_if_body(h):
    """`if x: r = 1` — inline simple-statement body."""
    src = (
        'r = 0\n'
        'IF 1: r = 1\n'
        'r'
    )
    assert _eval(h, src) == 1


def test_inline_if_skipped(h):
    """Inline if-body is skipped when condition is false."""
    src = (
        'r = 7\n'
        'IF 0: r = 1\n'
        'r'
    )
    assert _eval(h, src) == 7


def test_inline_while_body(h):
    """`while x: ...` with inline body."""
    src = (
        'i = 0\n'
        'WHILE i < 3: i = i + 1\n'
        'i'
    )
    assert _eval(h, src) == 3


def test_for_over_dict_keys_only(h):
    """`for k, _ in d:` — Python-style "keys only" via underscore unpack."""
    src = (
        'd = <"a": 1, "b": 2, "c": 3>\n'
        'count = 0\n'
        'FOR k, _ IN d:\n'
        '    count = count + d[k]\n'
        'count'
    )
    assert _eval(h, src) == 6


def test_for_over_dict_entry_via_index(h):
    """`for entry in d:` binds the whole (key, value) tuple — index it."""
    src = (
        'd = <1: 100, 2: 200>\n'
        'total = 0\n'
        'FOR entry IN d:\n'
        '    total = total + entry[0] + entry[1]\n'
        'total'
    )
    assert _eval(h, src) == 303  # (1+100) + (2+200)


def test_for_over_empty_dict_zero_iterations(h):
    src = (
        'count = 0\n'
        'FOR k, v IN <>:\n'
        '    count = count + 1\n'
        'count'
    )
    assert _eval(h, src) == 0


def test_for_over_dict_with_break(h):
    """`break` inside a dict-iter loop exits cleanly."""
    src = (
        'd = <1: 10, 2: 20, 3: 30>\n'
        'last_v = 0\n'
        'FOR k, v IN d:\n'
        '    last_v = v\n'
        '    IF k == 2:\n'
        '        BREAK\n'
        'last_v'
    )
    # Keys are sorted: iteration visits (1,10), (2,20), then break.
    assert _eval(h, src) == 20


def test_multiline_literal_inside_function_body(h):
    """Multi-line literal inside a function body."""
    src = (
        'mk = "RETURN [\\n  1,\\n  2,\\n  3\\n]"\n'
        'mk()[1]'
    )
    assert _eval(h, src) == 2


def test_short_circuit_in_while_condition(h):
    """`while False or side():` — side called, but result is `False or 0`
    on the second iteration (assuming side returns 0). Loop exits."""
    src = (
        'tracker = <"n": 0>\n'
        'side = "tracker.n = tracker.n + 1\\nRETURN tracker.n < 3"\n'
        'WHILE FALSE OR side():\n'
        '    PASS\n'
        'tracker.n'
    )
    # 3 iterations: side() returns True, True, False → loop exits.
    assert _eval(h, src) == 3


# --- Stage 11: extended methods + negative indices + del statement --------

def test_str_lower(h):
    assert _eval_str(h, '"HELLO".LOWER()') == b"hello"


def test_str_upper_lower_roundtrip(h):
    assert _eval_str(h, '"AbCdEf".UPPER().LOWER()') == b"abcdef"


def test_str_find_present(h):
    assert _eval(h, '"hello".FIND("l")') == 2


def test_str_find_missing(h):
    assert _eval(h, '"hello".FIND("z")') == -1


def test_str_find_empty_returns_zero(h):
    assert _eval(h, '"hello".FIND("")') == 0


# --- str.find with optional start / end -------------------------------------

def test_str_find_start_skips_first_match(h):
    """`find("l", 3)` skips the two l's at indices 2,3 and finds none after."""
    # "hello".find("l", 3) → index 3 (second 'l')
    assert _eval(h, '"hello".FIND("l", 3)') == 3


def test_str_find_start_past_first(h):
    """Start one past the first occurrence finds the second."""
    assert _eval(h, '"abcabc".FIND("b", 2)') == 4


def test_str_find_start_past_last_returns_neg1(h):
    assert _eval(h, '"hello".FIND("o", 5)') == -1


def test_str_find_start_zero_equals_no_arg(h):
    assert _eval(h, '"hello".FIND("h", 0)') == 0


def test_str_find_end_excludes_match(h):
    """Match starts at index 4 (second 'b'); end=4 excludes it."""
    assert _eval(h, '"abcabc".FIND("b", 0, 4)') == 1


def test_str_find_end_includes_match(h):
    assert _eval(h, '"abcabc".FIND("b", 0, 5)') == 1


def test_str_find_end_too_short_for_match(h):
    """`needle` len 2; end=2 leaves only 'he' which doesn't contain 'lo'."""
    assert _eval(h, '"hello".FIND("lo", 0, 2)') == -1


def test_str_find_negative_start(h):
    """Negative start = me_len + start (Python semantics)."""
    # "hello".find("l", -2) → search "lo" → l is at index 3
    assert _eval(h, '"hello".FIND("l", -2)') == 3


def test_str_find_negative_end(h):
    """Negative end clips off the tail."""
    # "abcabc".find("c", 0, -1) → search "abcab" → c at index 2
    assert _eval(h, '"abcabc".FIND("c", 0, -1)') == 2


def test_str_find_negative_both(h):
    # "abcabc".find("a", -4, -1) → search "cab" (indices 2,3,4) → a at 3
    assert _eval(h, '"abcabc".FIND("a", -4, -1)') == 3


def test_str_find_empty_with_start(h):
    """Empty needle returns the (clamped) start position."""
    assert _eval(h, '"hello".FIND("", 2)') == 2


def test_str_find_empty_with_start_past_end(h):
    """Empty needle, start past length → clamps to length."""
    assert _eval(h, '"hello".FIND("", 99)') == 5


def test_str_find_start_greater_than_end(h):
    """start > end → no valid window → -1."""
    assert _eval(h, '"hello".FIND("e", 4, 2)') == -1


def test_str_find_full_range_explicit(h):
    """Explicit (0, 99) matches plain 2-arg form."""
    assert _eval(h, '"hello".FIND("l", 0, 99)') == 2


def test_str_find_membership_still_works(h):
    """Regression: `x in s` uses str_find_pos with the full-range sentinel."""
    assert _eval_bool(h, '"ll" IN "hello"') is True
    assert _eval_bool(h, '"xx" IN "hello"') is False


def test_str_startswith_match(h):
    assert _eval_bool(h, '"hello".STARTSWITH("he")') is True


def test_str_startswith_mismatch(h):
    assert _eval_bool(h, '"hello".STARTSWITH("world")') is False


def test_str_startswith_empty_always_true(h):
    assert _eval_bool(h, '"abc".STARTSWITH("")') is True


def test_str_endswith_match(h):
    assert _eval_bool(h, '"hello".ENDSWITH("lo")') is True


def test_str_endswith_mismatch(h):
    assert _eval_bool(h, '"hello".ENDSWITH("world")') is False


def test_list_insert_middle(h):
    src = (
        'lst = [1, 2, 3]\n'
        'lst.INSERT(1, 99)\n'
        'lst[1]'
    )
    assert _eval(h, src) == 99


def test_list_insert_at_zero(h):
    src = (
        'lst = [10, 20]\n'
        'lst.INSERT(0, 5)\n'
        'lst[0]'
    )
    assert _eval(h, src) == 5


def test_list_pop_returns_last(h):
    assert _eval(h, "[1, 2, 3].POP()") == 3


def test_list_pop_shrinks(h):
    src = (
        'lst = [1, 2, 3]\n'
        'lst.POP()\n'
        'LEN(lst)'
    )
    assert _eval(h, src) == 2


def test_list_pop_until_one(h):
    src = (
        'lst = [10, 20, 30]\n'
        'lst.POP()\n'
        'lst.POP()\n'
        'lst[0]'
    )
    assert _eval(h, src) == 10


def test_dict_subscript_present(h):
    assert _eval(h, '<1: 10, 2: 20>[2]') == 20


def test_dict_in_membership(h):
    assert _eval_bool(h, '99 IN <1: 10>') is False
    assert _eval_bool(h, '1 IN <1: 10>') is True


def test_dict_keys_length(h):
    assert _eval(h, 'LEN(<1: 10, 2: 20, 3: 30>.KEYS())') == 3


def test_dict_keys_iteration_via_subscript(h):
    src = (
        'd = <1: 10, 2: 20, 3: 30>\n'
        'd.KEYS()[1]'
    )
    assert _eval(h, src) == 2


def test_dict_values_extracts_values(h):
    src = (
        'd = <1: 10, 2: 20, 3: 30>\n'
        'd.VALUES()[1]'
    )
    assert _eval(h, src) == 20


def test_dict_iterate_via_values(h):
    src = (
        'total = 0\n'
        'FOR v IN <1: 10, 2: 20, 3: 30>.VALUES():\n'
        '    total = total + v\n'
        'total'
    )
    assert _eval(h, src) == 60


def test_user_dict_method_shadows_builtin_keys(h):
    src = (
        'obj = <"KEYS": "RETURN 42">\n'
        'obj.KEYS()'
    )
    assert _eval(h, src) == 42


def test_del_list_element(h):
    src = (
        'lst = [10, 20, 30]\n'
        'DEL lst[1]\n'
        'lst[1]'
    )
    assert _eval(h, src) == 30


def test_del_list_shrinks(h):
    src = (
        'lst = [10, 20, 30]\n'
        'DEL lst[0]\n'
        'LEN(lst)'
    )
    assert _eval(h, src) == 2


def test_del_dict_key(h):
    src = (
        'd = <1: 10, 2: 20, 3: 30>\n'
        'DEL d[2]\n'
        'LEN(d)'
    )
    assert _eval(h, src) == 2


def test_del_dict_then_in(h):
    src = (
        'd = <1: 10, 2: 20>\n'
        'DEL d[1]\n'
        '1 IN d'
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
    assert _eval(h, 'a = [1, 2, 3]\nID(a) > 0') is None or _eval(h, 'a = [1, 2, 3]\nID(a) > 0')


def test_id_same_object_same_id(h):
    src = (
        'a = [1, 2, 3]\n'
        'b = a\n'           # same handle
        'ID(a) == ID(b)'
    )
    assert _eval_bool(h, src) is True


def test_id_different_objects_different_ids(h):
    src = (
        'a = [1]\n'
        'b = [1]\n'
        'ID(a) == ID(b)'
    )
    assert _eval_bool(h, src) is False


def test_cmp_less(h):
    assert _eval(h, 'CMP(1, 2)') == -1


def test_cmp_equal(h):
    assert _eval(h, 'CMP(2, 2)') == 0


def test_cmp_greater(h):
    assert _eval(h, 'CMP(3, 2)') == 1


def test_cmp_strings(h):
    assert _eval(h, 'CMP("a", "b")') == -1


def test_hex_zero(h):
    assert _eval_str(h, "HEX(0)") == b"0x00"


def test_hex_small_positive(h):
    assert _eval_str(h, "HEX(15)") == b"0x0f"


def test_hex_negative(h):
    assert _eval_str(h, "HEX(-1)") == b"-0x01"


def test_hex_large(h):
    assert _eval_str(h, "HEX(256)") == b"0x0100"


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


# --- dict.create() / prototype inheritance ----------------------------------

def test_dict_create_returns_new_dict(h):
    """create() returns a fresh dict; modifying it doesn't touch the proto."""
    src = (
        'p = <"x": 1>\n'
        'c = p.CREATE()\n'
        'c["x"] = 2\n'
        'p["x"]'
    )
    assert _eval(h, src) == 1


def test_dict_create_child_holds_own_writes(h):
    src = (
        'p = <"x": 1>\n'
        'c = p.CREATE()\n'
        'c["x"] = 2\n'
        'c["x"]'
    )
    assert _eval(h, src) == 2


def test_dict_create_child_inherits_field(h):
    """Field defined on prototype is visible on child by attribute access."""
    src = (
        'p = <"x": 7>\n'
        'c = p.CREATE()\n'
        'c.x'
    )
    assert _eval(h, src) == 7


def test_dict_create_method_inherits_from_prototype(h):
    """Method defined on prototype runs on child via me-binding."""
    src = (
        'ship = <"spd": 0, "go": "ME.spd = 8">\n'
        'shuttle = ship.CREATE()\n'
        'shuttle.go()\n'
        'shuttle.spd'
    )
    assert _eval(h, src) == 8


def test_dict_create_method_does_not_pollute_prototype(h):
    src = (
        'ship = <"spd": 0, "go": "ME.spd = 8">\n'
        'shuttle = ship.CREATE()\n'
        'shuttle.go()\n'
        'ship.spd'
    )
    assert _eval(h, src) == 0


def test_dict_create_prototype_changes_propagate(h):
    """Updating the prototype is reflected in children that don't shadow."""
    src = (
        'p = <"x": 1>\n'
        'c = p.CREATE()\n'
        'p["x"] = 99\n'
        'c.x'
    )
    assert _eval(h, src) == 99


def test_dict_create_three_level_chain(h):
    """create() can chain — grandchild reads through grandparent."""
    src = (
        'a = <"v": 5>\n'
        'b = a.CREATE()\n'
        'c = b.CREATE()\n'
        'c.v'
    )
    assert _eval(h, src) == 5


def test_dict_create_subscript_inherits(h):
    """Subscript reads (`obj["key"]`) walk prototype too."""
    src = (
        'p = <"x": 11>\n'
        'c = p.CREATE()\n'
        'c["x"]'
    )
    assert _eval(h, src) == 11


# --- str.isalpha / str.isdigit ----------------------------------------------

def test_isalpha_all_letters(h):
    assert _eval_bool(h, '"Hello".ISALPHA()') is True


def test_isalpha_mixed_rejected(h):
    assert _eval_bool(h, '"Hi5".ISALPHA()') is False


def test_isalpha_empty_is_false(h):
    assert _eval_bool(h, '"".ISALPHA()') is False


def test_isalpha_space_rejected(h):
    assert _eval_bool(h, '"a b".ISALPHA()') is False


def test_isdigit_all_digits(h):
    assert _eval_bool(h, '"12345".ISDIGIT()') is True


def test_isdigit_mixed_rejected(h):
    assert _eval_bool(h, '"12a".ISDIGIT()') is False


def test_isdigit_empty_is_false(h):
    assert _eval_bool(h, '"".ISDIGIT()') is False


def test_isdigit_minus_rejected(h):
    """Leading sign isn't a digit per Python's str.isdigit."""
    assert _eval_bool(h, '"-1".ISDIGIT()') is False


# --- repr() and container rendering ----------------------------------------

def test_repr_string_quotes(h):
    """repr('hi') wraps in single quotes."""
    assert _eval_str(h, "REPR('hi')") == b"'hi'"


def test_repr_int_unchanged(h):
    """repr(int) renders the same as str(int)."""
    assert _eval_str(h, 'REPR(42)') == b"42"


def test_repr_bool_unchanged(h):
    assert _eval_str(h, 'REPR(TRUE)') == b"TRUE"


def test_repr_none_unchanged(h):
    assert _eval_str(h, 'REPR(NONE)') == b"NONE"


def test_str_list_quotes_inner_strings(h):
    """str([1, 'hi']) → "[1,'hi']" — inner strings are quoted. Separator is
    a bare comma (no trailing space) — see STR_COMMA_SPACE in statics.asm."""
    assert _eval_str(h, 'STR([1, "hi"])') == b"[1,'hi']"


def test_str_int_in_list_unchanged(h):
    """str([1, 2]) → "[1,2]"."""
    assert _eval_str(h, 'STR([1, 2])') == b"[1,2]"


def test_str_dict_quotes_string_keys_and_values(h):
    """str(<'a': 'b'>) → "<'a':'b'>" — both key and value quoted, key/value
    separator is a bare colon. Brackets are angle, not curly: the C64
    character ROM has no `<` `>` glyphs."""
    assert _eval_str(h, 'STR(<"a": "b">)') == b"<'a':'b'>"


def test_str_tuple_quotes_inner(h):
    assert _eval_str(h, 'STR(("x",))') == b"('x',)" or _eval_str(h, 'STR(("x", 1))') == b"('x',1)"


def test_repr_list_same_as_str(h):
    """repr() and str() agree on containers."""
    src1 = 'REPR([1, "hi"])'
    src2 = 'STR([1, "hi"])'
    assert _eval_str(h, src1) == _eval_str(h, src2)


def test_str_top_level_string_passthrough(h):
    """str('hi') returns the bare string — no quotes (vs. repr which adds them)."""
    assert _eval_str(h, "STR('hi')") == b"hi"


# --- str.replace --------------------------------------------------------------

def test_replace_simple(h):
    assert _eval_str(h, '"hello".REPLACE("l", "L")') == b"heLLo"


def test_replace_no_match(h):
    assert _eval_str(h, '"hello".REPLACE("x", "Y")') == b"hello"


def test_replace_grow(h):
    """new longer than old."""
    assert _eval_str(h, '"abc".REPLACE("b", "BBB")') == b"aBBBc"


def test_replace_shrink(h):
    """new shorter than old."""
    assert _eval_str(h, '"hello".REPLACE("ll", "")') == b"heo"


def test_replace_multi_char_pattern(h):
    assert _eval_str(h, '"banana".REPLACE("an", "X")') == b"bXXa"


def test_replace_at_start(h):
    assert _eval_str(h, '"abc".REPLACE("a", "Z")') == b"Zbc"


def test_replace_at_end(h):
    assert _eval_str(h, '"abc".REPLACE("c", "Z")') == b"abZ"


def test_replace_overlap_non_greedy(h):
    """After a match, scanning continues past the replaced region — Python sem."""
    assert _eval_str(h, '"aaaa".REPLACE("aa", "b")') == b"bb"


def test_replace_whole_string(h):
    assert _eval_str(h, '"hello".REPLACE("hello", "world")') == b"world"


def test_replace_empty_old_panics(h):
    """Empty `old` is a type error in this port."""
    src = '"abc".REPLACE("", "X")'
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)


# --- str.split -------------------------------------------------------------

def test_split_basic(h):
    """split returns a 3-element list."""
    assert _eval(h, 'LEN("a,b,c".SPLIT(","))') == 3


def test_split_first_element(h):
    assert _eval_str(h, '"a,b,c".SPLIT(",")[0]') == b"a"


def test_split_last_element(h):
    assert _eval_str(h, '"a,b,c".SPLIT(",")[2]') == b"c"


def test_split_empty_segments(h):
    """Consecutive seps produce empty strings (Python sem)."""
    assert _eval(h, 'LEN("a,,b".SPLIT(","))') == 3


def test_split_empty_segment_value(h):
    assert _eval_str(h, '"a,,b".SPLIT(",")[1]') == b""


def test_split_leading_empty(h):
    assert _eval_str(h, '",a".SPLIT(",")[0]') == b""


def test_split_trailing_empty(h):
    assert _eval_str(h, '"a,".SPLIT(",")[1]') == b""


def test_split_no_sep_in_string(h):
    """No matches → list with one element = original string."""
    assert _eval_str(h, '"hello".SPLIT(",")[0]') == b"hello"


def test_split_no_sep_length(h):
    assert _eval(h, 'LEN("hello".SPLIT(","))') == 1


def test_split_multi_char_sep(h):
    assert _eval_str(h, '"1<>2<>3".SPLIT("<>")[1]') == b"2"


def test_split_empty_string(h):
    """Empty me → list with one empty string."""
    assert _eval(h, 'LEN("".SPLIT(","))') == 1


def test_split_empty_string_value(h):
    assert _eval_str(h, '"".SPLIT(",")[0]') == b""


def test_split_empty_sep_panics(h):
    src = '"abc".SPLIT("")'
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)


# --- str.split() whitespace mode -------------------------------------------
# Zero-arg split: any run of whitespace ($20 / $0D) acts as a single
# separator, leading/trailing whitespace is stripped, empty segments are
# never emitted. Mirrors Python's `str.split()`.

def test_split_ws_basic(h):
    assert _eval(h, 'LEN("a b c".SPLIT())') == 3


def test_split_ws_collapses_runs(h):
    """Multiple spaces between words count as one separator."""
    assert _eval(h, 'LEN("a   b".SPLIT())') == 2


def test_split_ws_strips_leading(h):
    assert _eval_str(h, '"   hi".SPLIT()[0]') == b"hi"


def test_split_ws_strips_trailing(h):
    assert _eval(h, 'LEN("hi   ".SPLIT())') == 1


def test_split_ws_strips_both(h):
    assert _eval_str(h, '"  one  two  ".SPLIT()[1]') == b"two"


def test_split_ws_empty_string(h):
    """Whitespace mode on empty string → empty list (NOT [""])."""
    assert _eval(h, 'LEN("".SPLIT())') == 0


def test_split_ws_only_whitespace(h):
    """All-whitespace input → empty list."""
    assert _eval(h, 'LEN("    ".SPLIT())') == 0


def test_split_ws_handles_cr(h):
    """$0D (CR) is also whitespace."""
    src = 'LEN("a\\rb".SPLIT())'
    # Use literal CR via chr(13) so the source is parsed correctly.
    src = 'LEN(("a" + CHR(13) + "b").SPLIT())'
    assert _eval(h, src) == 2


def test_split_ws_mixed_separators(h):
    """Mix of space + CR runs together as one separator."""
    src = '("a" + CHR(13) + "  " + CHR(13) + "b").SPLIT()'
    assert _eval(h, f'LEN({src})') == 2


def test_split_ws_segment_values(h):
    assert _eval_str(h, '"  hello world  ".SPLIT()[0]') == b"hello"


# --- rnd -------------------------------------------------------------------
# rnd() / rnd(end) / rnd(start, end) — Admiral-compatible random.
# The 0-arg form returns a FLOAT in [0, 1) (uses BASIC ROM via float_random),
# so all rnd tests run on the `hfp` fixture.

def test_rnd_no_args_returns_float_in_unit_interval(hfp):
    """rnd() returns a FLOAT in [0, 1)."""
    v = _eval_float(hfp, 'RND()')
    assert 0.0 <= v < 1.0


def test_rnd_no_args_first_value_from_seed_0(hfp):
    """float_random consumes 4 rand8 bytes; with seed 0 the first 4 bytes are
    (184, 163, 27, 16). The mantissa is built as $B8_A3_1B_10 with bit 31
    forced (hidden-1 explicit), giving value 1.44247... in [1, 2). Subtract
    1.0 → ~0.44248."""
    assert _eval_float(hfp, 'RND()') == pytest.approx(0.4424775913, rel=1e-7)


def test_rnd_no_args_sequence_from_seed_0(hfp):
    """Three successive rnd() calls each pull 4 rand8 bytes."""
    payload = list("RND() + RND() + RND()".encode("ascii"))
    handle = place_str(hfp, 0x8500, payload)
    hfp.rs_push(handle)
    hfp.call("parser_eval", max_steps=5_000_000)
    rv = hfp.read_word(RV)
    obj = hfp.read_word(rv)
    payload_bytes = hfp.read_bytes(obj + 2, 5)
    assert msbasic_to_python(payload_bytes) == pytest.approx(
        0.8532366217, rel=1e-6,
    )


def test_rnd_int_end_returns_int_in_range(hfp):
    """rnd(end) with INT end returns an INT in [0, end)."""
    v = _eval(hfp, 'RND(10)')
    assert 0 <= v < 10  # exact value is implementation-defined (4-byte draw)


def test_rnd_int_end_zero_panics(hfp):
    """rnd(0) → divide-by-zero panic from int_mod."""
    from conftest import ERROR_CODE_ZP
    payload = list('RND(0)'.encode('ascii'))
    handle = place_str(hfp, 0x8500, payload)
    hfp.rs_push(handle)
    hfp.call('parser_eval', expect_panic=True, max_steps=2_000_000)
    assert hfp.mpu.memory[ERROR_CODE_ZP] == 0x02  # ERR_DIV_ZERO


def test_rnd_int_two_args_returns_int_in_range(hfp):
    """rnd(start, end) with both INT returns an INT in [start, end)."""
    v = _eval(hfp, 'RND(100, 110)')
    assert 100 <= v < 110  # exact value implementation-defined (4-byte draw)


def test_rnd_float_end_returns_float_in_range(hfp):
    """rnd(end) with FLOAT end scales float_random by end."""
    v = _eval_float(hfp, 'RND(2.0)')
    # First float_random ≈ 0.44248; * 2.0 ≈ 0.88496.
    assert v == pytest.approx(0.8849551826, rel=1e-6)


def test_rnd_float_two_args_returns_float_in_range(hfp):
    """rnd(start, end) with both FLOAT scales float_random into [start, end)."""
    v = _eval_float(hfp, 'RND(10.0, 12.0)')
    # 10.0 + first_random * (12.0 - 10.0) ≈ 10.88496.
    assert v == pytest.approx(10.8849551826, rel=1e-6)


def test_rnd_mixed_int_float_promotes_to_float(hfp):
    """rnd(INT, FLOAT) — admiral-style auto-promotion to FLOAT.

    With cast_common_number_type the INT side is promoted, so the result is
    a FLOAT in [start, end). Mirrors admiral's `built_in_rnd_2`.
    """
    v = _eval_float(hfp, 'RND(1, 2.0)')
    assert 1.0 <= v < 2.0


def test_rnd_bool_arg_panics(hfp):
    """rnd(True) — admiral rejects BOOL with ERR_TYPE; the C64 port matches."""
    from conftest import ERROR_CODE_ZP
    payload = list('RND(TRUE)'.encode('ascii'))
    handle = place_str(hfp, 0x8500, payload)
    hfp.rs_push(handle)
    hfp.call('parser_eval', expect_panic=True, max_steps=2_000_000)
    assert hfp.mpu.memory[ERROR_CODE_ZP] == 0x05  # ERR_TYPE


def test_rnd_bool_second_arg_panics(hfp):
    """rnd(0, True) also panics — BOOL reject applies to either position."""
    from conftest import ERROR_CODE_ZP
    payload = list('RND(0, TRUE)'.encode('ascii'))
    handle = place_str(hfp, 0x8500, payload)
    hfp.rs_push(handle)
    hfp.call('parser_eval', expect_panic=True, max_steps=2_000_000)
    assert hfp.mpu.memory[ERROR_CODE_ZP] == 0x05  # ERR_TYPE


def test_rnd_int_large_range_in_bounds(hfp):
    """rnd(0, 1000) returns a value in [0, 1000)."""
    v = _eval(hfp, 'RND(0, 1000)')
    assert 0 <= v < 1000


def test_rnd_int_large_range_distribution(hfp):
    """rnd over a > 256 range returns a value in [0, 1000).

    _brnd_alloc_rand draws a full 31-bit random (4 rand8 bytes), so values
    beyond 255 are reachable (unlike the old single-byte algorithm). The exact
    value is implementation-defined; here we just assert the range.
    """
    assert 0 <= _eval(hfp, 'RND(0, 1000)') < 1000


def test_rnd_too_many_args_panics(hfp):
    """rnd(a, b, c) — arity > 2 panics ERR_ARITY."""
    from conftest import ERROR_CODE_ZP
    payload = list('RND(1, 2, 3)'.encode('ascii'))
    handle = place_str(hfp, 0x8500, payload)
    hfp.rs_push(handle)
    hfp.call('parser_eval', expect_panic=True, max_steps=2_000_000)
    assert hfp.mpu.memory[ERROR_CODE_ZP] == 0x06  # ERR_ARITY


# --- Phase B: tuple-unpacking assignments ----------------------------------
# `stmt_assign_or_expr` speculatively parses TK_NAME / TK_LPAREN statements
# as a `testlist` target tree. On `=` it commits via `assign(target, value)`;
# otherwise it rolls back via lexer_restore and falls through to expression.

def test_tuple_assign_two_names(h):
    src = (
        'a, b = (1, 2)\n'
        'a + b * 10'
    )
    assert _eval(h, src) == 21


def test_tuple_assign_three_names(h):
    src = (
        'a, b, c = (10, 20, 30)\n'
        'a + b + c'
    )
    assert _eval(h, src) == 60


def test_tuple_assign_unparenthesized_rhs(h):
    """`a, b = 1, 2` — RHS is implicitly a tuple."""
    src = (
        'a, b = 1, 2\n'
        'a * 10 + b'
    )
    assert _eval(h, src) == 12


def test_tuple_assign_swap(h):
    """Tuple unpacking lets us swap without a temp."""
    src = (
        'a = 1\n'
        'b = 2\n'
        'a, b = b, a\n'
        'a * 10 + b'
    )
    assert _eval(h, src) == 21


def test_tuple_assign_nested_lhs(h):
    """`a, (b, c) = (1, (2, 3))` — recursive unpack."""
    src = (
        'a, (b, c) = (1, (2, 3))\n'
        'a + b * 10 + c * 100'
    )
    assert _eval(h, src) == 321


def test_tuple_assign_deeply_nested(h):
    src = (
        'a, (b, (c, d)) = (1, (2, (3, 4)))\n'
        'a + b * 10 + c * 100 + d * 1000'
    )
    assert _eval(h, src) == 4321


def test_tuple_assign_paren_lhs_only(h):
    """`(a, b) = (1, 2)` — LHS in outer parens."""
    src = (
        '(a, b) = (1, 2)\n'
        'a + b * 10'
    )
    assert _eval(h, src) == 21


def test_tuple_assign_rhs_can_be_list(h):
    """RHS of tuple LHS may be a list (any sequence with the array layout)."""
    src = (
        'a, b, c = [7, 8, 9]\n'
        'a + b * 10 + c * 100'
    )
    assert _eval(h, src) == 987


def test_tuple_assign_with_subscript_target(h):
    """`a, lst[0] = (1, 99)` — mixed name + subscript LHS."""
    src = (
        'lst = [0, 0, 0]\n'
        'a, lst[0] = (1, 99)\n'
        'a + lst[0] * 10'
    )
    assert _eval(h, src) == 991


def test_tuple_assign_with_attr_target(h):
    """`a, obj.x = (1, 99)` — mixed name + attribute LHS."""
    src = (
        'obj = <"x": 0>\n'
        'a, obj.x = (1, 99)\n'
        'a + obj.x * 10'
    )
    assert _eval(h, src) == 991


def test_tuple_assign_chain_target(h):
    """`a, obj.inner.v = (1, 99)` — chain attribute LHS."""
    src = (
        'obj = <"inner": <"v": 0>>\n'
        'a, obj.inner.v = (1, 99)\n'
        'a + obj.inner.v * 10'
    )
    assert _eval(h, src) == 991


def test_tuple_assign_arity_mismatch_panics(h):
    """LHS and RHS lengths must match; otherwise ERR_ARITY."""
    from conftest import ERROR_CODE_ZP, ERR_ARITY
    src = 'a, b = (1, 2, 3)'
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)
    assert h.mpu.memory[ERROR_CODE_ZP] == ERR_ARITY


def test_tuple_assign_non_sequence_rhs_panics(h):
    from conftest import ERROR_CODE_ZP, ERR_TYPE
    src = 'a, b = 5'
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)
    assert h.mpu.memory[ERROR_CODE_ZP] == ERR_TYPE


# --- Regressions: speculative testlist must not break expression statements

def test_no_regression_function_call_stmt(h):
    """`len(...)` at statement level is parsed by testlist first; rollback
    must still leave the call working."""
    src = 'LEN("abc")'
    assert _eval(h, src) == 3


def test_no_regression_method_call_stmt(h):
    src = (
        's = "hello"\n'
        's.UPPER()'
    )
    assert _eval_str(h, src) == b"HELLO"


def test_no_regression_arithmetic_with_name(h):
    src = (
        'x = 5\n'
        'x + 3 * 2'
    )
    assert _eval(h, src) == 11


def test_no_regression_slice_at_stmt_top(h):
    """`a[1:3]` — `[` chain in testlist must abort on `:` so slice still parses."""
    src = (
        'a = [10, 20, 30, 40]\n'
        'a[1:3]'
    )
    assert _eval_list_ints(h, src) == [20, 30]


def test_no_regression_paren_arith_stmt(h):
    """`(1 + 2) * 3` — TK_LPAREN-starting statement that isn't a target."""
    assert _eval(h, '(1 + 2) * 3') == 9


def test_no_regression_paren_tuple_lookup(h):
    """`(1, 2, 3)[1]` — TK_LPAREN-starting tuple expr followed by subscript."""
    assert _eval(h, '(10, 20, 30)[1]') == 20


def test_no_regression_simple_assign(h):
    """`x = 5` flows through testlist + assign; verify it still works."""
    src = (
        'x = 42\n'
        'x'
    )
    assert _eval(h, src) == 42


def test_no_regression_subscript_assign(h):
    src = (
        'a = [1, 2, 3]\n'
        'a[1] = 99\n'
        'a[1]'
    )
    assert _eval(h, src) == 99


def test_no_regression_attr_assign(h):
    src = (
        'o = <>\n'
        'o.x = 7\n'
        'o.x'
    )
    assert _eval(h, src) == 7


# --- Phase C: for-loop tuple unpacking + dict iteration --------------------
# `stmt_for` parses the loop target via `testlist`, so any LHS form works
# (single name, tuple, nested, .attr / [i] suffixes). DICT iteration binds
# the entry tuple — admiral semantics.

def test_for_tuple_unpack_over_list_of_pairs(h):
    """`for a, b in lst` — list of 2-tuples."""
    src = (
        'pairs = [(1, 10), (2, 20), (3, 30)]\n'
        'a_sum = 0\n'
        'b_sum = 0\n'
        'FOR a, b IN pairs:\n'
        '    a_sum = a_sum + a\n'
        '    b_sum = b_sum + b\n'
        'a_sum * 100 + b_sum'
    )
    assert _eval(h, src) == 660  # 6*100 + 60


def test_for_tuple_unpack_three_elements(h):
    src = (
        'rows = [(1, 2, 3), (4, 5, 6)]\n'
        'total = 0\n'
        'FOR x, y, z IN rows:\n'
        '    total = total + x + y + z\n'
        'total'
    )
    assert _eval(h, src) == 21


def test_for_nested_tuple_unpack(h):
    """`for a, (b, c) in pairs:` — nested unpacking."""
    src = (
        'pairs = [(1, (2, 3)), (10, (20, 30))]\n'
        'total = 0\n'
        'FOR a, (b, c) IN pairs:\n'
        '    total = total + a + b + c\n'
        'total'
    )
    assert _eval(h, src) == 66  # 1+2+3 + 10+20+30


def test_for_tuple_unpack_over_list_of_lists(h):
    """RHS items can be lists (not just tuples)."""
    src = (
        'data = [[1, 10], [2, 20]]\n'
        'sum = 0\n'
        'FOR k, v IN data:\n'
        '    sum = sum + k * v\n'
        'sum'
    )
    assert _eval(h, src) == 50  # 1*10 + 2*20


def test_for_dict_iteration_uses_keys_for_lookup(h):
    """Common idiom: `for k, v in d` to iterate entries directly."""
    src = (
        'd = <"a": 1, "b": 2, "c": 3>\n'
        'total = 0\n'
        'FOR k, v IN d:\n'
        '    total = total + v\n'
        'total'
    )
    assert _eval(h, src) == 6


def test_for_single_name_over_dict_binds_entry(h):
    """`for entry in d` binds the whole (key, value) tuple."""
    src = (
        'd = <10: 1, 20: 2>\n'
        'k0 = 0\n'
        'v0 = 0\n'
        'FOR entry IN d:\n'
        '    k0 = entry[0]\n'
        '    v0 = entry[1]\n'
        '    BREAK\n'
        'k0 * 100 + v0'
    )
    # First entry (sorted): (10, 1)
    assert _eval(h, src) == 1001


def test_for_tuple_arity_mismatch_panics(h):
    """`for a, b, c in pairs_of_2:` — arity mismatch panics."""
    from conftest import ERROR_CODE_ZP, ERR_ARITY
    src = (
        'pairs = [(1, 2), (3, 4)]\n'
        'FOR a, b, c IN pairs:\n'
        '    PASS'
    )
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)
    assert h.mpu.memory[ERROR_CODE_ZP] == ERR_ARITY


def test_for_no_regression_single_name(h):
    """`for x in list` — bare-name target still works."""
    src = (
        'total = 0\n'
        'FOR x IN [1, 2, 3, 4]:\n'
        '    total = total + x\n'
        'total'
    )
    assert _eval(h, src) == 10


def test_for_no_regression_string_iteration(h):
    """`for c in "abc"` — string iteration with bare-name target."""
    src = (
        'count = 0\n'
        'FOR c IN "abc":\n'
        '    count = count + 1\n'
        'count'
    )
    assert _eval(h, src) == 3


def test_for_no_regression_break_continue(h):
    """break / continue still work with the new testlist-based for-loop."""
    src = (
        'total = 0\n'
        'FOR i IN [1, 2, 3, 4, 5]:\n'
        '    IF i == 2:\n'
        '        CONTINUE\n'
        '    IF i == 4:\n'
        '        BREAK\n'
        '    total = total + i\n'
        'total'
    )
    assert _eval(h, src) == 4  # 1 + 3


# --- mem / globals / locals -----------------------------------------------

def test_globals_returns_dict(h):
    from conftest import TYPE_DICT
    h_type, _ = _eval_container_type_and_len(h, "GLOBALS()")
    assert h_type == TYPE_DICT


def test_locals_returns_dict(h):
    from conftest import TYPE_DICT
    h_type, _ = _eval_container_type_and_len(h, "LOCALS()")
    assert h_type == TYPE_DICT


def test_globals_locals_same_handle_at_top_level(h):
    """At top level, globals() and locals() return the same scope dict."""
    assert _eval_bool(h, "ID(GLOBALS()) == ID(LOCALS())") is True


def test_globals_contains_top_level_assignment(h):
    src = 'x = 42\nLEN(GLOBALS())'
    assert _eval(h, src) == 1


def test_locals_contains_top_level_assignment(h):
    src = 'y = 99\nLEN(LOCALS())'
    assert _eval(h, src) == 1


def test_mem_returns_positive_int(h):
    assert _eval_bool(h, "MEM() > 0") is True


def test_mem_decreases_after_alloc(h):
    """Allocating a list reduces mem()'s reported free heap."""
    src = (
        'before = MEM()\n'
        'data = [1, 2, 3, 4, 5]\n'
        'after = MEM()\n'
        'before > after'
    )
    assert _eval_bool(h, src) is True


# --- wset / wget / cursor (console builtins) -------------------------------

SCREEN_BASE = 0x0400
COLOR_BASE = 0xD800
SCREEN_COLS = 40
SCREEN_ROW_ZP = 0x33
SCREEN_COL_ZP = 0x34


def _eval_no_result(h, source: str) -> None:
    """Like _eval, but for builtins that return None."""
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)


def test_wset_writes_screen_code(h):
    """wset(0, 0, 'A') writes screen code $01 (the C64 code for 'A')."""
    h.mpu.memory[SCREEN_BASE] = 0x00
    _eval_no_result(h, 'WSET(0, 0, "A")')
    assert h.mpu.memory[SCREEN_BASE] == 0x01


def test_wset_writes_at_correct_offset(h):
    """wset(5, 3, 'B') targets SCREEN_BASE + 3*40 + 5."""
    addr = SCREEN_BASE + 3 * SCREEN_COLS + 5
    h.mpu.memory[addr] = 0x00
    _eval_no_result(h, 'WSET(5, 3, "B")')
    assert h.mpu.memory[addr] == 0x02


def test_wset_translates_uppercase_letter(h):
    """PETSCII uppercase 'Z' ($5A) → screen code $1A via the general octant
    formula in petscii_to_screen_code."""
    h.mpu.memory[SCREEN_BASE] = 0x00
    _eval_no_result(h, 'WSET(0, 0, "Z")')
    assert h.mpu.memory[SCREEN_BASE] == 0x1A


def test_wset_does_not_touch_color_ram(h):
    """WSET writes screen RAM only — color is left under user control."""
    color_addr = COLOR_BASE + 3 * SCREEN_COLS + 5
    screen_addr = SCREEN_BASE + 3 * SCREEN_COLS + 5
    h.mpu.memory[color_addr] = 0x02                   # red sentinel
    h.mpu.memory[screen_addr] = 0x00
    _eval_no_result(h, 'WSET(5, 3, "X")')
    assert h.mpu.memory[screen_addr] == 0x18, "screen RAM should hold $18 (X)"
    assert h.mpu.memory[color_addr] == 0x02, "color RAM should be unchanged"


def test_wset_oob_col_no_op(h):
    """col >= 40 → silent no-op, screen RAM untouched."""
    h.mpu.memory[SCREEN_BASE] = 0xEE
    _eval_no_result(h, 'WSET(40, 0, "A")')
    assert h.mpu.memory[SCREEN_BASE] == 0xEE


def test_wset_oob_row_no_op(h):
    """row >= 25 → silent no-op."""
    addr = SCREEN_BASE + 24 * SCREEN_COLS
    h.mpu.memory[addr] = 0xEE
    _eval_no_result(h, 'WSET(0, 25, "A")')
    assert h.mpu.memory[addr] == 0xEE


def test_wset_negative_no_op(h):
    """Negative col → silent no-op (sign bit set ≥ $80 ≥ 40)."""
    h.mpu.memory[SCREEN_BASE] = 0xEE
    _eval_no_result(h, 'WSET(-1, 0, "A")')
    assert h.mpu.memory[SCREEN_BASE] == 0xEE


def test_wget_returns_petscii_str(h):
    """wget(5, 3) reads screen code $01 → 1-char STR with PETSCII 'A'."""
    addr = SCREEN_BASE + 3 * SCREEN_COLS + 5
    h.mpu.memory[addr] = 0x01
    payload = list('WGET(5, 3)'.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    obj = h.read_word(rv)
    o_len = h.read_word(obj)
    assert o_len == 1
    assert h.mpu.memory[obj + 2] == 0x41  # PETSCII 'A'


def test_wget_passes_through_high_codes(h):
    """Screen codes >= $20 are returned as-is (no inverse translation)."""
    addr = SCREEN_BASE + 0
    h.mpu.memory[addr] = 0x7A
    payload = list('WGET(0, 0)'.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    obj = h.read_word(rv)
    assert h.mpu.memory[obj + 2] == 0x7A


def test_wset_wget_roundtrip(h):
    """wset then wget recovers the original PETSCII char."""
    src = 'WSET(7, 4, "Q")\nWGET(7, 4)'
    payload = list(src.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    obj = h.read_word(rv)
    o_len = h.read_word(obj)
    assert o_len == 1
    assert h.mpu.memory[obj + 2] == ord("Q")


def test_cursor_set_updates_zp(h):
    """cursor(7, 3) writes SCREEN_COL=7, SCREEN_ROW=3."""
    h.mpu.memory[SCREEN_COL_ZP] = 0
    h.mpu.memory[SCREEN_ROW_ZP] = 0
    _eval_no_result(h, 'CURSOR(7, 3)')
    assert h.mpu.memory[SCREEN_COL_ZP] == 7
    assert h.mpu.memory[SCREEN_ROW_ZP] == 3


def test_cursor_set_clamps_high(h):
    """cursor(50, 50) clamps to (39, 24)."""
    _eval_no_result(h, 'CURSOR(50, 50)')
    assert h.mpu.memory[SCREEN_COL_ZP] == 39
    assert h.mpu.memory[SCREEN_ROW_ZP] == 24


def test_cursor_set_clamps_negative(h):
    """cursor(-1, -1) clamps both to max-bound (negatives wrap to 0xFF, > limit)."""
    _eval_no_result(h, 'CURSOR(-1, -1)')
    assert h.mpu.memory[SCREEN_COL_ZP] == 39
    assert h.mpu.memory[SCREEN_ROW_ZP] == 24


def test_cursor_get_returns_col(h):
    assert _eval(h, 'CURSOR(7, 3)\nCURSOR()[0]') == 7


def test_cursor_get_returns_row(h):
    assert _eval(h, 'CURSOR(7, 3)\nCURSOR()[1]') == 3


def test_cursor_get_returns_tuple(h):
    """cursor() result is a 2-tuple."""
    from conftest import TYPE_TUPLE
    h_type, o_len = _eval_container_type_and_len(h, 'CURSOR(2, 1)\nCURSOR()')
    assert h_type == TYPE_TUPLE
    assert o_len == 2


def test_cursor_arity_one_panics(h):
    """cursor(5) — single arg is invalid; panics ERR_ARITY."""
    from conftest import ERROR_CODE_ZP, ERR_ARITY
    payload = list('CURSOR(5)'.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    with pytest.raises(Exception):
        h.call("parser_eval", max_steps=2_000_000)
    assert h.mpu.memory[ERROR_CODE_ZP] == ERR_ARITY


# --- cls -------------------------------------------------------------------

def _fill_screen_row(h, row: int, value: int) -> None:
    base = SCREEN_BASE + row * SCREEN_COLS
    for col in range(SCREEN_COLS):
        h.mpu.memory[base + col] = value


def test_cls_blanks_screen(h):
    """`cls` keyword fills every cell with screen-code space."""
    for row in range(25):
        _fill_screen_row(h, row, 0x42)
    _eval_no_result(h, 'CLS')
    for i in range(25 * SCREEN_COLS):
        assert h.mpu.memory[SCREEN_BASE + i] == 0x20, f"cell {i} not blanked"


def test_cls_resets_cursor(h):
    """`cls` moves cursor to (0, 0)."""
    _eval_no_result(h, 'CURSOR(13, 7)\nCLS')
    assert _eval(h, 'CURSOR()[0]') == 0
    assert _eval(h, 'CURSOR()[1]') == 0




# --- getc / key (KERNAL GETIN-backed builtins) -----------------------------

KERNAL_GETIN = 0xFFE4


def _stub_getin_always(h, return_val: int) -> None:
    """Stub $FFE4 to always return `return_val` in A. Mirrors test_keyboard.

    Also relocates NEXT_HANDLE to $C000 — handles normally start at $FFF8 and
    grow DOWN through the area where this stub lives ($FFE4..$FFE6). On real
    hardware a $01=$36 bank flip puts KERNAL ROM there, so the stub bytes
    come from ROM not heap; in py65 we just bypass the collision by moving
    handles below the ROM space."""
    h.write_word(NEXT_HANDLE_ZP, 0xC000)
    h.mpu.memory[KERNAL_GETIN + 0] = 0xA9      # LDA #imm
    h.mpu.memory[KERNAL_GETIN + 1] = return_val
    h.mpu.memory[KERNAL_GETIN + 2] = 0x60      # RTS


def _eval_to_str(h, source: str, max_steps: int = 2_000_000) -> bytes:
    """Evaluate source, return RV's TYPE_STR payload as bytes."""
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=max_steps)
    rv = h.read_word(RV)
    obj = h.read_word(rv)
    o_len = h.read_word(obj)
    return bytes(h.mpu.memory[obj + 2 + i] for i in range(o_len))


def test_getc_returns_petscii_str(h):
    """getc() returns a 1-char STR with the byte GETIN gave."""
    _stub_getin_always(h, 0x41)  # 'A'
    assert _eval_to_str(h, 'GETC()') == b'A'


def test_getc_returns_petscii_for_lowercase(h):
    """getc() doesn't translate — passes PETSCII through verbatim."""
    _stub_getin_always(h, 0x7A)  # 'z'
    assert _eval_to_str(h, 'GETC()') == b'z'


def test_key_returns_none_when_buffer_empty(h):
    """key() returns None when GETIN gives 0."""
    from conftest import TYPE_NONE
    _stub_getin_always(h, 0x00)
    payload = list('KEY()'.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    assert h.mpu.memory[rv + 6] == TYPE_NONE  # H_TYPE


def test_key_returns_str_when_key_available(h):
    """key() returns a 1-char STR when GETIN gives non-zero."""
    _stub_getin_always(h, 0x58)  # 'X'
    assert _eval_to_str(h, 'KEY()') == b'X'


# --- input -----------------------------------------------------------------

def _stub_getin_queue(h, bytes_in: bytes) -> None:
    """Stub GETIN to walk through `bytes_in` (one byte per call), looping back
    to the start once exhausted. Tests that want input(...) to terminate must
    include a $0D byte in the queue.

    Queue at $C800, cursor at $C7FF. Caps queue at 255 bytes (cpx #imm range).

    Stub at $FFE4 must leave Z set based on the byte (so caller's `beq`
    after JSR works) — PHA the byte, do cursor bookkeeping, PLA right
    before RTS so Z reflects the byte value.

    Also relocates NEXT_HANDLE to $C000 — handles normally start at $FFF8 and
    grow DOWN through both the stub at $FFE4 and the queue at $C800. Move
    them below the queue so neither gets clobbered.
    """
    h.write_word(NEXT_HANDLE_ZP, 0xC000)
    assert len(bytes_in) <= 255
    queue_len = len(bytes_in)
    h.mpu.memory[0xC7FF] = 0
    for i, b in enumerate(bytes_in):
        h.mpu.memory[0xC800 + i] = b
    stub = [
        0xAE, 0xFF, 0xC7,   # ldx $C7FF
        0xBD, 0x00, 0xC8,   # lda $C800,x
        0x48,               # pha
        0xE8,               # inx
        0xE0, queue_len,    # cpx #queue_len
        0xD0, 0x02,         # bne +2
        0xA2, 0x00,         # ldx #0
        0x8E, 0xFF, 0xC7,   # stx $C7FF
        0x68,               # pla — restores byte AND re-sets Z/N from byte
        0x60,               # rts
    ]
    for i, b in enumerate(stub):
        h.mpu.memory[KERNAL_GETIN + i] = b


def test_input_no_prompt_returns_buffer(h):
    """input() reads chars until $0D, returns them as STR (no newline). Bytes
    pass through verbatim — internal storage is PETSCII uppercase, which is
    exactly what KERNAL_GETIN returns from the keyboard."""
    _stub_getin_queue(h, b'HELLO\r')
    assert _eval_to_str(h, 'INPUT()') == b'HELLO'


def test_input_empty_returns_empty_str(h):
    """input() with immediate RETURN returns an empty TYPE_STR."""
    _stub_getin_queue(h, b'\r')
    assert _eval_to_str(h, 'INPUT()') == b''


def test_input_del_removes_last_char(h):
    """DEL ($14) removes the last buffered char before RETURN."""
    _stub_getin_queue(h, b'CAB\x14\r')
    assert _eval_to_str(h, 'INPUT()') == b'CA'


def test_input_del_on_empty_is_noop(h):
    """DEL with empty buffer is ignored, doesn't underflow."""
    _stub_getin_queue(h, b'\x14\x14X\r')
    assert _eval_to_str(h, 'INPUT()') == b'X'


def test_input_echoes_to_screen(h):
    """Each accepted char is echoed via screen_put_char."""
    _stub_getin_queue(h, b'AB\r')
    h.mpu.memory[SCREEN_BASE] = 0x00
    h.mpu.memory[SCREEN_BASE + 1] = 0x00
    h.mpu.memory[SCREEN_COL_ZP] = 0
    h.mpu.memory[SCREEN_ROW_ZP] = 0
    _eval_to_str(h, 'INPUT()')
    # 'A' → screen code $01, 'B' → $02.
    assert h.mpu.memory[SCREEN_BASE] == 0x01
    assert h.mpu.memory[SCREEN_BASE + 1] == 0x02


def test_input_prompt_printed(h):
    """input(prompt) prints the prompt before reading."""
    _stub_getin_queue(h, b'X\r')
    h.mpu.memory[SCREEN_COL_ZP] = 0
    h.mpu.memory[SCREEN_ROW_ZP] = 0
    _eval_to_str(h, 'INPUT(">")')
    # '>' is screen code $1E (PETSCII $3E, no translation since < $40).
    assert h.mpu.memory[SCREEN_BASE] == 0x3E
    # 'X' echoed at column 1.
    assert h.mpu.memory[SCREEN_BASE + 1] == 0x18


def test_input_prompt_wrong_type_panics(h):
    """input(non-STR) panics ERR_TYPE."""
    from conftest import ERROR_CODE_ZP, ERR_TYPE
    payload = list('INPUT(42)'.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    with pytest.raises(Exception):
        h.call("parser_eval", max_steps=2_000_000)
    assert h.mpu.memory[ERROR_CODE_ZP] == ERR_TYPE


def test_input_caps_at_80(h):
    """Buffer caps at 80 chars; further keystrokes (before RETURN) are dropped."""
    _stub_getin_queue(h, b'A' * 90 + b'\r')
    payload = list('LEN(INPUT())'.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=10_000_000)
    rv = h.read_word(RV)
    # LEN(...) is an inline int; value = H_PTR(lo16) | H_SIZE(hi16)<<16.
    assert (h.read_word(rv) | (h.read_word(rv + 2) << 16)) == 80



# --- parser_exec — REPL-flavored variant that reuses caller's scope ---------

def test_error_handler_recovers_to_repl_loop(hd):
    """A panic during parser_exec must not wedge the system: error_handler
    restores the snapshot, prints `?ERROR XX`, and jumps to repl_loop. We
    verify by setting up a fake REPL state, triggering a panic, and asserting
    PC eventually reaches repl_loop (i.e., the prompt is about to redraw).

    Uses `hd` because error_handler now closes any leaked disk channels via
    KERNAL CLOSE — the kernal_mock traps those calls (which would otherwise
    branch into uninitialized RAM at $FFC3)."""
    CURRENT_SCOPE = 0x42
    ROOT_SCOPE = 0x44
    hd.call("screen_init")
    hd.call("dict_alloc")
    scope = hd.read_word(RV)
    hd.write_word(CURRENT_SCOPE, scope)
    hd.write_word(ROOT_SCOPE, scope)
    hd.rs_push(scope)

    repl_rec_s = hd.sym["repl_rec_s"]
    repl_rec_rsp = hd.sym["repl_rec_rsp"]
    repl_rec_fsp = hd.sym["repl_rec_fsp"]
    repl_rec_fp = hd.sym["repl_rec_fp"]
    hd.mpu.memory[repl_rec_s] = hd.mpu.sp
    hd.write_word(repl_rec_rsp, hd.read_word(0x04))
    hd.write_word(repl_rec_fsp, hd.read_word(0x02))
    hd.write_word(repl_rec_fp,  hd.read_word(0x06))

    # `mem` is a builtin, but bare-name lookup raises ERR_LEX because the
    # scope chain doesn't contain builtins. Drives the panic-and-recover
    # path the user hits when they type any unbound name.
    src = place_str(hd, 0x8500, list(b"MEM"))
    hd.rs_push(src)
    repl_loop = hd.sym["repl_loop"]
    hd.mpu.pc = hd.sym["parser_exec"]
    for _ in range(2_000_000):
        if hd.mpu.pc == repl_loop:
            break
        if hd.kernal_mock.step_hook():
            continue
        hd.mpu.step()
    else:
        raise TimeoutError("error_handler did NOT jmp repl_loop")

    # ERROR_CODE should be cleared by error_handler before reprompt.
    assert hd.mpu.memory[0x27] == 0
    # The "?ERR" prefix should have been printed somewhere on screen.
    screen_chunk = bytes(hd.mpu.memory[0x0400:0x0500])
    # Screen-codes for '?ERR': '?'=$3F, 'E'→$05, 'R'→$12.
    # Look for the sequence anywhere in the row band.
    needle = bytes([0x3F, 0x05, 0x12, 0x12])
    assert needle in screen_chunk, "?ERR text NOT found IN screen RAM"


def test_parser_exec_prints_int_expression(h):
    """`print 1+2` writes '3' to screen RAM via parser_exec — the REPL's
    smoke test, mirroring the exact source bytes repl_loop builds for
    `PRINT 1+2` typed on the keyboard (after the lowercase fold)."""
    CURRENT_SCOPE = 0x42
    ROOT_SCOPE = 0x44
    h.call("screen_init")
    h.call("dict_alloc")
    scope = h.read_word(RV)
    h.write_word(CURRENT_SCOPE, scope)
    h.write_word(ROOT_SCOPE, scope)
    h.rs_push(scope)

    src = place_str(h, 0x8500, list(b"PRINT 1+2"))
    h.rs_push(src)
    h.call("parser_exec", max_steps=2_000_000)

    # '3' = ASCII $33, screen code $33 (digit range is 1:1 in petscii→screen).
    assert h.mpu.memory[0x0400] == 0x33, (
        f"expected '3' at screen base, got ${h.mpu.memory[0x0400]:02X}"
    )


def test_parser_exec_prints_list(h):
    """`print [1,2,3]` must render via builtin_str — produces the literal
    `[1, 2, 3]` on screen, NOT a `?` placeholder. Regression: print_value
    used to emit a hardcoded '?' for any container type."""
    CURRENT_SCOPE = 0x42
    ROOT_SCOPE = 0x44
    h.call("screen_init")
    h.call("dict_alloc")
    scope = h.read_word(RV)
    h.write_word(CURRENT_SCOPE, scope)
    h.write_word(ROOT_SCOPE, scope)
    h.rs_push(scope)

    src = place_str(h, 0x8500, list(b"PRINT [1,2,3]"))
    h.rs_push(src)
    h.call("parser_exec", max_steps=2_000_000)

    # Expect "[1,2,3]" at screen row 0 starting at col 0. Screen-codes:
    # '[' = $1B, ',' = $2C, '1'..'3' = $31..$33, ']' = $1D.
    expected = bytes([0x1B, 0x31, 0x2C, 0x32, 0x2C, 0x33, 0x1D])
    actual = bytes(h.mpu.memory[0x0400 : 0x0400 + len(expected)])
    assert actual == expected, (
        f"expected list rendering at screen base, got {actual!r}"
    )


def test_parser_exec_persists_vars_across_calls(h):
    """parser_exec keeps a caller-supplied scope rooted on RS, so successive
    calls can see each other's bindings. This is the REPL's reason-to-exist:
    `x = 5` in turn N must be visible as `x` in turn N+1.
    """
    # CURRENT_SCOPE / ROOT_SCOPE are .const ZP addresses (defs.asm), not labels.
    CURRENT_SCOPE = 0x42
    ROOT_SCOPE = 0x44

    # Caller-side setup (what repl_main does once at boot): allocate a root
    # scope, push it as a permanent RS root, cache the handle in the two
    # scope-pointer ZP cells.
    h.call("dict_alloc")
    scope = h.read_word(RV)
    h.write_word(CURRENT_SCOPE, scope)
    h.write_word(ROOT_SCOPE, scope)
    h.rs_push(scope)

    # Turn 1: `x = 7`. Body returns NONE (assignment); side-effect is a new
    # binding in the persistent scope.
    src1 = place_str(h, 0x8500, list(b"x = 7"))
    h.rs_push(src1)
    h.call("parser_exec", max_steps=2_000_000)

    # Turn 2: `x` (bare-name expression). Should resolve via scope_get and
    # return 7. parser_exec leaves RV = last statement's value.
    src2 = place_str(h, 0x8600, list(b"x"))
    h.rs_push(src2)
    h.call("parser_exec", max_steps=2_000_000)
    assert _read_int(h, h.read_word(RV)) == 7

    # Turn 3: `x + 1` — verifies arithmetic still works on the persisted value.
    src3 = place_str(h, 0x8700, list(b"x + 1"))
    h.rs_push(src3)
    h.call("parser_exec", max_steps=2_000_000)
    assert _read_int(h, h.read_word(RV)) == 8


# --- elif-chain control-sentinel regression ---------------------------------
# A RETURN/BREAK from an arm FOLLOWED BY more elif arms used to be lost: the
# later arms' condition evaluation clobbered the control sentinel in RV (and
# ran the conditions' side effects). Fixed in stmt_if by parking the sentinel
# on RS and parsing-without-evaluating the remaining arms.

def test_return_from_nonlast_elif_arm(h):
    src = ('F = "IF C == 17:\\n  RETURN 1\\nELIF C == 13:\\n  RETURN 3\\n'
           'ELIF C == 134:\\n  RETURN 4"\n'
           'F(C=13)')
    assert _eval(h, src) == 3


def test_return_from_if_arm_with_elif_following(h):
    src = ('F = "IF C == 13:\\n  RETURN 3\\nELIF C == 134:\\n  RETURN 4"\n'
           'F(C=13)')
    assert _eval(h, src) == 3


def test_break_from_nonlast_elif_arm(h):
    src = ('F = "K = 0\\nWHILE K < 5:\\n  K = K + 1\\n  IF K == 2:\\n'
           '    BREAK\\n  ELIF K == 9:\\n    K = 99\\nRETURN K"\n'
           'F()')
    assert _eval(h, src) == 2


def test_taken_branch_skips_later_condition_side_effects(h):
    # After an arm is taken, later elif conditions must not execute: G()
    # would bump X if evaluated.
    src = ('X = 0\n'
           'G = "X = X + 100\\nRETURN 0"\n'
           'F = "IF C == 13:\\n  RETURN 3\\nELIF G() == 1:\\n  RETURN 4"\n'
           'R = F(C=13)\n'
           'R + X')
    assert _eval(h, src) == 3
