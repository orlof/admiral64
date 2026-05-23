"""PEEK / POKE accept an integer address.

Previously the address argument went through deref_W0_to_W2, which assumes a
heap-allocated payload (string/list). For an inline int H_PTR holds the value
itself, not a heap pointer, so the deref chased a random address and POKE/PEEK
operated on the wrong memory.
"""

from __future__ import annotations

from conftest import RV


def _eval_int(h, src: str, max_steps: int = 2_000_000) -> int:
    payload = list(src.encode("ascii"))
    handle = h.alloc_str(len(payload))
    h.write_bytes(h.read_word(handle) + 2, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=max_steps)
    rv = h.read_word(RV)
    return h.read_word(rv) | (h.read_word(rv + 2) << 16)


def test_poke_writes_to_int_address(h):
    # Pick a low-RAM byte unlikely to matter ($02C0 is in the cassette buffer's
    # tape-header area; the REPL only uses $033C+).
    _eval_int(h, "POKE(704, 42)\n0")
    assert h.mpu.memory[704] == 42


def test_poke_writes_to_io_register(h):
    # py65 doesn't bank, so writes go through to RAM regardless — but the
    # value at the requested address is the relevant check. $D021 = 53281
    # (background color register).
    _eval_int(h, "POKE(53281, 7)\n0")
    assert h.mpu.memory[0xD021] == 7


def test_peek_reads_back_what_poke_wrote(h):
    assert _eval_int(h, "POKE(705, 123)\nPEEK(705)") == 123


def test_peek_returns_byte_value(h):
    # Seed RAM directly; PEEK should read it back.
    h.mpu.memory[0x0300] = 0xAB
    assert _eval_int(h, "PEEK(768)") == 0xAB


# LEN on non-heap types now type-errors instead of reading garbage. Same
# regression class as POKE — deref_W0_to_W2 chased H_PTR as a heap pointer.

def _eval_panics(h, src: str, max_steps: int = 2_000_000):
    payload = list(src.encode("ascii"))
    handle = h.alloc_str(len(payload))
    h.write_bytes(h.read_word(handle) + 2, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=max_steps, expect_panic=True)


def test_len_on_int_panics(h):
    _eval_panics(h, "LEN(42)")


def test_len_on_bool_panics(h):
    _eval_panics(h, "LEN(TRUE)")


def test_len_on_none_panics(h):
    _eval_panics(h, "LEN(NONE)")


def test_len_on_str_works(h):
    assert _eval_int(h, 'LEN("HELLO")') == 5


def test_len_on_list_works(h):
    assert _eval_int(h, 'LEN([1, 2, 3, 4])') == 4
