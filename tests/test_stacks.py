"""Tests for the root stack and frame stack infrastructure."""

from __future__ import annotations

from conftest import W0, W1, FSP_ZP, RSP_ZP

FS_END = 0x8800
RS_END = 0x8C00


# --- Init --------------------------------------------------------------------

def test_rs_init_sets_rsp_to_end(h):
    assert h.read_word(RSP_ZP) == RS_END


def test_fs_init_sets_fsp_to_end(h):
    assert h.read_word(FSP_ZP) == FS_END


# --- rs_push_w0 / rs_pop_w0 via asm wrappers --------------------------------

def test_rs_push_w0_decrements_rsp_and_writes(h):
    h.write_word(W0, 0xCAFE)
    h.call("rs_push_w0")
    assert h.read_word(RSP_ZP) == RS_END - 2
    assert h.read_word(RS_END - 2) == 0xCAFE


def test_rs_pop_w0_restores_pointer_and_reads(h):
    h.write_word(W0, 0xBABE)
    h.call("rs_push_w0")
    h.write_word(W0, 0x0000)
    h.call("rs_pop_w0")
    assert h.read_word(W0) == 0xBABE
    assert h.read_word(RSP_ZP) == RS_END


def test_rs_push_pop_roundtrip_multiple(h):
    h.write_word(W0, 0x1111)
    h.call("rs_push_w0")
    h.write_word(W0, 0x2222)
    h.call("rs_push_w0")
    h.write_word(W0, 0x3333)
    h.call("rs_push_w0")

    assert h.read_word(RSP_ZP) == RS_END - 6

    h.call("rs_pop_w0")
    assert h.read_word(W0) == 0x3333
    h.call("rs_pop_w0")
    assert h.read_word(W0) == 0x2222
    h.call("rs_pop_w0")
    assert h.read_word(W0) == 0x1111
    assert h.read_word(RSP_ZP) == RS_END


def test_rs_push_w0_w1_interleaved(h):
    h.write_word(W0, 0xAAAA)
    h.write_word(W1, 0xBBBB)
    h.call("rs_push_w0")
    h.call("rs_push_w1")

    h.write_word(W0, 0)
    h.write_word(W1, 0)

    h.call("rs_pop_w0")
    assert h.read_word(W0) == 0xBBBB
    h.call("rs_pop_w1")
    assert h.read_word(W1) == 0xAAAA


# --- Python-side helpers ----------------------------------------------------

def test_python_rs_push_pop_matches_asm(h):
    h.rs_push(0xDEAD)
    h.rs_push(0xBEEF)
    assert h.rsp == RS_END - 4
    assert h.rs_peek(0) == 0xBEEF
    assert h.rs_peek(1) == 0xDEAD
    assert h.rs_pop() == 0xBEEF
    assert h.rs_pop() == 0xDEAD
    assert h.rsp == RS_END


def test_python_rs_push_is_visible_to_asm_pop(h):
    h.rs_push(0x4242)
    h.write_word(W0, 0)
    h.call("rs_pop_w0")
    assert h.read_word(W0) == 0x4242
    assert h.rsp == RS_END
