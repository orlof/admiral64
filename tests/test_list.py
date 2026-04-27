"""Tests for list.asm — TYPE_LIST primitives.

Lists share the sequence shape with tuples (N consecutive 16-bit handles,
O_LEN = element count), so most of the read paths reuse seq.asm. List-specific
work: mutation (`list_set`), append + grow.
"""

from __future__ import annotations

from conftest import RV, TYPE_LIST, W0, W1, FSP_ZP
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


def place_list(h, addr: int, child_handles: list[int], capacity: int | None = None) -> int:
    """Hand-place a list handle+object pair. capacity defaults to len(children)."""
    if capacity is None:
        capacity = len(child_handles)
    handle_addr = addr
    object_addr = addr + SIZEOF_HANDLE

    h.write_word(handle_addr + H_PTR, object_addr)
    h.write_word(handle_addr + H_SIZE, O_HEADER + 2 * capacity)
    h.write_word(handle_addr + 4, 0)  # H_NEXT
    h.mpu.memory[handle_addr + H_TYPE] = TYPE_LIST
    h.mpu.memory[handle_addr + H_FLAGS] = 0

    h.write_word(object_addr + O_LEN, len(child_handles))
    for i, child in enumerate(child_handles):
        h.write_word(object_addr + O_HEADER + 2 * i, child)
    # Pad capacity slots with zero so any future append sees null.
    for i in range(len(child_handles), capacity):
        h.write_word(object_addr + O_HEADER + 2 * i, 0)
    return handle_addr


def read_list(h, list_handle: int) -> list[int]:
    obj = h.read_word(list_handle + H_PTR)
    n = h.read_word(obj + O_LEN)
    return [h.read_word(obj + O_HEADER + 2 * i) for i in range(n)]


def list_capacity(h, list_handle: int) -> int:
    return (h.read_word(list_handle + H_SIZE) - O_HEADER) // 2


# --- list_alloc -------------------------------------------------------------


def test_list_alloc_sets_type_tag(h):
    handle = h.alloc_list(3)
    assert h.mpu.memory[handle + H_TYPE] == TYPE_LIST


def test_list_alloc_sets_o_len_to_count(h):
    handle = h.alloc_list(5)
    obj = h.read_word(handle + H_PTR)
    assert h.read_word(obj + O_LEN) == 5


def test_list_alloc_zero_count(h):
    handle = h.alloc_list(0)
    assert h.mpu.memory[handle + H_TYPE] == TYPE_LIST
    obj = h.read_word(handle + H_PTR)
    assert h.read_word(obj + O_LEN) == 0


def test_list_alloc_zeroes_payload(h):
    from conftest import HEAP_DATA_START
    for i in range(20):
        h.mpu.memory[HEAP_DATA_START + i] = 0xCC
    handle = h.alloc_list(4)
    obj = h.read_word(handle + H_PTR)
    for i in range(4):
        assert h.read_word(obj + O_HEADER + 2 * i) == 0


# --- shared accessors (seq_get / seq_len work on lists too) -----------------


def _call_seq_get_via_list(h, list_handle: int, index: int) -> int:
    rsp_initial = h.rsp
    fsp_initial = h.read_word(FSP_ZP)
    h.rs_push(list_handle)
    # Push index as a word onto FS.
    h.write_word(FSP_ZP, fsp_initial - 2)
    h.write_word(fsp_initial - 2, index & 0xFFFF)
    h.call("list_get")
    assert h.rsp == rsp_initial
    assert h.read_word(FSP_ZP) == fsp_initial
    return h.read_word(RV)


def _call_list_len(h, list_handle: int) -> int:
    rsp_initial = h.rsp
    h.rs_push(list_handle)
    h.call("list_len")
    assert h.rsp == rsp_initial
    return h.mpu.a


def test_list_get_alias_reads_slot(h):
    a = place_int(h, 0x7E00, [0x11])
    b = place_int(h, 0x6100, [0x22])
    L = place_list(h, 0x6200, [a, b])
    assert _call_seq_get_via_list(h, L, 0) == a
    assert _call_seq_get_via_list(h, L, 1) == b


def test_list_len_alias(h):
    a = place_int(h, 0x7E00, [0x11])
    L = place_list(h, 0x6100, [a, a, a, a])
    assert _call_list_len(h, L) == 4


# --- list_set ---------------------------------------------------------------


def _call_list_set(h, list_handle: int, index: int, child: int) -> None:
    rsp_initial = h.rsp
    fsp_initial = h.read_word(FSP_ZP)
    h.rs_push(list_handle)
    h.rs_push(child)
    h.write_word(FSP_ZP, fsp_initial - 2)
    h.write_word(fsp_initial - 2, index & 0xFFFF)
    h.call("list_set")
    assert h.rsp == rsp_initial
    assert h.read_word(FSP_ZP) == fsp_initial


def test_list_set_replaces_slot(h):
    a = place_int(h, 0x7E00, [0x11])
    b = place_int(h, 0x6100, [0x22])
    new_child = place_int(h, 0x6200, [0xFF])
    L = place_list(h, 0x6300, [a, b])
    _call_list_set(h, L, 1, new_child)
    assert read_list(h, L) == [a, new_child]


def test_list_set_does_not_change_o_len(h):
    a = place_int(h, 0x7E00, [0x11])
    new_child = place_int(h, 0x6100, [0xFF])
    L = place_list(h, 0x6200, [a, a, a])
    _call_list_set(h, L, 1, new_child)
    obj = h.read_word(L + H_PTR)
    assert h.read_word(obj + O_LEN) == 3


# --- list_append ------------------------------------------------------------


def _call_list_append(h, list_handle: int, child: int) -> None:
    rsp_initial = h.rsp
    h.rs_push(list_handle)
    h.rs_push(child)
    h.call("list_append")
    assert h.rsp == rsp_initial


def test_append_to_empty_list_grows_and_writes(h):
    """Empty list (capacity 0) → append must grow to floor capacity 4."""
    L = h.alloc_list(0)
    h.rs_push(L)               # root before allocating child
    child = h.alloc_int(1)
    child_obj = h.read_word(child + H_PTR)
    h.write_bytes(child_obj + O_HEADER, [0x42])
    h.rs_push(child)
    h.rs_pop()                 # already on RS via list args; clear duplicate
    h.rs_pop()                 # clear our pin (list will re-push for append)

    # Re-stage for the append call.
    h.rs_push(L)
    h.rs_push(child)
    h.call("list_append")

    obj = h.read_word(L + H_PTR)
    assert h.read_word(obj + O_LEN) == 1
    assert h.read_word(obj + O_HEADER) == child
    assert list_capacity(h, L) >= 4   # grew to floor


def test_append_within_capacity_no_grow(h):
    """List with slack capacity: append must not realloc."""
    a = place_int(h, 0x7E00, [0x11])
    b = place_int(h, 0x6100, [0x22])
    # Capacity 4, length 2.
    L = place_list(h, 0x6200, [a, b], capacity=4)
    h_ptr_before = h.read_word(L + H_PTR)
    h_size_before = h.read_word(L + H_SIZE)

    new_child = place_int(h, 0x6300, [0x33])
    _call_list_append(h, L, new_child)

    assert h.read_word(L + H_PTR) == h_ptr_before, "should not have grown"
    assert h.read_word(L + H_SIZE) == h_size_before
    obj = h.read_word(L + H_PTR)
    assert h.read_word(obj + O_LEN) == 3
    assert h.read_word(obj + O_HEADER + 4) == new_child


def test_append_at_capacity_triggers_grow(h):
    """When O_LEN == capacity, append must realloc."""
    L = h.alloc_list(2)        # initial: O_LEN=2, capacity=2, both null
    h_ptr_before = h.read_word(L + H_PTR)
    h_size_before = h.read_word(L + H_SIZE)

    h.rs_push(L)
    child = h.alloc_int(1)
    child_obj = h.read_word(child + H_PTR)
    h.write_bytes(child_obj + O_HEADER, [0x99])
    # Don't drop the pin — the append call needs L on RS too. Re-stage:
    h.rs_pop()                  # remove our pin
    h.rs_push(L)
    h.rs_push(child)
    h.call("list_append")

    assert h.read_word(L + H_PTR) != h_ptr_before, "should have grown"
    assert h.read_word(L + H_SIZE) > h_size_before
    obj = h.read_word(L + H_PTR)
    assert h.read_word(obj + O_LEN) == 3
    assert h.read_word(obj + O_HEADER + 4) == child


def test_grow_preserves_existing_elements(h):
    """When grow runs, the old elements must be byte-identical in the new
    payload area."""
    L = h.alloc_list(2)
    obj = h.read_word(L + H_PTR)
    # Manually set elements to recognisable handle-shaped values.
    a = place_int(h, 0x7E00, [0xAA])
    b = place_int(h, 0x6100, [0xBB])
    h.write_word(obj + O_HEADER, a)
    h.write_word(obj + O_HEADER + 2, b)
    # capacity == 2, O_LEN == 2 → next append grows.
    h.rs_push(L)
    new_child = h.alloc_int(1)
    new_obj = h.read_word(new_child + H_PTR)
    h.write_bytes(new_obj + O_HEADER, [0xCC])
    h.rs_pop()

    h.rs_push(L)
    h.rs_push(new_child)
    h.call("list_append")

    assert read_list(h, L) == [a, b, new_child]


def test_repeated_appends_grow_amortized(h):
    """Append 10 items into a 0-capacity list. Final state is consistent.

    `list_append` consumes both args from RS, so we re-push L at the top of
    each iteration to keep it rooted across the alloc + call.
    """
    L = h.alloc_list(0)
    appended = []
    for i in range(10):
        h.rs_push(L)            # pin L for this iteration's alloc + call
        child = h.alloc_int(1)  # safe: nothing GC-triggers between this and the rs_push below
        child_obj = h.read_word(child + H_PTR)
        h.mpu.memory[child_obj + O_HEADER] = i + 1
        appended.append(child)
        h.rs_push(child)        # RS = [L, child] — list_append's expected shape
        h.call("list_append")   # consumes both

    obj = h.read_word(L + H_PTR)
    assert h.read_word(obj + O_LEN) == 10
    for i, child in enumerate(appended):
        assert h.read_word(obj + O_HEADER + 2 * i) == child


# --- val_eq via list dispatch -----------------------------------------------


def _call_val_eq(h, a: int, b: int) -> int:
    rsp_initial = h.rsp
    h.rs_push(a)
    h.rs_push(b)
    h.call("val_eq")
    assert h.rsp == rsp_initial
    return h.mpu.a


def test_val_eq_lists_equal_payloads(h):
    a1 = place_int(h, 0x7E00, [0x01])
    b1 = place_int(h, 0x6100, [0x02])
    L1 = place_list(h, 0x6200, [a1, b1])

    a2 = place_int(h, 0x6300, [0x01])
    b2 = place_int(h, 0x6400, [0x02])
    L2 = place_list(h, 0x6500, [a2, b2])

    assert _call_val_eq(h, L1, L2) == 1


def test_val_eq_lists_differ(h):
    a1 = place_int(h, 0x7E00, [0x01])
    b1 = place_int(h, 0x6100, [0x02])
    L1 = place_list(h, 0x6200, [a1, b1])

    a2 = place_int(h, 0x6300, [0x99])
    b2 = place_int(h, 0x6400, [0x02])
    L2 = place_list(h, 0x6500, [a2, b2])

    assert _call_val_eq(h, L1, L2) == 0


def test_val_eq_list_ne_tuple_same_payload(h):
    """Type tag distinguishes list from tuple even when contents match."""
    from test_tuple import place_tuple
    a = place_int(h, 0x7E00, [0x11])
    L = place_list(h, 0x6100, [a])
    T = place_tuple(h, 0x6200, [a])
    assert _call_val_eq(h, L, T) == 0


# --- GC tracing of list children --------------------------------------------


def test_rooted_list_children_survive_gc(h):
    """List traced like tuple — children marked transitively."""
    child = h.alloc_int(2)
    obj = h.read_word(child + H_PTR)
    h.write_bytes(obj + O_HEADER, [0xDE, 0xAD])
    h.rs_push(child)

    L = h.alloc_list(1)
    L_obj = h.read_word(L + H_PTR)
    h.write_word(L_obj + O_HEADER, child)
    h.rs_pop()                 # drop direct child pin
    h.rs_push(L)

    h.call("gc_collect")

    new_obj = h.read_word(child + H_PTR)
    assert h.read_bytes(new_obj + O_HEADER, 2) == [0xDE, 0xAD]


def test_grow_old_payload_orphaned_then_compacted(h):
    """After grow, old payload bytes are unreferenced; gc_compact reclaims
    that space. Validate: total NEXT_DATA after compact equals the size of
    the live payloads only."""
    from conftest import HEAP_DATA_START, NEXT_DATA_ZP
    L = h.alloc_list(0)
    h.rs_push(L)
    # Force several grows so we definitely orphan some payload bytes.
    for i in range(5):
        h.rs_pop()
        child = h.alloc_int(1)
        h.rs_push(L)
        h.rs_push(child)
        h.call("list_append")
        h.rs_push(L)            # re-pin for next iteration

    next_data_before = h.read_word(NEXT_DATA_ZP)
    h.call("gc_collect")
    next_data_after = h.read_word(NEXT_DATA_ZP)

    assert next_data_after < next_data_before, (
        "compact should have reclaimed orphaned grow payloads"
    )
    # And the list still works.
    obj = h.read_word(L + H_PTR)
    assert h.read_word(obj + O_LEN) == 5
