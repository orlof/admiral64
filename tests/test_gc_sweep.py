"""Tests for gc_sweep, gc_collect, and alloc free-list reuse."""

from __future__ import annotations

from conftest import (
    FREE_HEAD_ZP,
    HEAP_DATA_START,
    HEAP_HANDLE_START,
    NEXT_DATA_ZP,
    NEXT_HANDLE_ZP,
    TYPE_INT,
)

FLAG_MARKED = 0x80
FLAG_RENDERING = 0x10

H_PTR = 0
H_SIZE = 2
H_NEXT = 4
H_TYPE = 6
H_FLAGS = 7


def _flags(h, handle: int) -> int:
    return h.mpu.memory[handle + H_FLAGS]


def _h_next(h, handle: int) -> int:
    return h.read_word(handle + H_NEXT)


def _free_list(h) -> list[int]:
    """Walk FREE_HEAD via H_NEXT into a Python list (for assertions)."""
    out = []
    node = h.read_word(FREE_HEAD_ZP)
    while node != 0:
        out.append(node)
        node = _h_next(h, node)
    return out


# --- gc_sweep: empty / trivial cases ----------------------------------------

def test_sweep_fresh_heap_noop(h):
    h.call("gc_sweep")
    assert h.read_word(FREE_HEAD_ZP) == 0
    assert h.read_word(NEXT_HANDLE_ZP) == HEAP_HANDLE_START


# --- gc_sweep: all-unmarked, all-marked, mixed ------------------------------

def test_sweep_all_unmarked_threads_all_onto_free_list(h):
    handles = [h.alloc_int(2) for _ in range(3)]
    # None rooted → none marked → all should end up on free list.
    h.call("gc_sweep")
    # Walk-order: reserved list is [h1, h2, h3] in alloc order. Each unmarked
    # handle is prepended to FREE_HEAD, so free list ends up reversed.
    assert _free_list(h) == list(reversed(handles))
    for hdl in handles:
        assert _flags(h, hdl) == 0           # no stray flag bits


def test_sweep_all_marked_all_survive(h):
    handles = [h.alloc_int(2) for _ in range(3)]
    # Manually mark (simulating post-gc_mark state).
    for hdl in handles:
        h.mpu.memory[hdl + H_FLAGS] = FLAG_MARKED
    h.call("gc_sweep")
    assert h.read_word(FREE_HEAD_ZP) == 0
    for hdl in handles:
        assert _flags(h, hdl) == 0           # FLAG_MARKED cleared


def test_sweep_mixed_marked_and_unmarked(h):
    handles = [h.alloc_int(n) for n in (2, 4, 6, 8, 10)]
    survivors = {handles[1], handles[3]}
    for hdl in handles:
        if hdl in survivors:
            h.mpu.memory[hdl + H_FLAGS] = FLAG_MARKED
    h.call("gc_sweep")
    for hdl in handles:
        assert _flags(h, hdl) == 0          # mark cleared or never set
    freed = [hdl for hdl in handles if hdl not in survivors]
    assert set(_free_list(h)) == set(freed)


# --- gc_sweep: flag preservation --------------------------------------------

def test_sweep_preserves_other_flag_bits_on_survivors(h):
    """gc_sweep clears FLAG_MARKED on survivors but must leave unrelated bits
    alone — e.g. FLAG_RENDERING set by an in-progress print."""
    handle = h.alloc_int(4)
    h.mpu.memory[handle + H_FLAGS] = FLAG_MARKED | FLAG_RENDERING
    h.call("gc_sweep")
    assert _flags(h, handle) == FLAG_RENDERING   # MARKED cleared, RENDERING kept


# --- gc_sweep: idempotence / stability --------------------------------------

def test_sweep_twice_is_stable(h):
    handles = [h.alloc_int(2) for _ in range(3)]
    h.call("gc_sweep")
    first_list = _free_list(h)
    h.call("gc_sweep")
    second_list = _free_list(h)
    # Rebuilt identically — no cycles, no duplicates.
    assert first_list == second_list
    assert len(set(second_list)) == len(second_list)  # no duplicates


# --- gc_collect end-to-end --------------------------------------------------

def test_gc_collect_frees_garbage_and_preserves_roots(h):
    live = h.alloc_int(4)
    garbage = h.alloc_int(4)
    h.rs_push(live)                          # root only `live`
    h.call("gc_collect")
    assert _flags(h, live) == 0              # MARKED set then cleared by sweep
    assert _free_list(h) == [garbage]


# --- alloc reuses from free list --------------------------------------------

def test_alloc_reuses_freed_handle(h):
    original = h.alloc_int(4)
    next_handle_after_first = h.read_word(NEXT_HANDLE_ZP)
    h.call("gc_sweep")                       # no root → free it
    assert _free_list(h) == [original]
    # Next alloc should reuse the freed handle — NEXT_HANDLE should NOT decrement.
    reused = h.alloc_int(4)
    assert reused == original
    assert h.read_word(NEXT_HANDLE_ZP) == next_handle_after_first
    assert h.read_word(FREE_HEAD_ZP) == 0


def test_alloc_reuses_in_lifo_order(h):
    h1 = h.alloc_int(2)
    h2 = h.alloc_int(2)
    h3 = h.alloc_int(2)
    h.call("gc_sweep")
    # FREE_HEAD order after top-down sweep: h1 (highest addr) linked first →
    # ends up deepest. FREE_HEAD points to h3 (last allocated, lowest addr).
    assert _free_list(h) == [h3, h2, h1]
    assert h.alloc_int(2) == h3
    assert h.alloc_int(2) == h2
    assert h.alloc_int(2) == h1
    assert h.read_word(FREE_HEAD_ZP) == 0


def test_alloc_falls_back_to_carve_when_free_list_empty(h):
    # Prime: alloc one, free it via sweep, reuse, then alloc again → carves.
    first = h.alloc_int(2)
    h.call("gc_sweep")
    reused = h.alloc_int(2)
    assert reused == first
    # Free list now empty — the next alloc must carve a fresh handle.
    next_handle_before = h.read_word(NEXT_HANDLE_ZP)
    fresh = h.alloc_int(2)
    assert fresh == next_handle_before - 8
    assert h.read_word(NEXT_HANDLE_ZP) == next_handle_before - 8


def test_alloc_after_collect_cycle(h):
    a = h.alloc_int(4)
    b = h.alloc_int(4)
    h.rs_push(b)                             # keep b alive
    h.call("gc_collect")
    # a is free; b is live with clean flags.
    assert _free_list(h) == [a]
    assert _flags(h, b) == 0
    # Next alloc reuses a.
    c = h.alloc_int(4)
    assert c == a


# --- new handle gets clean state after reuse --------------------------------

def test_reused_handle_has_cleared_h_next(h):
    # Sanity: after sweep threads H_NEXT, alloc must reset it to 0 for the
    # new object so it doesn't look like a free-list node.
    h1 = h.alloc_int(2)
    h2 = h.alloc_int(2)
    h.call("gc_sweep")
    assert _h_next(h, h2) == h1              # threaded by sweep
    # Reuse h2.
    reused = h.alloc_int(2)
    assert reused == h2
    assert _h_next(h, reused) == 0           # cleaned by alloc
