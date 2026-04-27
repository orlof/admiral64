"""Tests for the GC mark phase — walks RS, sets FLAG_MARKED on roots."""

from __future__ import annotations

from conftest import (
    FSP_ZP,
    RSP_ZP,
    TYPE_INT,
)

FLAG_MARKED = 0x80
FLAG_PINNED = 0x20
H_FLAGS = 7


def _flags(h, handle: int) -> int:
    return h.mpu.memory[handle + H_FLAGS]


# --- trivial cases -----------------------------------------------------------

def test_empty_rs_is_noop(h):
    rsp_before = h.rsp
    fsp_before = h.read_word(FSP_ZP)
    h.call("gc_mark")
    assert h.rsp == rsp_before
    assert h.read_word(FSP_ZP) == fsp_before


# --- single root -------------------------------------------------------------

def test_single_rooted_handle_gets_marked(h):
    handle = h.alloc_int(4)
    assert _flags(h, handle) == 0           # fresh
    h.rs_push(handle)
    h.call("gc_mark")
    assert _flags(h, handle) == FLAG_MARKED


# --- many roots --------------------------------------------------------------

def test_multiple_roots_all_marked(h):
    handles = [h.alloc_int(n) for n in (2, 4, 6, 8)]
    for hdl in handles:
        h.rs_push(hdl)
    h.call("gc_mark")
    for hdl in handles:
        assert _flags(h, hdl) == FLAG_MARKED


# --- unrooted handles -------------------------------------------------------

def test_unrooted_handle_stays_unmarked(h):
    rooted = h.alloc_int(4)
    garbage = h.alloc_int(4)
    h.rs_push(rooted)                       # only root `rooted`
    h.call("gc_mark")
    assert _flags(h, rooted) == FLAG_MARKED
    assert _flags(h, garbage) == 0


# --- idempotence / flag preservation ----------------------------------------

def test_mark_is_idempotent(h):
    handle = h.alloc_int(4)
    h.rs_push(handle)
    h.call("gc_mark")
    h.call("gc_mark")
    assert _flags(h, handle) == FLAG_MARKED


def test_mark_preserves_other_flag_bits(h):
    handle = h.alloc_int(4)
    h.mpu.memory[handle + H_FLAGS] = FLAG_PINNED
    h.rs_push(handle)
    h.call("gc_mark")
    assert _flags(h, handle) == (FLAG_PINNED | FLAG_MARKED)


# --- stack state -------------------------------------------------------------

def test_gc_mark_does_not_touch_rsp_fsp(h):
    handle = h.alloc_int(4)
    h.rs_push(handle)
    rsp_before = h.rsp
    fsp_before = h.read_word(FSP_ZP)
    h.call("gc_mark")
    assert h.rsp == rsp_before
    assert h.read_word(FSP_ZP) == fsp_before


def test_same_handle_rooted_twice_marked_once(h):
    # If a handle is on RS more than once (shared scope), mark still produces
    # the same end state — FLAG_MARKED set, nothing corrupted.
    handle = h.alloc_int(4)
    h.rs_push(handle)
    h.rs_push(handle)
    h.call("gc_mark")
    assert _flags(h, handle) == FLAG_MARKED
