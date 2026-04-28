"""Tests for tuple.asm — TYPE_TUPLE primitives + GC tracing.

Tuples are immutable, fixed-length sequences of handles. O_LEN is the element
count (not byte count); payload is N×2 bytes of child handle pointers.
"""

from __future__ import annotations

from conftest import RV, TYPE_TUPLE, W0, W1
from test_int_add import (
    H_FLAGS,
    H_PTR,
    H_SIZE,
    H_TYPE,
    O_HEADER,
    O_LEN,
    SIZEOF_HANDLE,
    place_int,
    read_int,
)
from test_str import place_str

FLAG_MARKED = 0x80
FLAG_GRAY = 0x40


def place_tuple(h, addr: int, child_handles: list[int]) -> int:
    """Hand-place a tuple handle+object pair at `addr`. Returns handle address."""
    handle_addr = addr
    object_addr = addr + SIZEOF_HANDLE
    h.write_word(handle_addr + H_PTR, object_addr)
    h.write_word(handle_addr + H_SIZE, O_HEADER + 2 * len(child_handles))
    h.write_word(handle_addr + 4, 0)  # H_NEXT
    h.mpu.memory[handle_addr + H_TYPE] = TYPE_TUPLE
    h.mpu.memory[handle_addr + H_FLAGS] = 0

    h.write_word(object_addr + O_LEN, len(child_handles))
    for i, child in enumerate(child_handles):
        h.write_word(object_addr + O_HEADER + 2 * i, child)
    return handle_addr


def read_tuple_slot(h, tuple_handle: int, index: int) -> int:
    obj = h.read_word(tuple_handle + H_PTR)
    return h.read_word(obj + O_HEADER + 2 * index)


# --- tuple_alloc -------------------------------------------------------------


def test_alloc_tuple_sets_type_tag(h):
    handle = h.alloc_tuple(3)
    assert h.mpu.memory[handle + H_TYPE] == TYPE_TUPLE


def test_alloc_tuple_sets_o_len_to_element_count(h):
    handle = h.alloc_tuple(5)
    obj = h.read_word(handle + H_PTR)
    assert h.read_word(obj + O_LEN) == 5


def test_alloc_tuple_h_size_is_header_plus_2N(h):
    handle = h.alloc_tuple(4)
    assert h.read_word(handle + H_SIZE) == O_HEADER + 8


def test_alloc_tuple_zero_elements(h):
    handle = h.alloc_tuple(0)
    assert h.mpu.memory[handle + H_TYPE] == TYPE_TUPLE
    obj = h.read_word(handle + H_PTR)
    assert h.read_word(obj + O_LEN) == 0


def test_alloc_tuple_payload_is_zeroed(h):
    # Pre-poke heap with a recognizable pattern so we know the zero-fill ran.
    from conftest import HEAP_DATA_START
    for i in range(20):
        h.mpu.memory[HEAP_DATA_START + i] = 0xAA

    handle = h.alloc_tuple(4)
    obj = h.read_word(handle + H_PTR)
    # All four child slots must read as null (0x0000).
    for i in range(4):
        assert h.read_word(obj + O_HEADER + 2 * i) == 0, f"slot {i}"


# --- tuple_get ---------------------------------------------------------------


def _call_tuple_get(h, tuple_handle: int, index: int) -> int:
    """V4' tuple_get: tuple on RS, index on FS. Returns RV (child handle)."""
    rsp_initial = h.rsp
    fsp_initial = h.read_word(0x02)
    h.rs_push(tuple_handle)
    # Push index as a word onto FS.
    h.write_word(0x02, fsp_initial - 2)  # decrement FSP by 2
    h.write_word(fsp_initial - 2, index & 0xFFFF)
    h.call("tuple_get")
    assert h.rsp == rsp_initial, "tuple_get violated RS discipline"
    assert h.read_word(0x02) == fsp_initial, "tuple_get violated FS discipline"
    return h.read_word(RV)


def test_tuple_get_reads_slot(h):
    child0 = place_int(h, 0x8500, [0x42])
    child1 = place_int(h, 0x6100, [0x43])
    t = place_tuple(h, 0x6200, [child0, child1])
    assert _call_tuple_get(h, t, 0) == child0
    assert _call_tuple_get(h, t, 1) == child1


def test_tuple_get_returns_zero_for_unset_slot(h):
    handle = h.alloc_tuple(3)
    assert _call_tuple_get(h, handle, 0) == 0
    assert _call_tuple_get(h, handle, 2) == 0


# --- tuple_len ---------------------------------------------------------------


def _call_tuple_len(h, tuple_handle: int) -> int:
    rsp_initial = h.rsp
    h.rs_push(tuple_handle)
    h.call("tuple_len")
    assert h.rsp == rsp_initial
    return h.mpu.a


def test_tuple_len_basic(h):
    child = place_int(h, 0x8500, [0x01])
    t = place_tuple(h, 0x6100, [child, child, child])
    assert _call_tuple_len(h, t) == 3


def test_tuple_len_zero(h):
    handle = h.alloc_tuple(0)
    assert _call_tuple_len(h, handle) == 0


# --- tuple_set_leaf ----------------------------------------------------------


def test_tuple_set_leaf_writes_slot(h):
    """tuple_set_leaf is a leaf helper — call it with W0/W1/A direct setup."""
    child = place_int(h, 0x8500, [0xAB])
    t = h.alloc_tuple(3)
    # W0 = tuple, W1 = child, A = index 1
    h.write_word(W0, t)
    h.write_word(W1, child)
    h.call("tuple_set_leaf", a=1)
    obj = h.read_word(t + H_PTR)
    assert h.read_word(obj + O_HEADER + 2 * 1) == child
    assert h.read_word(obj + O_HEADER + 2 * 0) == 0  # other slots untouched
    assert h.read_word(obj + O_HEADER + 2 * 2) == 0


# --- GC tracing of tuple children -------------------------------------------


def test_rooted_tuple_children_survive_gc(h):
    """A tuple's children must be marked transitively, not just the tuple."""
    child = h.alloc_int(2)
    child_obj = h.read_word(child + H_PTR)
    h.write_bytes(child_obj + O_HEADER, [0xDE, 0xAD])
    h.rs_push(child)                # pin while building tuple

    t = h.alloc_tuple(1)
    # Manually wire child into slot 0.
    t_obj = h.read_word(t + H_PTR)
    h.write_word(t_obj + O_HEADER, child)

    # Drop child from RS — it's now reachable only through the tuple.
    h.rs_pop()
    h.rs_push(t)

    h.call("gc_collect")

    # Child handle still on the live list and payload intact.
    assert h.mpu.memory[child + H_FLAGS] & FLAG_MARKED == 0  # cleared by sweep
    new_child_obj = h.read_word(child + H_PTR)
    assert h.read_bytes(new_child_obj + O_HEADER, 2) == [0xDE, 0xAD]


def test_unrooted_tuple_and_children_collected(h):
    """A tuple not rooted on RS gets freed; its children (if not otherwise
    referenced) get freed too."""
    child = h.alloc_int(2)
    t = h.alloc_tuple(1)
    t_obj = h.read_word(t + H_PTR)
    h.write_word(t_obj + O_HEADER, child)
    # Neither tuple nor child rooted — both garbage.

    h.call("gc_collect")

    # Re-allocating should reuse the freed handles (LIFO, child was freed last).
    reused = h.alloc_int(1)
    assert reused in (t, child)
    reused2 = h.alloc_int(1)
    assert reused2 in (t, child) and reused2 != reused


def test_nested_tuple_traces_all_levels(h):
    """A tuple inside a tuple — gc_mark must follow the full chain."""
    leaf = h.alloc_int(1)
    leaf_obj = h.read_word(leaf + H_PTR)
    h.write_bytes(leaf_obj + O_HEADER, [0x77])
    h.rs_push(leaf)

    inner = h.alloc_tuple(1)
    inner_obj = h.read_word(inner + H_PTR)
    h.write_word(inner_obj + O_HEADER, leaf)
    h.rs_pop()  # leaf no longer rooted directly
    h.rs_push(inner)

    outer = h.alloc_tuple(1)
    outer_obj = h.read_word(outer + H_PTR)
    h.write_word(outer_obj + O_HEADER, inner)
    h.rs_pop()  # inner no longer rooted directly
    h.rs_push(outer)

    h.call("gc_collect")

    # leaf must have survived two levels of indirection.
    leaf_obj_new = h.read_word(leaf + H_PTR)
    assert h.read_bytes(leaf_obj_new + O_HEADER, 1) == [0x77]
    # inner is reachable via outer; verify we can read leaf back through both.
    inner_handle_in_outer = read_tuple_slot(h, outer, 0)
    assert inner_handle_in_outer == inner
    leaf_handle_in_inner = read_tuple_slot(h, inner, 0)
    assert leaf_handle_in_inner == leaf


def test_tuple_with_null_slot_does_not_crash_gc(h):
    """gc_mark must skip unset (zero) child slots without dereferencing them."""
    t = h.alloc_tuple(3)  # all slots null
    h.rs_push(t)
    h.call("gc_collect")
    assert h.mpu.memory[t + H_TYPE] == TYPE_TUPLE


def test_partial_fill_traces_only_set_children(h):
    """Mixed: tuple has one real child and one null. Real child survives."""
    child = h.alloc_int(2)
    child_obj = h.read_word(child + H_PTR)
    h.write_bytes(child_obj + O_HEADER, [0xCA, 0xFE])
    h.rs_push(child)

    t = h.alloc_tuple(3)
    t_obj = h.read_word(t + H_PTR)
    # Slot 1 = child, slots 0 and 2 stay null.
    h.write_word(t_obj + O_HEADER + 2, child)

    h.rs_pop()
    h.rs_push(t)
    h.call("gc_collect")

    new_child_obj = h.read_word(child + H_PTR)
    assert h.read_bytes(new_child_obj + O_HEADER, 2) == [0xCA, 0xFE]


def test_no_gray_bit_remains_on_reserved_handles(h):
    """After gc_mark, every reserved handle is black (MARKED, !GRAY)."""
    child = h.alloc_int(1)
    h.rs_push(child)
    t = h.alloc_tuple(1)
    t_obj = h.read_word(t + H_PTR)
    h.write_word(t_obj + O_HEADER, child)
    h.rs_pop()
    h.rs_push(t)

    h.call("gc_mark")

    assert h.mpu.memory[t + H_FLAGS] & FLAG_GRAY == 0
    assert h.mpu.memory[child + H_FLAGS] & FLAG_GRAY == 0
    assert h.mpu.memory[t + H_FLAGS] & FLAG_MARKED == FLAG_MARKED
    assert h.mpu.memory[child + H_FLAGS] & FLAG_MARKED == FLAG_MARKED


# --- val_eq on tuples --------------------------------------------------------


def _call_val_eq(h, a: int, b: int) -> int:
    rsp_initial = h.rsp
    h.rs_push(a)
    h.rs_push(b)
    h.call("val_eq")
    assert h.rsp == rsp_initial
    return h.mpu.a


def test_val_eq_same_tuple_handle(h):
    a = place_int(h, 0x8500, [0x01])
    b = place_int(h, 0x6100, [0x02])
    t = place_tuple(h, 0x6200, [a, b])
    assert _call_val_eq(h, t, t) == 1


def test_val_eq_tuples_with_equal_int_children(h):
    a1 = place_int(h, 0x8500, [0x01])
    b1 = place_int(h, 0x6100, [0x02])
    t1 = place_tuple(h, 0x6200, [a1, b1])

    a2 = place_int(h, 0x6300, [0x01])
    b2 = place_int(h, 0x6400, [0x02])
    t2 = place_tuple(h, 0x6500, [a2, b2])

    assert _call_val_eq(h, t1, t2) == 1


def test_val_eq_tuples_differ_at_first_child(h):
    a1 = place_int(h, 0x8500, [0x01])
    b1 = place_int(h, 0x6100, [0x02])
    t1 = place_tuple(h, 0x6200, [a1, b1])

    a2 = place_int(h, 0x6300, [0x99])  # different
    b2 = place_int(h, 0x6400, [0x02])
    t2 = place_tuple(h, 0x6500, [a2, b2])

    assert _call_val_eq(h, t1, t2) == 0


def test_val_eq_tuples_differ_at_last_child(h):
    a1 = place_int(h, 0x8500, [0x01])
    b1 = place_int(h, 0x6100, [0x02])
    t1 = place_tuple(h, 0x6200, [a1, b1])

    a2 = place_int(h, 0x6300, [0x01])
    b2 = place_int(h, 0x6400, [0x99])  # different
    t2 = place_tuple(h, 0x6500, [a2, b2])

    assert _call_val_eq(h, t1, t2) == 0


def test_val_eq_tuples_different_lengths(h):
    a = place_int(h, 0x8500, [0x01])
    t1 = place_tuple(h, 0x6100, [a])
    t2 = place_tuple(h, 0x6200, [a, a])
    assert _call_val_eq(h, t1, t2) == 0


def test_val_eq_empty_tuples(h):
    t1 = place_tuple(h, 0x8500, [])
    t2 = place_tuple(h, 0x6100, [])
    assert _call_val_eq(h, t1, t2) == 1


def test_val_eq_nested_tuples(h):
    # ((1,), (2,))  ==  ((1,), (2,))  via two layers of recursion.
    one_a = place_int(h, 0x8500, [0x01])
    two_a = place_int(h, 0x6100, [0x02])
    inner_a1 = place_tuple(h, 0x6200, [one_a])
    inner_a2 = place_tuple(h, 0x6300, [two_a])
    outer_a = place_tuple(h, 0x6400, [inner_a1, inner_a2])

    one_b = place_int(h, 0x6500, [0x01])
    two_b = place_int(h, 0x6600, [0x02])
    inner_b1 = place_tuple(h, 0x6700, [one_b])
    inner_b2 = place_tuple(h, 0x6800, [two_b])
    outer_b = place_tuple(h, 0x6900, [inner_b1, inner_b2])

    assert _call_val_eq(h, outer_a, outer_b) == 1


def test_val_eq_tuple_of_strs(h):
    a1 = place_str(h, 0x8500, [0x48, 0x49])  # "HI"
    b1 = place_str(h, 0x6100, [0x21])         # "!"
    t1 = place_tuple(h, 0x6200, [a1, b1])

    a2 = place_str(h, 0x6300, [0x48, 0x49])
    b2 = place_str(h, 0x6400, [0x21])
    t2 = place_tuple(h, 0x6500, [a2, b2])

    assert _call_val_eq(h, t1, t2) == 1


def test_val_eq_tuple_ne_int_with_same_payload_bytes(h):
    """A tuple with one slot pointing at $XXXX has the same 2 payload bytes as
    an int [$XX, $XX], but their type tags differ — must not compare equal."""
    a = place_int(h, 0x8500, [0x01])
    t = place_tuple(h, 0x6100, [a])
    # An int whose payload is the byte representation of `a`'s handle.
    spoof = place_int(h, 0x6200, [a & 0xFF, (a >> 8) & 0xFF])
    assert _call_val_eq(h, t, spoof) == 0
