"""Tests for str_alloc — TYPE_STR heap objects.

Strings share the heap layout with ints (H_PTR+H_SIZE+H_NEXT+H_TYPE+H_FLAGS;
[O_LEN, payload...]), so the machinery is identical — what's tested here is
the type tag plumbing and that strings survive GC like any other heap object.
"""

from __future__ import annotations

from conftest import RV, TYPE_STR
from test_int_add import (
    H_FLAGS,
    H_PTR,
    H_SIZE,
    H_TYPE,
    O_HEADER,
    O_LEN,
    SIZEOF_HANDLE,
)


def place_str(h, addr: int, payload: list[int]) -> int:
    """Hand-place a string handle+object pair at `addr`. Returns handle address."""
    handle_addr = addr
    object_addr = addr + SIZEOF_HANDLE

    h.write_word(handle_addr + H_PTR, object_addr)
    h.write_word(handle_addr + H_SIZE, O_HEADER + len(payload))
    h.write_word(handle_addr + 4, 0)  # H_NEXT
    h.mpu.memory[handle_addr + H_TYPE] = TYPE_STR
    h.mpu.memory[handle_addr + H_FLAGS] = 0

    h.write_word(object_addr + O_LEN, len(payload))
    h.write_bytes(object_addr + O_HEADER, payload)
    return handle_addr


def read_str(h, handle_addr: int) -> list[int]:
    """Read payload bytes of a string handle, trusting O_LEN."""
    obj = h.read_word(handle_addr + H_PTR)
    length = h.read_word(obj + O_LEN)
    return h.read_bytes(obj + O_HEADER, length)


# --- basic alloc --------------------------------------------------------------

def test_alloc_str_sets_type_tag(h):
    handle = h.alloc_str(5)
    assert h.mpu.memory[handle + H_TYPE] == TYPE_STR


def test_alloc_str_sets_h_size_with_header(h):
    handle = h.alloc_str(5)
    assert h.read_word(handle + H_SIZE) == O_HEADER + 5


def test_alloc_str_sets_o_len(h):
    handle = h.alloc_str(5)
    obj = h.read_word(handle + H_PTR)
    assert h.read_word(obj + O_LEN) == 5


def test_alloc_str_zero_length(h):
    handle = h.alloc_str(0)
    assert h.mpu.memory[handle + H_TYPE] == TYPE_STR
    obj = h.read_word(handle + H_PTR)
    assert h.read_word(obj + O_LEN) == 0


def test_alloc_str_payload_round_trip(h):
    handle = h.alloc_str(5)
    obj = h.read_word(handle + H_PTR)
    # "HELLO" in raw ASCII.
    h.write_bytes(obj + O_HEADER, [0x48, 0x45, 0x4C, 0x4C, 0x4F])
    assert read_str(h, handle) == [0x48, 0x45, 0x4C, 0x4C, 0x4F]


# --- GC interaction -----------------------------------------------------------

def test_rooted_string_survives_collect(h):
    handle = h.alloc_str(5)
    obj = h.read_word(handle + H_PTR)
    h.write_bytes(obj + O_HEADER, [0x41, 0x42, 0x43, 0x44, 0x45])
    h.rs_push(handle)

    h.call("gc_collect")

    # Handle address is stable; payload pointer may have moved but contents intact.
    assert read_str(h, handle) == [0x41, 0x42, 0x43, 0x44, 0x45]
    assert h.mpu.memory[handle + H_TYPE] == TYPE_STR


def test_unrooted_string_is_collected(h):
    handle = h.alloc_str(5)
    # Not pushed to RS — garbage.
    h.call("gc_collect")
    # Handle moved to FREE_HEAD; re-alloc reuses it.
    reused = h.alloc_str(3)
    assert reused == handle


def test_string_compacts_over_freed_data(h):
    # Allocate garbage, live string, more garbage — collect — verify string
    # payload moved (was not the first slot) and bytes are intact.
    _garbage1 = h.alloc_str(10)
    live = h.alloc_str(4)
    live_obj = h.read_word(live + H_PTR)
    h.write_bytes(live_obj + O_HEADER, [0xDE, 0xAD, 0xBE, 0xEF])
    _garbage2 = h.alloc_str(10)

    h.rs_push(live)
    h.call("gc_collect")

    # Payload should now sit at HEAP_DATA_START (first live slot).
    new_obj = h.read_word(live + H_PTR)
    assert new_obj < live_obj  # moved down
    assert read_str(h, live) == [0xDE, 0xAD, 0xBE, 0xEF]


def test_str_and_int_coexist_across_gc(h):
    # Both types live through a collect; tags preserved.
    s = h.alloc_str(3)
    s_obj = h.read_word(s + H_PTR)
    h.write_bytes(s_obj + O_HEADER, [0x48, 0x49, 0x21])  # "HI!"
    i = h.alloc_int(2)
    i_obj = h.read_word(i + H_PTR)
    h.write_bytes(i_obj + O_HEADER, [0xE8, 0x03])  # 1000, little-endian

    h.rs_push(s)
    h.rs_push(i)
    h.call("gc_collect")

    assert h.mpu.memory[s + H_TYPE] == TYPE_STR
    assert read_str(h, s) == [0x48, 0x49, 0x21]
    i_obj_new = h.read_word(i + H_PTR)
    assert h.read_bytes(i_obj_new + O_HEADER, 2) == [0xE8, 0x03]


# --- place_str helper round-trips --------------------------------------------

def test_place_str_round_trip(h):
    handle = place_str(h, 0x8900, [0x41, 0x42, 0x43])
    assert h.mpu.memory[handle + H_TYPE] == TYPE_STR
    assert read_str(h, handle) == [0x41, 0x42, 0x43]
