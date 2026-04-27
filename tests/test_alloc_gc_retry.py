"""Tests for alloc's OOM-triggered GC retry."""

from __future__ import annotations

from conftest import (
    ERR_OOM,
    FREE_HEAD_ZP,
    NEXT_DATA_ZP,
    NEXT_HANDLE_ZP,
    TYPE_INT,
)

FLAG_MARKED = 0x80

H_FLAGS = 7


# --- retry succeeds by freeing an unrooted handle ---------------------------

def test_retry_succeeds_when_free_list_fills_via_sweep(h):
    """Gap is one byte too tight for a fresh-carve alloc, but an unrooted
    handle exists. GC moves it to FREE_HEAD, dropping the SIZEOF_HANDLE term
    from `need`. The retry fits."""
    garbage = h.alloc_int(4)                # lives at HEAP_HANDLE_START - 8
    handle_addr_before = h.read_word(NEXT_HANDLE_ZP)

    # Shrink gap to 10 bytes (by moving NEXT_DATA). alloc(1) needs 11 with
    # an empty free list, but only 3 once GC frees `garbage`.
    h.write_word(NEXT_DATA_ZP, h.read_word(NEXT_HANDLE_ZP) - 10)

    result = h.alloc_int(1)
    assert result == garbage                # the reused slot
    # NEXT_HANDLE was not decremented — reuse path, not a fresh carve.
    assert h.read_word(NEXT_HANDLE_ZP) == handle_addr_before
    # Free list drained.
    assert h.read_word(FREE_HEAD_ZP) == 0


# --- retry fails → panic ----------------------------------------------------

def test_retry_panics_when_all_handles_are_rooted(h):
    """Heap filled entirely by a rooted handle: mark keeps it alive, sweep
    frees nothing, compact can't shrink live data. Second OOM → panic."""
    h.force_gap(10)
    h.alloc_panics(1, TYPE_INT, ERR_OOM)


def test_retry_panics_when_data_need_exceeds_gap(h):
    """Even with compact reclaiming dead data, a single request that exceeds
    the gap between rooted data and NEXT_HANDLE cannot be satisfied."""
    h.force_gap(5)
    h.alloc_panics(10, TYPE_INT, ERR_OOM)


# --- normal path does not trigger GC ----------------------------------------

def test_successful_alloc_does_not_run_gc(h):
    """Observable via a pre-set FLAG_MARKED on an unrooted handle: sweep
    would clear it, so if the bit survives a successful alloc, GC didn't run."""
    unrooted = h.alloc_int(4)
    h.mpu.memory[unrooted + H_FLAGS] = FLAG_MARKED

    # Fresh-heap alloc with plenty of room: should succeed on first try.
    result = h.alloc_int(4)
    assert result != 0
    # Pre-set mark bit is untouched → GC didn't run.
    assert h.mpu.memory[unrooted + H_FLAGS] == FLAG_MARKED


# --- retry ordering: once, not twice ----------------------------------------

def test_retry_runs_at_most_once(h):
    """If the first GC pass doesn't produce enough room, alloc must not loop
    GC indefinitely — it panics on the second attempt, not hangs."""
    h.force_gap(10)
    h.alloc_panics(1, TYPE_INT, ERR_OOM)


# --- 16-bit overflow paths still panic on second attempt --------------------

def test_need_overflow_panics_even_with_gc_slack(h):
    """If ALLOC_SIZE is wider than the entire address space, GC can't help —
    OOM must still panic cleanly."""
    h.alloc_int(4)                          # unrooted: GC has something to do
    h.alloc_panics(0xFFFF, TYPE_INT, ERR_OOM)
