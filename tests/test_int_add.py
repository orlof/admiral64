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


def _min_twos_complement(val: int) -> list[int]:
    """Shortest little-endian two's-complement byte list for signed `val`.

    Matches the old variable-length normalization: 0 -> [0x00], 2 -> [0x02],
    -1 -> [0xFF], 1000 -> [0xE8, 0x03], -128 -> [0x80], 128 -> [0x80, 0x00].
    """
    length = 1
    while True:
        try:
            return list(val.to_bytes(length, "little", signed=True))
        except OverflowError:
            length += 1


def place_int(h, addr: int, magnitude: list[int]) -> int:
    """Hand-place an inline-int handle at `addr`. Returns the handle address.

    Fixed 32-bit inline representation: the value lives in H_PTR (lo16) +
    H_SIZE (hi16). `magnitude` is interpreted as a little-endian two's-
    complement value (the old variable-length input form) and sign-extended
    to 32 bits.
    """
    handle_addr = addr
    val = int.from_bytes(bytes(magnitude), "little", signed=True) if magnitude else 0
    val &= 0xFFFFFFFF

    h.write_word(handle_addr + H_PTR, val & 0xFFFF)
    h.write_word(handle_addr + H_SIZE, (val >> 16) & 0xFFFF)
    h.write_word(handle_addr + H_NEXT, 0)
    h.mpu.memory[handle_addr + H_TYPE] = TYPE_INT
    h.mpu.memory[handle_addr + H_FLAGS] = 0
    return handle_addr


def read_int(h, handle_addr: int) -> list[int]:
    """Read an inline int → minimal little-endian two's-complement byte list."""
    lo = h.read_word(handle_addr + H_PTR)
    hi = h.read_word(handle_addr + H_SIZE)
    val = lo | (hi << 16)
    if val & 0x8000_0000:
        val -= 0x1_0000_0000
    return _min_twos_complement(val)


def run_add(h, a_bytes: list[int], b_bytes: list[int]) -> list[int]:
    """Invoke int_add via V3' ABI: args on RS, result in RV."""
    rsp_initial = h.rsp
    a = place_int(h, 0x8800, a_bytes)
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
