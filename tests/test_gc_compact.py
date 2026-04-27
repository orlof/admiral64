"""Tests for gc_compact — sliding compaction of live heap data."""

from __future__ import annotations

from conftest import (
    FREE_HEAD_ZP,
    HEAP_DATA_START,
    HEAP_HANDLE_START,
    NEXT_DATA_ZP,
    RESERVED_HEAD_ZP,
    RESERVED_TAIL_ZP,
    TYPE_INT,
)

FLAG_MARKED = 0x80
O_HEADER = 2

H_PTR = 0
H_SIZE = 2
H_NEXT = 4
H_FLAGS = 7


def _h_ptr(h, handle: int) -> int:
    return h.read_word(handle + H_PTR)


def _h_size(h, handle: int) -> int:
    return h.read_word(handle + H_SIZE)


def _h_next(h, handle: int) -> int:
    return h.read_word(handle + H_NEXT)


def _flags(h, handle: int) -> int:
    return h.mpu.memory[handle + H_FLAGS]


def _reserved_list(h) -> list[int]:
    out = []
    node = h.read_word(RESERVED_HEAD_ZP)
    while node != 0:
        out.append(node)
        node = _h_next(h, node)
    return out


def _mark(h, handle: int) -> None:
    """Set FLAG_MARKED on a handle (simulating post-gc_mark state)."""
    h.mpu.memory[handle + H_FLAGS] |= FLAG_MARKED


# --- trivial cases -----------------------------------------------------------

def test_compact_empty_heap_is_noop(h):
    h.call("gc_compact")
    assert h.read_word(NEXT_DATA_ZP) == HEAP_DATA_START


def test_compact_single_live_handle_stays_in_place(h):
    handle = h.alloc_int(4)                 # payload at $8500, 4+2=6 bytes
    ptr_before = _h_ptr(h, handle)
    h.call("gc_compact")
    assert _h_ptr(h, handle) == ptr_before
    assert h.read_word(NEXT_DATA_ZP) == HEAP_DATA_START + 6


# --- packed live data → no moves --------------------------------------------

def test_compact_contiguous_live_handles_stay_put(h):
    handles = [h.alloc_int(n) for n in (4, 6, 8)]
    ptrs_before = [_h_ptr(h, x) for x in handles]
    next_data_before = h.read_word(NEXT_DATA_ZP)
    h.call("gc_compact")
    for hdl, p in zip(handles, ptrs_before):
        assert _h_ptr(h, hdl) == p          # nothing moved
    assert h.read_word(NEXT_DATA_ZP) == next_data_before


# --- holes get closed (via sweep-then-compact) -----------------------------

def test_compact_slides_survivor_over_freed_block(h):
    h.alloc_int(10)                         # garbage
    live = h.alloc_int(4)
    _mark(h, live)                          # simulate post-mark state
    h.call("gc_sweep")                      # garbage → free; live stays live
    h.call("gc_compact")
    assert _h_ptr(h, live) == HEAP_DATA_START
    assert h.read_word(NEXT_DATA_ZP) == HEAP_DATA_START + 6


def test_compact_preserves_payload_bytes(h):
    h.alloc_int(10)                         # garbage
    live = h.alloc_int(4)
    live_payload = _h_ptr(h, live) + O_HEADER
    h.write_bytes(live_payload, [0xAA, 0xBB, 0xCC, 0xDD])
    _mark(h, live)
    h.call("gc_sweep")
    h.call("gc_compact")
    new_payload = HEAP_DATA_START + O_HEADER
    assert h.read_bytes(new_payload, 4) == [0xAA, 0xBB, 0xCC, 0xDD]
    # Length header moved too.
    assert h.read_word(HEAP_DATA_START) == 4


def test_compact_closes_multiple_holes(h):
    a = h.alloc_int(4)                      # $8500, 6 bytes
    b = h.alloc_int(4)                      # $8506, 6 bytes
    c = h.alloc_int(4)                      # $850C, 6 bytes
    d = h.alloc_int(4)                      # $8512, 6 bytes
    # b and d survive; a and c are garbage.
    _mark(h, b)
    _mark(h, d)
    h.call("gc_sweep")
    h.call("gc_compact")
    assert _h_ptr(h, b) == HEAP_DATA_START           # b slides to $8500
    assert _h_ptr(h, d) == HEAP_DATA_START + 6       # d slides to $8506
    assert h.read_word(NEXT_DATA_ZP) == HEAP_DATA_START + 12


# --- compact only walks the reserved list -----------------------------------

def test_compact_ignores_free_list_handles(h):
    """Sweep moves a handle to the free list; compact must not touch it,
    even though FREE_HEAD is a distinct pointer from RESERVED_HEAD."""
    garbage = h.alloc_int(10)
    live = h.alloc_int(4)
    _mark(h, live)
    h.call("gc_sweep")
    # After sweep: garbage on free list, live on reserved list.
    garbage_ptr_before = _h_ptr(h, garbage)
    h.call("gc_compact")
    # Compact didn't rewrite the garbage handle's H_PTR.
    assert _h_ptr(h, garbage) == garbage_ptr_before
    # live is at the start of the heap.
    assert _h_ptr(h, live) == HEAP_DATA_START


# --- out-of-order handle addresses still work -------------------------------

def test_compact_handles_addresses_distinct_from_h_ptr_order(h):
    """After free-list reuse, handle addresses and H_PTRs can diverge. As
    long as the reserved list is in H_PTR-ascending order (alloc's invariant),
    compact works correctly."""
    h1 = h.alloc_int(4)                     # handle $BFF8, data $8500
    h2 = h.alloc_int(4)                     # handle $BFF0, data $8506
    h.call("gc_sweep")                      # both freed (no marks)
    reused2 = h.alloc_int(4)                # reuses h2 (LIFO pop)
    reused1 = h.alloc_int(4)                # reuses h1
    # Reserved list order = alloc order = H_PTR order ($850C, $8512).
    assert _reserved_list(h) == [reused2, reused1]
    assert _h_ptr(h, reused2) == 0x850C
    assert _h_ptr(h, reused1) == 0x8512
    h.call("gc_compact")
    assert _h_ptr(h, reused2) == HEAP_DATA_START
    assert _h_ptr(h, reused1) == HEAP_DATA_START + 6
    assert h.read_word(NEXT_DATA_ZP) == HEAP_DATA_START + 12


# --- idempotence ------------------------------------------------------------

def test_compact_is_idempotent(h):
    handles = [h.alloc_int(n) for n in (4, 6, 8)]
    _mark(h, handles[0])
    _mark(h, handles[2])
    h.call("gc_sweep")                      # handles[1] moves to free
    h.call("gc_compact")
    first_ptrs = [_h_ptr(h, x) for x in (handles[0], handles[2])]
    first_next = h.read_word(NEXT_DATA_ZP)
    h.call("gc_compact")                    # second pass — nothing to do
    second_ptrs = [_h_ptr(h, x) for x in (handles[0], handles[2])]
    second_next = h.read_word(NEXT_DATA_ZP)
    assert first_ptrs == second_ptrs
    assert first_next == second_next


# --- full gc_collect cycle --------------------------------------------------

def test_gc_collect_compacts_after_sweep(h):
    a = h.alloc_int(100)
    b = h.alloc_int(50)
    c = h.alloc_int(30)
    h.rs_push(b)                            # only b is rooted
    h.call("gc_collect")                    # mark + sweep + compact
    assert _h_ptr(h, b) == HEAP_DATA_START
    assert h.read_word(NEXT_DATA_ZP) == HEAP_DATA_START + 52
    assert _reserved_list(h) == [b]
    # a and c are on the free list.
    free = set()
    node = h.read_word(FREE_HEAD_ZP)
    while node != 0:
        free.add(node)
        node = _h_next(h, node)
    assert free == {a, c}


def test_compact_enables_large_alloc_after_freeing_live_data(h):
    """Stage-4 payoff: compaction reclaims data bytes, letting a subsequent
    alloc exceed what was possible before GC."""
    h.alloc_int(12000)                      # unrooted
    result = h.alloc_int(10_000)
    assert result != 0
    assert h.read_word(FREE_HEAD_ZP) == 0
