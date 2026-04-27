"""Tests for the reserved handle list — alloc appends, sweep filters."""

from __future__ import annotations

from conftest import (
    FREE_HEAD_ZP,
    RESERVED_HEAD_ZP,
    RESERVED_TAIL_ZP,
    TYPE_INT,
)

FLAG_MARKED = 0x80

H_NEXT = 4
H_FLAGS = 7


def _h_next(h, handle: int) -> int:
    return h.read_word(handle + H_NEXT)


def _reserved_list(h) -> list[int]:
    out = []
    node = h.read_word(RESERVED_HEAD_ZP)
    while node != 0:
        out.append(node)
        node = _h_next(h, node)
    return out


def _free_list(h) -> list[int]:
    out = []
    node = h.read_word(FREE_HEAD_ZP)
    while node != 0:
        out.append(node)
        node = _h_next(h, node)
    return out


def _mark(h, handle: int) -> None:
    h.mpu.memory[handle + H_FLAGS] |= FLAG_MARKED


# --- alloc_init --------------------------------------------------------------

def test_init_empty_reserved_list(h):
    assert h.read_word(RESERVED_HEAD_ZP) == 0
    assert h.read_word(RESERVED_TAIL_ZP) == 0


# --- alloc appends to tail ---------------------------------------------------

def test_first_alloc_sets_head_and_tail(h):
    handle = h.alloc_int(2)
    assert h.read_word(RESERVED_HEAD_ZP) == handle
    assert h.read_word(RESERVED_TAIL_ZP) == handle
    assert _h_next(h, handle) == 0


def test_multiple_allocs_chain_in_order(h):
    handles = [h.alloc_int(n) for n in (2, 4, 6, 8)]
    assert _reserved_list(h) == handles
    assert h.read_word(RESERVED_HEAD_ZP) == handles[0]
    assert h.read_word(RESERVED_TAIL_ZP) == handles[-1]


def test_reuse_reappends_to_tail(h):
    """After free-list reuse, the handle's address may decrease but its
    position in the reserved list is still the tail — which keeps the list
    in H_PTR-ascending order because data grows up monotonically."""
    h1 = h.alloc_int(2)                      # handle $BFF8
    h2 = h.alloc_int(2)                      # handle $BFF0
    h.call("gc_sweep")                       # both freed
    reused_h2 = h.alloc_int(2)
    reused_h1 = h.alloc_int(2)
    assert reused_h2 == h2                   # LIFO pop
    assert reused_h1 == h1
    # List order is alloc order; tail is the most-recent alloc.
    assert _reserved_list(h) == [reused_h2, reused_h1]
    assert h.read_word(RESERVED_TAIL_ZP) == reused_h1


# --- sweep splits the list ---------------------------------------------------

def test_sweep_keeps_survivors_in_original_order(h):
    a = h.alloc_int(2)
    b = h.alloc_int(2)
    c = h.alloc_int(2)
    d = h.alloc_int(2)
    _mark(h, a)
    _mark(h, c)
    h.call("gc_sweep")
    assert _reserved_list(h) == [a, c]
    assert h.read_word(RESERVED_TAIL_ZP) == c
    # Garbage goes onto free list.
    assert set(_free_list(h)) == {b, d}


def test_sweep_empties_reserved_when_nothing_marked(h):
    handles = [h.alloc_int(2) for _ in range(3)]
    h.call("gc_sweep")
    assert _reserved_list(h) == []
    assert h.read_word(RESERVED_HEAD_ZP) == 0
    assert h.read_word(RESERVED_TAIL_ZP) == 0
    assert set(_free_list(h)) == set(handles)


def test_sweep_leaves_all_when_all_marked(h):
    handles = [h.alloc_int(2) for _ in range(3)]
    for hdl in handles:
        _mark(h, hdl)
    h.call("gc_sweep")
    assert _reserved_list(h) == handles
    assert _free_list(h) == []


# --- tail pointer is correct after reuse -------------------------------------

def test_tail_updated_after_sweep_and_reuse(h):
    a = h.alloc_int(2)
    b = h.alloc_int(2)
    _mark(h, a)                              # b is garbage
    h.call("gc_sweep")
    assert h.read_word(RESERVED_TAIL_ZP) == a
    # New alloc should append after a.
    c = h.alloc_int(2)
    assert _reserved_list(h) == [a, c]
    assert h.read_word(RESERVED_TAIL_ZP) == c
