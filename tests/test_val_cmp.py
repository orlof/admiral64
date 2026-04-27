"""Tests for val_cmp — generic 3-way comparison.

Returns A = $FF (-1) if a<b, $00 if a==b, $01 if a>b. Both args consumed.

Dispatch order (matches Admiral's val_cmp at stdlib.dasm16:158):
  1. Same handle → 0
  2. Different types → numeric type-tag compare
  3. Same type → per-type body
       int / bool: int_cmp (signed, byte-by-byte from MSB)
       str: byte-wise lexicographic (unsigned)
       tuple / list / dict: element-wise recursion; shorter is less
       none / unknown: 0 (equal)
"""

from __future__ import annotations

from test_int_add import place_int
from test_str import place_str
from test_tuple import place_tuple
from test_list import place_list


def run_cmp(h, a: int, b: int) -> int:
    rsp_initial = h.rsp
    h.rs_push(a)
    h.rs_push(b)
    h.call("val_cmp")
    assert h.rsp == rsp_initial
    result = h.mpu.a
    return result - 256 if result >= 128 else result


# --- Identity short-circuit -------------------------------------------------


def test_same_handle_zero(h):
    a = place_int(h, 0x7800, [0x42])
    assert run_cmp(h, a, a) == 0


def test_int_0_static_eq(h):
    int_0 = h.sym["INT_0"]
    assert run_cmp(h, int_0, int_0) == 0


# --- Type-tag mismatch (numeric ordering by tag) ----------------------------


def test_int_lt_str(h):
    """TYPE_INT ($20) < TYPE_STR ($21) — type-tag order."""
    i = place_int(h, 0x7800, [0x00])
    s = place_str(h, 0x6100, [0x00])
    assert run_cmp(h, i, s) == -1
    assert run_cmp(h, s, i) == 1


def test_int_lt_bool(h):
    """TYPE_INT ($20) < TYPE_BOOL ($22)."""
    i = place_int(h, 0x7800, [0x01])
    true_addr = h.sym["TRUE"]
    assert run_cmp(h, i, true_addr) == -1


# --- TYPE_INT (uses int_cmp tail-call) --------------------------------------


def test_int_eq(h):
    a = place_int(h, 0x7800, [0xE8, 0x03])
    b = place_int(h, 0x6100, [0xE8, 0x03])
    assert run_cmp(h, a, b) == 0


def test_int_lt(h):
    a = place_int(h, 0x7800, [0x01])
    b = place_int(h, 0x6100, [0x02])
    assert run_cmp(h, a, b) == -1


def test_int_gt(h):
    a = place_int(h, 0x7800, [0x02])
    b = place_int(h, 0x6100, [0x01])
    assert run_cmp(h, a, b) == 1


def test_neg_int_lt_pos(h):
    a = place_int(h, 0x7800, [0xFF])  # -1
    b = place_int(h, 0x6100, [0x01])
    assert run_cmp(h, a, b) == -1


# --- TYPE_BOOL (routed through int_cmp) -------------------------------------


def test_false_lt_true(h):
    """FALSE has payload [0], TRUE has payload [1] — both signed-positive."""
    f = h.sym["FALSE"]
    t = h.sym["TRUE"]
    assert run_cmp(h, f, t) == -1
    assert run_cmp(h, t, f) == 1


# --- TYPE_STR (byte-wise lexicographic, unsigned) ---------------------------


def test_str_eq(h):
    a = place_str(h, 0x7800, [0x48, 0x49])
    b = place_str(h, 0x6100, [0x48, 0x49])
    assert run_cmp(h, a, b) == 0


def test_str_lt_at_first_byte(h):
    a = place_str(h, 0x7800, [0x41, 0x42])  # "AB"
    b = place_str(h, 0x6100, [0x42, 0x42])  # "BB"
    assert run_cmp(h, a, b) == -1


def test_str_lt_at_last_byte(h):
    a = place_str(h, 0x7800, [0x41, 0x41])
    b = place_str(h, 0x6100, [0x41, 0x42])
    assert run_cmp(h, a, b) == -1


def test_str_shorter_is_less(h):
    a = place_str(h, 0x7800, [0x41])         # "A"
    b = place_str(h, 0x6100, [0x41, 0x42])   # "AB"
    assert run_cmp(h, a, b) == -1
    assert run_cmp(h, b, a) == 1


def test_str_high_byte_is_unsigned(h):
    """$FF should be greater than $7F (no signed misinterpretation)."""
    a = place_str(h, 0x7800, [0x7F])
    b = place_str(h, 0x6100, [0xFF])
    assert run_cmp(h, a, b) == -1


def test_empty_strings_equal(h):
    a = place_str(h, 0x7800, [])
    b = place_str(h, 0x6100, [])
    assert run_cmp(h, a, b) == 0


# --- TYPE_TUPLE — element-wise recursion ------------------------------------


def test_tuple_eq(h):
    a1 = place_int(h, 0x7800, [0x01])
    b1 = place_int(h, 0x6100, [0x02])
    t1 = place_tuple(h, 0x6200, [a1, b1])

    a2 = place_int(h, 0x6300, [0x01])
    b2 = place_int(h, 0x6400, [0x02])
    t2 = place_tuple(h, 0x6500, [a2, b2])

    assert run_cmp(h, t1, t2) == 0


def test_tuple_lt_at_first_element(h):
    a1 = place_int(h, 0x7800, [0x01])
    b1 = place_int(h, 0x6100, [0x02])
    t1 = place_tuple(h, 0x6200, [a1, b1])

    a2 = place_int(h, 0x6300, [0x05])
    b2 = place_int(h, 0x6400, [0x02])
    t2 = place_tuple(h, 0x6500, [a2, b2])

    assert run_cmp(h, t1, t2) == -1


def test_tuple_shorter_prefix_is_less(h):
    a = place_int(h, 0x7800, [0x01])
    short = place_tuple(h, 0x6100, [a])
    long_ = place_tuple(h, 0x6200, [a, a])
    assert run_cmp(h, short, long_) == -1
    assert run_cmp(h, long_, short) == 1


# --- TYPE_LIST — same recursive shape ---------------------------------------


def test_list_lt_at_last_element(h):
    a1 = place_int(h, 0x7800, [0x01])
    b1 = place_int(h, 0x6100, [0x02])
    L1 = place_list(h, 0x6200, [a1, b1])

    a2 = place_int(h, 0x6300, [0x01])
    b2 = place_int(h, 0x6400, [0x05])
    L2 = place_list(h, 0x6500, [a2, b2])

    assert run_cmp(h, L1, L2) == -1


# --- Mixed: nested compare across container types ---------------------------


def test_nested_tuple_compare(h):
    one_a = place_int(h, 0x7800, [0x01])
    two_a = place_int(h, 0x6100, [0x02])
    inner_a = place_tuple(h, 0x6200, [two_a])
    outer_a = place_tuple(h, 0x6300, [one_a, inner_a])

    one_b = place_int(h, 0x6400, [0x01])
    five_b = place_int(h, 0x6500, [0x05])  # different
    inner_b = place_tuple(h, 0x6600, [five_b])
    outer_b = place_tuple(h, 0x6700, [one_b, inner_b])

    assert run_cmp(h, outer_a, outer_b) == -1


def test_string_keys_sortable(h):
    """Strings of various lengths sort lexicographically with tie-broken by
    length (shorter first)."""
    apple = place_str(h, 0x7800, [ord("a"), ord("p"), ord("p"), ord("l"), ord("e")])
    banana = place_str(h, 0x6100, [ord("b"), ord("a"), ord("n"), ord("a"), ord("n"), ord("a")])
    apple2 = place_str(h, 0x6200, [ord("a"), ord("p"), ord("p"), ord("l"), ord("e")])
    apricot = place_str(h, 0x6300, [ord("a"), ord("p"), ord("r")])

    assert run_cmp(h, apple, banana) == -1
    assert run_cmp(h, apple, apricot) == -1   # 'l' < 'r'
    assert run_cmp(h, apricot, banana) == -1
    assert run_cmp(h, apple, apple2) == 0
