"""Tests for assign.asm — Phase A runtime support for tuple-unpacking lvalues.

Covers:
  - alloc_ref / alloc_sub allocate 2-handle TYPE_REF / TYPE_SUB targets.
  - assign() dispatches on target H_TYPE:
      TYPE_STR    → scope_set
      TYPE_REF    → dict_set on receiver
      TYPE_SUB    → list_set or dict_set based on container type
      TYPE_TUPLE  → arity-check then recursively assign each pair
"""

from __future__ import annotations

import pytest

from conftest import (
    ERR_ARITY,
    ERR_TYPE,
    ERROR_CODE_ZP,
    RV,
    TYPE_DICT,
    TYPE_LIST,
    TYPE_REF,
    TYPE_SUB,
    TYPE_TUPLE,
)
from test_dict import call_dict_get, dict_keys_in_order, read_dict_pair
from test_int_add import H_PTR, H_TYPE, O_HEADER, O_LEN, place_int
from test_str import place_str
from test_tuple import place_tuple, read_tuple_slot


GLOBAL_SCOPE_ZP = 0x42  # must match src/defs.asm


# --- helpers ----------------------------------------------------------------


def setup_global_scope(h) -> int:
    """Allocate a fresh dict and bind it as the current scope."""
    scope = h.alloc_dict()
    h.write_word(GLOBAL_SCOPE_ZP, scope)
    return scope


def call_alloc_ref(h, receiver: int, name: int) -> int:
    rsp_initial = h.rsp
    h.rs_push(receiver)
    h.rs_push(name)
    h.call("alloc_ref")
    assert h.rsp == rsp_initial
    return h.read_word(RV)


def call_alloc_sub(h, container: int, index: int) -> int:
    rsp_initial = h.rsp
    h.rs_push(container)
    h.rs_push(index)
    h.call("alloc_sub")
    assert h.rsp == rsp_initial
    return h.read_word(RV)


def call_assign(h, target: int, value: int) -> None:
    rsp_initial = h.rsp
    h.rs_push(target)
    h.rs_push(value)
    h.call("assign")
    assert h.rsp == rsp_initial


def call_assign_panics(h, target: int, value: int, error_code: int) -> None:
    h.rs_push(target)
    h.rs_push(value)
    h.call("assign", expect_panic=True)
    assert h.mpu.memory[ERROR_CODE_ZP] == error_code, (
        f"expected ERROR_CODE=${error_code:02X}, got "
        f"${h.mpu.memory[ERROR_CODE_ZP]:02X}"
    )


# --- alloc_ref --------------------------------------------------------------


def test_alloc_ref_sets_type_tag(h):
    receiver = h.alloc_dict()
    name = place_str(h, 0x8500, [0x41])
    ref = call_alloc_ref(h, receiver, name)
    assert h.mpu.memory[ref + H_TYPE] == TYPE_REF


def test_alloc_ref_payload_holds_receiver_and_name(h):
    receiver = h.alloc_dict()
    name = place_str(h, 0x8500, [0x42])
    ref = call_alloc_ref(h, receiver, name)
    assert read_tuple_slot(h, ref, 0) == receiver
    assert read_tuple_slot(h, ref, 1) == name


def test_alloc_ref_o_len_is_two(h):
    receiver = h.alloc_dict()
    name = place_str(h, 0x8500, [0x43])
    ref = call_alloc_ref(h, receiver, name)
    obj = h.read_word(ref + H_PTR)
    assert h.read_word(obj + O_LEN) == 2


# --- alloc_sub --------------------------------------------------------------


def test_alloc_sub_sets_type_tag(h):
    container = h.alloc_list(0)
    index = place_int(h, 0x8500, [0x00])
    sub = call_alloc_sub(h, container, index)
    assert h.mpu.memory[sub + H_TYPE] == TYPE_SUB


def test_alloc_sub_payload_holds_container_and_index(h):
    container = h.alloc_list(0)
    index = place_int(h, 0x8500, [0x05])
    sub = call_alloc_sub(h, container, index)
    assert read_tuple_slot(h, sub, 0) == container
    assert read_tuple_slot(h, sub, 1) == index


# --- assign: TYPE_STR target → scope_set -----------------------------------


def test_assign_name_binds_in_scope(h):
    """assign(name_str, value) should call scope_set, binding name → value."""
    scope = setup_global_scope(h)
    name = place_str(h, 0x8500, [0x78])  # "x"
    value = place_int(h, 0x6100, [0x42])

    call_assign(h, name, value)

    # Look up directly in the scope dict.
    assert call_dict_get(h, scope, name) == value


def test_assign_name_overwrites_existing(h):
    scope = setup_global_scope(h)
    name = place_str(h, 0x8500, [0x79])  # "y"
    v1 = place_int(h, 0x6100, [0x01])
    v2 = place_int(h, 0x6200, [0x02])

    call_assign(h, name, v1)
    call_assign(h, name, v2)
    assert call_dict_get(h, scope, name) == v2


# --- assign: TYPE_REF target → dict_set ------------------------------------


def test_assign_ref_writes_to_receiver_dict(h):
    """assign(REF(d, "k"), v) → d["k"] = v."""
    receiver = h.alloc_dict()
    h.rs_push(receiver)  # root across alloc_ref
    name = place_str(h, 0x8500, [0x6B])  # "k"
    value = place_int(h, 0x6100, [0x99])

    ref = call_alloc_ref(h, receiver, name)
    h.rs_push(ref)  # root across the assign

    call_assign(h, ref, value)
    assert call_dict_get(h, receiver, name) == value


# --- assign: TYPE_SUB target → list_set ------------------------------------


def test_assign_sub_list_writes_at_index(h):
    """assign(SUB(list, 1), v) → list[1] = v."""
    # Build a 3-element list [a, b, c].
    a = place_int(h, 0x8500, [0x0A])
    b = place_int(h, 0x6100, [0x0B])
    c = place_int(h, 0x6200, [0x0C])
    lst = h.alloc_list(3)
    obj = h.read_word(lst + H_PTR)
    h.write_word(obj + O_HEADER + 0, a)
    h.write_word(obj + O_HEADER + 2, b)
    h.write_word(obj + O_HEADER + 4, c)
    h.rs_push(lst)

    index = place_int(h, 0x6300, [0x01])
    sub = call_alloc_sub(h, lst, index)
    h.rs_push(sub)

    new_b = place_int(h, 0x6400, [0xBB])
    call_assign(h, sub, new_b)

    obj = h.read_word(lst + H_PTR)
    assert h.read_word(obj + O_HEADER + 0) == a
    assert h.read_word(obj + O_HEADER + 2) == new_b
    assert h.read_word(obj + O_HEADER + 4) == c


# --- assign: TYPE_SUB target → dict_set ------------------------------------


def test_assign_sub_dict_inserts_pair(h):
    """assign(SUB(dict, key), value) → dict[key] = value."""
    d = h.alloc_dict()
    h.rs_push(d)
    key = place_str(h, 0x8500, [0x6B])
    value = place_int(h, 0x6100, [0x33])
    sub = call_alloc_sub(h, d, key)
    h.rs_push(sub)

    call_assign(h, sub, value)
    assert call_dict_get(h, d, key) == value


# --- assign: type errors ----------------------------------------------------


def test_assign_panics_on_unsupported_target_type(h):
    """An int as target → ERR_TYPE."""
    target = place_int(h, 0x8500, [0x00])
    value = place_int(h, 0x6100, [0x01])
    call_assign_panics(h, target, value, ERR_TYPE)


def test_assign_sub_panics_on_unsupported_container(h):
    """SUB(int, ...) is nonsensical — assign should ERR_TYPE."""
    container = place_int(h, 0x8500, [0x00])
    index = place_int(h, 0x6100, [0x00])
    h.rs_push(container)
    sub = call_alloc_sub(h, container, index)
    h.rs_push(sub)

    value = place_int(h, 0x6200, [0x05])
    call_assign_panics(h, sub, value, ERR_TYPE)


# --- assign: TYPE_TUPLE target → recursive unpack --------------------------


def test_assign_tuple_unpacks_flat(h):
    """assign((x, y), (1, 2)) — both names bound."""
    scope = setup_global_scope(h)
    nx = place_str(h, 0x8500, [0x78])  # "x"
    ny = place_str(h, 0x6100, [0x79])  # "y"
    target = place_tuple(h, 0x6200, [nx, ny])

    v1 = place_int(h, 0x6300, [0x01])
    v2 = place_int(h, 0x6400, [0x02])
    value = place_tuple(h, 0x6500, [v1, v2])

    call_assign(h, target, value)
    assert call_dict_get(h, scope, nx) == v1
    assert call_dict_get(h, scope, ny) == v2


def test_assign_tuple_value_can_be_list(h):
    """assign((x, y), [1, 2]) — RHS is a list, also accepted."""
    scope = setup_global_scope(h)
    nx = place_str(h, 0x8500, [0x78])
    ny = place_str(h, 0x6100, [0x79])
    target = place_tuple(h, 0x6200, [nx, ny])

    v1 = place_int(h, 0x6300, [0x07])
    v2 = place_int(h, 0x6400, [0x08])
    lst = h.alloc_list(2)
    obj = h.read_word(lst + H_PTR)
    h.write_word(obj + O_HEADER + 0, v1)
    h.write_word(obj + O_HEADER + 2, v2)

    call_assign(h, target, lst)
    assert call_dict_get(h, scope, nx) == v1
    assert call_dict_get(h, scope, ny) == v2


def test_assign_tuple_nested(h):
    """assign((a, (b, c)), (1, (2, 3))) — nested unpack reaches all leaves."""
    scope = setup_global_scope(h)
    na = place_str(h, 0x8500, [0x61])  # "a"
    nb = place_str(h, 0x6100, [0x62])  # "b"
    nc = place_str(h, 0x6200, [0x63])  # "c"
    inner_tgt = place_tuple(h, 0x6300, [nb, nc])
    target = place_tuple(h, 0x6400, [na, inner_tgt])

    v1 = place_int(h, 0x6500, [0x01])
    v2 = place_int(h, 0x6600, [0x02])
    v3 = place_int(h, 0x6700, [0x03])
    inner_val = place_tuple(h, 0x6800, [v2, v3])
    value = place_tuple(h, 0x6900, [v1, inner_val])

    call_assign(h, target, value)
    assert call_dict_get(h, scope, na) == v1
    assert call_dict_get(h, scope, nb) == v2
    assert call_dict_get(h, scope, nc) == v3


def test_assign_tuple_arity_mismatch_panics(h):
    """LHS and RHS must have the same length, else ERR_ARITY."""
    setup_global_scope(h)
    nx = place_str(h, 0x8500, [0x78])
    ny = place_str(h, 0x6100, [0x79])
    target = place_tuple(h, 0x6200, [nx, ny])

    v1 = place_int(h, 0x6300, [0x01])
    v2 = place_int(h, 0x6400, [0x02])
    v3 = place_int(h, 0x6500, [0x03])
    value = place_tuple(h, 0x6600, [v1, v2, v3])

    call_assign_panics(h, target, value, ERR_ARITY)


def test_assign_tuple_rhs_must_be_sequence(h):
    """RHS that isn't TYPE_TUPLE/LIST → ERR_TYPE."""
    setup_global_scope(h)
    nx = place_str(h, 0x8500, [0x78])
    ny = place_str(h, 0x6100, [0x79])
    target = place_tuple(h, 0x6200, [nx, ny])

    value = place_int(h, 0x6300, [0x42])  # int, not a sequence
    call_assign_panics(h, target, value, ERR_TYPE)


def test_assign_mixed_lvalue_kinds(h):
    """assign((name, dict[key]), (v1, v2)) — name lvalue + sub lvalue."""
    scope = setup_global_scope(h)
    name = place_str(h, 0x8500, [0x78])  # "x"

    d = h.alloc_dict()
    h.rs_push(d)
    key = place_str(h, 0x6100, [0x6B])  # "k"
    sub = call_alloc_sub(h, d, key)
    h.rs_push(sub)

    target = place_tuple(h, 0x6200, [name, sub])
    h.rs_push(target)

    v1 = place_int(h, 0x6300, [0x11])
    v2 = place_int(h, 0x6400, [0x22])
    value = place_tuple(h, 0x6500, [v1, v2])

    call_assign(h, target, value)
    assert call_dict_get(h, scope, name) == v1
    assert call_dict_get(h, d, key) == v2
