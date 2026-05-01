"""Tests for int_add — variable-length signed integer addition."""

from __future__ import annotations

from conftest import RV, W0, W1

# Must stay in sync with src/defs.asm
H_PTR = 0
H_SIZE = 2
H_NEXT = 4
H_TYPE = 6
H_FLAGS = 7
SIZEOF_HANDLE = 8

O_LEN = 0
O_HEADER = 2

TYPE_INT = 0x20


def place_int(h, addr: int, magnitude: list[int]) -> int:
    """Hand-place an int handle+object pair starting at `addr`. Returns handle address.

    Used for setting up test inputs without going through the allocator.
    """
    handle_addr = addr
    object_addr = addr + SIZEOF_HANDLE

    h.write_word(handle_addr + H_PTR, object_addr)
    h.write_word(handle_addr + H_SIZE, O_HEADER + len(magnitude))
    h.write_word(handle_addr + H_NEXT, 0)
    h.mpu.memory[handle_addr + H_TYPE] = TYPE_INT
    h.mpu.memory[handle_addr + H_FLAGS] = 0

    h.write_word(object_addr + O_LEN, len(magnitude))
    h.write_bytes(object_addr + O_HEADER, magnitude)
    return handle_addr


def read_int(h, handle_addr: int) -> list[int]:
    """Follow a handle → heap object → payload. Returns the magnitude bytes."""
    payload_ptr = h.read_word(handle_addr + H_PTR)
    length = h.read_word(payload_ptr + O_LEN)
    return h.read_bytes(payload_ptr + O_HEADER, length)


def run_add(h, a_bytes: list[int], b_bytes: list[int]) -> list[int]:
    """Invoke int_add via V3' ABI: args on RS, result in RV."""
    rsp_initial = h.rsp
    a = place_int(h, 0x8500, a_bytes)
    b = place_int(h, 0x9100, b_bytes)
    h.rs_push(a)
    h.rs_push(b)
    h.call("int_add")
    # Callee pops its args. RS should be back to the initial level.
    assert h.rsp == rsp_initial, (
        f"int_add violated stack discipline: expected RSP=${rsp_initial:04X}, "
        f"got ${h.rsp:04X}"
    )
    result_handle = h.read_word(RV)
    return read_int(h, result_handle)


# --- Cases -----------------------------------------------------------------


def test_1_plus_1(h):
    assert run_add(h, [0x01], [0x01]) == [0x02]


def test_0_plus_0(h):
    assert run_add(h, [0x00], [0x00]) == [0x00]


def test_127_plus_1_promotes_to_two_bytes(h):
    assert run_add(h, [0x7F], [0x01]) == [0x80, 0x00]


def test_neg1_plus_neg1(h):
    assert run_add(h, [0xFF], [0xFF]) == [0xFE]


def test_256_plus_neg1(h):
    assert run_add(h, [0x00, 0x01], [0xFF]) == [0xFF, 0x00]


def test_short_plus_long_negative(h):
    assert run_add(h, [0x01], [0x00, 0x80]) == [0x01, 0x80]


def test_neg1_plus_1(h):
    assert run_add(h, [0xFF], [0x01]) == [0x00]


def test_max_pos_plus_1_grows(h):
    assert run_add(h, [0xFF, 0x7F], [0x01]) == [0x00, 0x80, 0x00]
