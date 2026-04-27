"""Tests for val_eq — generic equality across types.

val_eq is the type-agnostic equality primitive: handle identity short-circuits,
then type-tag check, then length, then byte-by-byte payload compare. Works for
any leaf type (int, str, bool, none, data). Containers will need their own
recursive comparator on top.

ABI: 2 handles on RS (a deeper, b top). Returns A=$01 if equal, $00 otherwise.
Both args consumed.
"""

from __future__ import annotations

from conftest import TYPE_BOOL, TYPE_NONE
from test_int_add import place_int
from test_str import place_str


def run_val_eq(h, a_handle: int, b_handle: int) -> int:
    rsp_initial = h.rsp
    h.rs_push(a_handle)
    h.rs_push(b_handle)
    h.call("val_eq")
    assert h.rsp == rsp_initial, "val_eq violated stack discipline"
    return h.mpu.a


# --- Handle identity short-circuit ------------------------------------------


def test_same_handle_is_equal(h):
    a = place_int(h, 0x7E00, [0x42])
    assert run_val_eq(h, a, a) == 1


def test_int_0_static_eq_itself(h):
    int_0 = h.sym["INT_0"]
    assert run_val_eq(h, int_0, int_0) == 1


def test_true_eq_true_via_identity(h):
    true_addr = h.sym["TRUE"]
    assert run_val_eq(h, true_addr, true_addr) == 1


def test_none_eq_none(h):
    none_addr = h.sym["NONE"]
    assert run_val_eq(h, none_addr, none_addr) == 1


# --- Type-tag mismatch fast path --------------------------------------------


def test_int_ne_str_same_bytes(h):
    # Int payload [$41] and str payload [$41] are bytewise identical but
    # different types — must not compare equal.
    a = place_int(h, 0x7E00, [0x41])
    b = place_str(h, 0x6100, [0x41])
    assert run_val_eq(h, a, b) == 0


def test_int_0_ne_false(h):
    # INT_0 is TYPE_INT; FALSE is TYPE_BOOL. Both have payload [0]. Not equal.
    int_0 = h.sym["INT_0"]
    false_addr = h.sym["FALSE"]
    assert run_val_eq(h, int_0, false_addr) == 0


def test_int_0_ne_none(h):
    int_0 = h.sym["INT_0"]
    none_addr = h.sym["NONE"]
    assert run_val_eq(h, int_0, none_addr) == 0


def test_empty_str_ne_none(h):
    # Both have O_LEN=0 — only the type tag distinguishes them.
    empty = place_str(h, 0x7E00, [])
    none_addr = h.sym["NONE"]
    assert run_val_eq(h, empty, none_addr) == 0


# --- Length mismatch --------------------------------------------------------


def test_short_int_ne_long_int(h):
    a = place_int(h, 0x7E00, [0x01])
    b = place_int(h, 0x6100, [0x01, 0x00])  # not a normalized form, but val_eq
                                            # treats representations literally
    assert run_val_eq(h, a, b) == 0


def test_short_str_ne_long_str(h):
    a = place_str(h, 0x7E00, [0x41, 0x42])
    b = place_str(h, 0x6100, [0x41, 0x42, 0x43])
    assert run_val_eq(h, a, b) == 0


# --- Byte-by-byte payload compare -------------------------------------------


def test_int_eq_via_payload_compare(h):
    # Two distinct handles, identical type and payload — must compare equal.
    a = place_int(h, 0x7E00, [0xE8, 0x03])
    b = place_int(h, 0x6100, [0xE8, 0x03])
    assert run_val_eq(h, a, b) == 1


def test_int_ne_at_msb(h):
    a = place_int(h, 0x7E00, [0xE8, 0x03])
    b = place_int(h, 0x6100, [0xE8, 0x04])
    assert run_val_eq(h, a, b) == 0


def test_int_ne_at_lsb(h):
    a = place_int(h, 0x7E00, [0xE8, 0x03])
    b = place_int(h, 0x6100, [0xE9, 0x03])
    assert run_val_eq(h, a, b) == 0


def test_str_eq_payload(h):
    a = place_str(h, 0x7E00, [0x48, 0x49])
    b = place_str(h, 0x6100, [0x48, 0x49])
    assert run_val_eq(h, a, b) == 1


def test_str_ne_payload_first_byte(h):
    a = place_str(h, 0x7E00, [0x48, 0x49])
    b = place_str(h, 0x6100, [0x4A, 0x49])
    assert run_val_eq(h, a, b) == 0


def test_str_ne_payload_last_byte(h):
    a = place_str(h, 0x7E00, [0x48, 0x49])
    b = place_str(h, 0x6100, [0x48, 0x4A])
    assert run_val_eq(h, a, b) == 0


def test_empty_strings_are_equal(h):
    # Length=0 path: byte loop must not run, must return equal.
    a = place_str(h, 0x7E00, [])
    b = place_str(h, 0x6100, [])
    assert run_val_eq(h, a, b) == 1


# --- Singleton sanity -------------------------------------------------------


def test_true_ne_false(h):
    true_addr = h.sym["TRUE"]
    false_addr = h.sym["FALSE"]
    assert run_val_eq(h, true_addr, false_addr) == 0


def test_true_ne_int_1(h):
    # Different type tags; payload byte happens to match.
    true_addr = h.sym["TRUE"]
    int_1 = h.sym["INT_1"]
    assert run_val_eq(h, true_addr, int_1) == 0


def test_static_int_payloads(h):
    # INT_0 vs a freshly-placed [0x00] int: same type, same length, same bytes.
    int_0 = h.sym["INT_0"]
    fresh_zero = place_int(h, 0x7E00, [0x00])
    assert run_val_eq(h, int_0, fresh_zero) == 1


# --- Static-handle metadata sanity ------------------------------------------


def test_singleton_type_tags(h):
    # Verify the statics carry the type tags val_eq depends on.
    H_TYPE_OFFSET = 6
    assert h.mpu.memory[h.sym["TRUE"] + H_TYPE_OFFSET] == TYPE_BOOL
    assert h.mpu.memory[h.sym["FALSE"] + H_TYPE_OFFSET] == TYPE_BOOL
    assert h.mpu.memory[h.sym["NONE"] + H_TYPE_OFFSET] == TYPE_NONE
