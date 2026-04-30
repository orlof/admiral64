"""Tests for the bump allocator — success paths and OOM panic."""

from __future__ import annotations

from conftest import (
    ERR_OOM,
    HEAP_DATA_START,
    HEAP_HANDLE_START,
    NEXT_DATA_ZP,
    NEXT_HANDLE_ZP,
    TYPE_INT,
)

SIZEOF_HANDLE = 8
O_HEADER = 2

H_PTR = 0
H_SIZE = 2
H_NEXT = 4
H_TYPE = 6
H_FLAGS = 7


def _force_near_oom(h, gap: int) -> None:
    """Shrink the heap gap to `gap` bytes via a real rooted alloc.
    Going through the allocator keeps invariants consistent: gc_compact sees
    a valid live handle that it must preserve, so the gap is unrecoverable.
    """
    h.force_gap(gap)


# --- fresh state -------------------------------------------------------------

def test_alloc_init_sets_pointers(h):
    assert h.read_word(NEXT_DATA_ZP) == HEAP_DATA_START
    assert h.read_word(NEXT_HANDLE_ZP) == HEAP_HANDLE_START


# --- single successful alloc -------------------------------------------------

def test_alloc_returns_handle_and_advances_pointers(h):
    handle = h.alloc(10, TYPE_INT)
    assert handle == HEAP_HANDLE_START - SIZEOF_HANDLE
    assert h.read_word(NEXT_HANDLE_ZP) == HEAP_HANDLE_START - SIZEOF_HANDLE
    assert h.read_word(NEXT_DATA_ZP) == HEAP_DATA_START + 10 + O_HEADER


def test_alloc_populates_handle_struct(h):
    handle = h.alloc(10, TYPE_INT)
    assert h.read_word(handle + H_PTR) == HEAP_DATA_START
    assert h.read_word(handle + H_SIZE) == 10 + O_HEADER
    assert h.read_word(handle + H_NEXT) == 0
    assert h.mpu.memory[handle + H_TYPE] == TYPE_INT
    assert h.mpu.memory[handle + H_FLAGS] == 0
    assert h.read_word(HEAP_DATA_START) == 10  # O_LEN header


def test_multiple_allocs_chain(h):
    h1 = h.alloc(10, TYPE_INT)
    h2 = h.alloc(20, TYPE_INT)
    assert h2 == h1 - SIZEOF_HANDLE
    assert h.read_word(NEXT_DATA_ZP) == HEAP_DATA_START + 12 + 22


# --- 16-bit sizes ------------------------------------------------------------

def test_alloc_large_size_succeeds(h):
    handle = h.alloc(1000, TYPE_INT)
    assert handle == HEAP_HANDLE_START - SIZEOF_HANDLE
    assert h.read_word(handle + H_SIZE) == 1000 + O_HEADER
    assert h.read_word(HEAP_DATA_START) == 1000  # O_LEN stored as word
    assert h.read_word(NEXT_DATA_ZP) == HEAP_DATA_START + 1000 + O_HEADER


def test_alloc_size_crosses_byte_boundary(h):
    # 256 exactly: low byte 0, high byte 1 — ensures H_SIZE/O_LEN propagate carry.
    handle = h.alloc(256, TYPE_INT)
    assert h.read_word(handle + H_SIZE) == 256 + O_HEADER
    assert h.read_word(HEAP_DATA_START) == 256
    assert h.read_word(NEXT_DATA_ZP) == HEAP_DATA_START + 256 + O_HEADER


# --- OOM (gap exhaustion) → panic -------------------------------------------

def test_alloc_exact_fit_succeeds(h):
    _force_near_oom(h, 11)  # need = 1 + 2 + 8 = 11
    handle = h.alloc(1, TYPE_INT)
    assert handle != 0


def test_alloc_one_byte_short_panics_oom(h):
    _force_near_oom(h, 10)
    h.alloc_panics(1, TYPE_INT, ERR_OOM)


def test_alloc_gap_overflow_panics_oom(h):
    # Fresh heap gap is ~30 KB ($FFF8 - $8800). Ask for 32 KB — definite OOM.
    h.alloc_panics(32_000, TYPE_INT, ERR_OOM)


# --- OOM (need-overflow, 17th-bit carry) → panic ----------------------------

def test_alloc_near_max_16bit_panics_via_need_overflow(h):
    # size = $FFFF: need = $FFFF + 10 = $10009 → 17-bit carry → panic.
    h.alloc_panics(0xFFFF, TYPE_INT, ERR_OOM)


def test_alloc_size_fff6_boundary(h):
    # size = $FFF6: need = $FFF6 + 10 = $10000 → carries. Panic.
    h.alloc_panics(0xFFF6, TYPE_INT, ERR_OOM)


def test_alloc_size_fff5_no_need_overflow_but_still_panics(h):
    # size = $FFF5: need = $FFFF (no carry). Gap check catches it.
    h.alloc_panics(0xFFF5, TYPE_INT, ERR_OOM)


# --- alloc_int wrapper -------------------------------------------------------

def test_alloc_int_uses_type_int(h):
    handle = h.alloc_int(5)
    assert h.mpu.memory[handle + H_TYPE] == TYPE_INT
