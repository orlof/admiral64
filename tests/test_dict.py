"""Tests for dict.asm — TYPE_DICT primitives.

A dict is a sorted array of (key, value) 2-tuples. Lookup is binary search
by key via val_cmp. Reuses TYPE_LIST's underlying array.asm primitives.

Supported key types: int, bool, str, tuple — anything val_cmp orders.
"""

from __future__ import annotations

from conftest import RV, TYPE_DICT, TYPE_TUPLE, FSP_ZP
from test_int_add import (
    H_FLAGS,
    H_PTR,
    H_SIZE,
    H_TYPE,
    O_HEADER,
    O_LEN,
    SIZEOF_HANDLE,
    place_int,
)
from test_str import place_str
from test_tuple import place_tuple


DICT_KEY = 0
DICT_VAL = 1


# --- helpers ----------------------------------------------------------------


def read_dict_pair(h, dict_handle: int, index: int) -> tuple[int, int]:
    """Return (key_handle, value_handle) at the given pair index."""
    obj = h.read_word(dict_handle + H_PTR)
    pair = h.read_word(obj + O_HEADER + 2 * index)
    pair_obj = h.read_word(pair + H_PTR)
    key = h.read_word(pair_obj + O_HEADER + 2 * DICT_KEY)
    val = h.read_word(pair_obj + O_HEADER + 2 * DICT_VAL)
    return key, val


def dict_keys_in_order(h, dict_handle: int) -> list[int]:
    obj = h.read_word(dict_handle + H_PTR)
    n = h.read_word(obj + O_LEN)
    return [read_dict_pair(h, dict_handle, i)[0] for i in range(n)]


def call_dict_set(h, d: int, key: int, value: int) -> None:
    rsp_initial = h.rsp
    h.rs_push(d)
    h.rs_push(key)
    h.rs_push(value)
    h.call("dict_set")
    assert h.rsp == rsp_initial


def call_dict_get(h, d: int, key: int) -> int:
    rsp_initial = h.rsp
    h.rs_push(d)
    h.rs_push(key)
    h.call("dict_get")
    assert h.rsp == rsp_initial
    return h.read_word(RV)


def call_dict_del(h, d: int, key: int) -> None:
    rsp_initial = h.rsp
    h.rs_push(d)
    h.rs_push(key)
    h.call("dict_del")
    assert h.rsp == rsp_initial


def call_dict_len(h, d: int) -> int:
    rsp_initial = h.rsp
    h.rs_push(d)
    h.call("dict_len")
    assert h.rsp == rsp_initial
    return h.mpu.a


# --- dict_alloc -------------------------------------------------------------


def test_dict_alloc_sets_type_tag(h):
    d = h.alloc_dict()
    assert h.mpu.memory[d + H_TYPE] == TYPE_DICT


def test_dict_alloc_is_empty(h):
    d = h.alloc_dict()
    assert call_dict_len(h, d) == 0


# --- dict_get on empty dict returns NONE -----------------------------------


def test_get_missing_returns_none(h):
    d = h.alloc_dict()
    none_addr = h.sym["NONE"]
    key = place_int(h, 0x7800, [0x42])
    assert call_dict_get(h, d, key) == none_addr


# --- single-entry insert + lookup -------------------------------------------


def test_set_then_get(h):
    d = h.alloc_dict()
    h.rs_push(d)
    key = h.alloc_int(1)
    key_obj = h.read_word(key + H_PTR)
    h.mpu.memory[key_obj + O_HEADER] = 0x42
    h.rs_push(key)
    value = h.alloc_int(1)
    value_obj = h.read_word(value + H_PTR)
    h.mpu.memory[value_obj + O_HEADER] = 0x99
    h.rs_pop(); h.rs_pop()  # clear the pins (set will re-push)

    call_dict_set(h, d, key, value)

    assert call_dict_len(h, d) == 1
    assert call_dict_get(h, d, key) == value


def test_set_then_get_with_static_key(h):
    """Static-handle keys also work — handle identity short-circuits val_cmp."""
    d = h.alloc_dict()
    int_1 = h.sym["INT_1"]
    value = place_int(h, 0x7800, [0xAB])
    call_dict_set(h, d, int_1, value)
    assert call_dict_get(h, d, int_1) == value


# --- multi-entry: ordering preserved ----------------------------------------


def test_inserts_keep_keys_sorted(h):
    """Dict keeps keys sorted internally regardless of insertion order."""
    d = h.alloc_dict()
    k3 = place_int(h, 0x7800, [0x03])
    k1 = place_int(h, 0x6100, [0x01])
    k2 = place_int(h, 0x6200, [0x02])
    v3 = place_int(h, 0x6300, [0xC3])
    v1 = place_int(h, 0x6400, [0xC1])
    v2 = place_int(h, 0x6500, [0xC2])

    call_dict_set(h, d, k3, v3)
    call_dict_set(h, d, k1, v1)
    call_dict_set(h, d, k2, v2)

    assert call_dict_len(h, d) == 3
    keys = dict_keys_in_order(h, d)
    assert keys == [k1, k2, k3], f"keys not sorted: {keys}"


def test_get_after_multi_insert(h):
    d = h.alloc_dict()
    k1 = place_int(h, 0x7800, [0x01])
    k2 = place_int(h, 0x6100, [0x02])
    k3 = place_int(h, 0x6200, [0x03])
    v1 = place_int(h, 0x6300, [0xA1])
    v2 = place_int(h, 0x6400, [0xA2])
    v3 = place_int(h, 0x6500, [0xA3])

    call_dict_set(h, d, k2, v2)
    call_dict_set(h, d, k3, v3)
    call_dict_set(h, d, k1, v1)

    assert call_dict_get(h, d, k1) == v1
    assert call_dict_get(h, d, k2) == v2
    assert call_dict_get(h, d, k3) == v3


# --- update existing key ---------------------------------------------------


def test_update_existing_key_does_not_grow(h):
    d = h.alloc_dict()
    k = place_int(h, 0x7800, [0x42])
    v1 = place_int(h, 0x6100, [0x01])
    v2 = place_int(h, 0x6200, [0x02])

    call_dict_set(h, d, k, v1)
    assert call_dict_len(h, d) == 1
    assert call_dict_get(h, d, k) == v1

    call_dict_set(h, d, k, v2)
    assert call_dict_len(h, d) == 1            # not grown
    assert call_dict_get(h, d, k) == v2


# --- string keys ------------------------------------------------------------


def test_string_keys_sorted_lexicographically(h):
    d = h.alloc_dict()
    apple = place_str(h, 0x7800, [ord(c) for c in "apple"])
    banana = place_str(h, 0x6100, [ord(c) for c in "banana"])
    cherry = place_str(h, 0x6200, [ord(c) for c in "cherry"])
    v1 = place_int(h, 0x6300, [1])
    v2 = place_int(h, 0x6400, [2])
    v3 = place_int(h, 0x6500, [3])

    call_dict_set(h, d, banana, v2)
    call_dict_set(h, d, cherry, v3)
    call_dict_set(h, d, apple, v1)

    keys = dict_keys_in_order(h, d)
    assert keys == [apple, banana, cherry]
    assert call_dict_get(h, d, apple) == v1
    assert call_dict_get(h, d, banana) == v2
    assert call_dict_get(h, d, cherry) == v3


# --- bool keys --------------------------------------------------------------


def test_bool_keys(h):
    d = h.alloc_dict()
    true_addr = h.sym["TRUE"]
    false_addr = h.sym["FALSE"]
    v1 = place_int(h, 0x7800, [1])
    v2 = place_int(h, 0x6100, [2])

    call_dict_set(h, d, true_addr, v1)
    call_dict_set(h, d, false_addr, v2)

    assert call_dict_get(h, d, true_addr) == v1
    assert call_dict_get(h, d, false_addr) == v2
    # FALSE (payload 0) sorts before TRUE (payload 1).
    assert dict_keys_in_order(h, d) == [false_addr, true_addr]


# --- tuple keys -------------------------------------------------------------


def test_tuple_keys(h):
    d = h.alloc_dict()
    a = place_int(h, 0x7800, [0x01])
    b = place_int(h, 0x6100, [0x02])
    c = place_int(h, 0x6200, [0x03])
    k_ab = place_tuple(h, 0x6300, [a, b])
    k_ac = place_tuple(h, 0x6400, [a, c])
    v1 = place_int(h, 0x6500, [0xC1])
    v2 = place_int(h, 0x6600, [0xC2])

    call_dict_set(h, d, k_ac, v2)
    call_dict_set(h, d, k_ab, v1)

    assert call_dict_get(h, d, k_ab) == v1
    assert call_dict_get(h, d, k_ac) == v2
    # (a,b) < (a,c) at second element → ab sorts first.
    assert dict_keys_in_order(h, d) == [k_ab, k_ac]


# --- mixed-type keys --------------------------------------------------------


def test_mixed_type_keys(h):
    """val_cmp falls back to type-tag order for cross-type keys.
    TYPE_INT < TYPE_STR < TYPE_BOOL < TYPE_TUPLE numerically."""
    d = h.alloc_dict()
    int_key = place_int(h, 0x7800, [0x05])
    str_key = place_str(h, 0x6100, [ord("z")])
    bool_key = h.sym["TRUE"]
    a = place_int(h, 0x6200, [1])
    tup_key = place_tuple(h, 0x6300, [a])

    v1 = place_int(h, 0x6400, [1])
    v2 = place_int(h, 0x6500, [2])
    v3 = place_int(h, 0x6600, [3])
    v4 = place_int(h, 0x6700, [4])

    call_dict_set(h, d, tup_key, v4)
    call_dict_set(h, d, str_key, v2)
    call_dict_set(h, d, int_key, v1)
    call_dict_set(h, d, bool_key, v3)

    keys = dict_keys_in_order(h, d)
    assert keys == [int_key, str_key, bool_key, tup_key]


# --- dict_del ---------------------------------------------------------------


def test_del_removes_key(h):
    d = h.alloc_dict()
    k1 = place_int(h, 0x7800, [0x01])
    k2 = place_int(h, 0x6100, [0x02])
    k3 = place_int(h, 0x6200, [0x03])
    v1 = place_int(h, 0x6300, [0xA1])
    v2 = place_int(h, 0x6400, [0xA2])
    v3 = place_int(h, 0x6500, [0xA3])

    call_dict_set(h, d, k1, v1)
    call_dict_set(h, d, k2, v2)
    call_dict_set(h, d, k3, v3)
    assert call_dict_len(h, d) == 3

    call_dict_del(h, d, k2)
    assert call_dict_len(h, d) == 2
    none_addr = h.sym["NONE"]
    assert call_dict_get(h, d, k2) == none_addr
    assert call_dict_get(h, d, k1) == v1
    assert call_dict_get(h, d, k3) == v3
    assert dict_keys_in_order(h, d) == [k1, k3]


def test_del_missing_is_noop(h):
    d = h.alloc_dict()
    k1 = place_int(h, 0x7800, [0x01])
    v1 = place_int(h, 0x6100, [0xA1])
    call_dict_set(h, d, k1, v1)

    k_missing = place_int(h, 0x6200, [0xFF])
    call_dict_del(h, d, k_missing)
    assert call_dict_len(h, d) == 1
    assert call_dict_get(h, d, k1) == v1


# --- larger dict — exercises grow + multiple bin-search levels --------------


def test_many_inserts_stay_sorted(h):
    d = h.alloc_dict()
    h.rs_push(d)

    keys_values = []
    insert_order = [5, 1, 9, 3, 7, 2, 8, 4, 6, 0]
    for k_val in insert_order:
        h.rs_push(d)
        key = h.alloc_int(1)
        ko = h.read_word(key + H_PTR)
        h.mpu.memory[ko + O_HEADER] = k_val
        h.rs_push(key)
        value = h.alloc_int(1)
        vo = h.read_word(value + H_PTR)
        h.mpu.memory[vo + O_HEADER] = 0x80 + k_val
        h.rs_pop(); h.rs_pop()  # drop our pins
        call_dict_set(h, d, key, value)
        keys_values.append((k_val, key, value))

    # All entries readable.
    for k_val, key, value in keys_values:
        assert call_dict_get(h, d, key) == value, f"k={k_val}"

    assert call_dict_len(h, d) == 10

    # Keys appear in payload sorted by their int value.
    sorted_keys = [key for _, key, _ in sorted(keys_values, key=lambda t: t[0])]
    assert dict_keys_in_order(h, d) == sorted_keys


# --- val_eq on dicts (already supported via _veq_array) ---------------------


def test_val_eq_equal_dicts(h):
    d1 = h.alloc_dict()
    d2 = h.alloc_dict()
    k1 = place_int(h, 0x7800, [0x01])
    v1 = place_int(h, 0x6100, [0xA1])
    k2 = place_int(h, 0x6200, [0x02])
    v2 = place_int(h, 0x6300, [0xA2])

    call_dict_set(h, d1, k1, v1)
    call_dict_set(h, d1, k2, v2)
    call_dict_set(h, d2, k2, v2)  # different insert order; sorted state same
    call_dict_set(h, d2, k1, v1)

    rsp = h.rsp
    h.rs_push(d1)
    h.rs_push(d2)
    h.call("val_eq")
    assert h.rsp == rsp
    assert h.mpu.a == 1


def test_val_eq_dicts_differ_in_value(h):
    d1 = h.alloc_dict()
    d2 = h.alloc_dict()
    k = place_int(h, 0x7800, [0x01])
    v_a = place_int(h, 0x6100, [0xA1])
    v_b = place_int(h, 0x6200, [0xA2])

    call_dict_set(h, d1, k, v_a)
    call_dict_set(h, d2, k, v_b)

    rsp = h.rsp
    h.rs_push(d1)
    h.rs_push(d2)
    h.call("val_eq")
    assert h.rsp == rsp
    assert h.mpu.a == 0


# --- GC tracing of dict children -------------------------------------------


def test_dict_pair_survives_gc(h):
    """Dict's pair tuples + their key/value handles all survive a collect."""
    d = h.alloc_dict()
    h.rs_push(d)
    k = h.alloc_int(1)
    h.rs_push(k)
    ko = h.read_word(k + H_PTR)
    h.mpu.memory[ko + O_HEADER] = 0x42
    v = h.alloc_int(1)
    vo = h.read_word(v + H_PTR)
    h.mpu.memory[vo + O_HEADER] = 0x99
    h.rs_pop(); h.rs_pop()  # drop direct pins; key/value reachable via dict only after set

    call_dict_set(h, d, k, v)

    h.rs_push(d)
    h.call("gc_collect")

    # Re-read through the dict — handles are stable, payloads may have moved.
    assert call_dict_get(h, d, k) == v
    new_v_obj = h.read_word(v + H_PTR)
    assert h.mpu.memory[new_v_obj + O_HEADER] == 0x99
