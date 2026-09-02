"""EDIT() as a disk-loaded v2 TYPE_CODE plugin — interpreter-level tests.

Moved from test_parser.py when EDIT left the kernel. Same GETIN key-queue
stubbing; the editor now arrives via LOAD("EDIT") from the KernalDiskMock.
"""
from __future__ import annotations

import pytest

from test_parser import _stub_getin_queue, _eval_to_str, place_str
from conftest import RV

pytestmark = []


@pytest.fixture
def he(hd, edit_plugin_record):
    hd.kernal_mock.files[b"EDIT"] = edit_plugin_record
    return hd


LOADE = 'E = LOAD("EDIT")\n'

# --- edit() builtin --------------------------------------------------------

F1_SAVE = 0x85
F3_CANCEL = 0x86


def test_edit_no_arg_save_immediate(he):
    """edit() with F1 immediately → empty STR."""
    _stub_getin_queue(he, bytes([F1_SAVE]))
    assert _eval_to_str(he, LOADE + 'E()') == b''


def test_edit_with_text_save_unchanged(he):
    """edit("hello") + F1 → 'hello'."""
    _stub_getin_queue(he, bytes([F1_SAVE]))
    assert _eval_to_str(he, LOADE + 'E("hello")') == b'hello'


def test_edit_with_long_text_preload(he):
    """edit(long_str) preserves the full string (was byte-truncated at 256)."""
    _stub_getin_queue(he, bytes([F1_SAVE]))
    src = LOADE + 's = "k" * 400\nE(s)'
    assert _eval_to_str(he, src, max_steps=20_000_000) == b'k' * 400


def test_edit_type_chars_then_save(he):
    """edit() + 'A' 'B' + F1 → 'AB'. Typed bytes pass through verbatim:
    PETSCII uppercase $41-$5A is the platform's native encoding."""
    _stub_getin_queue(he, b'AB' + bytes([F1_SAVE]))
    assert _eval_to_str(he, LOADE + 'E()') == b'AB'


def test_edit_bs_removes_last_char(he):
    """edit() + 'X' + BS + 'Y' + F1 → 'Y'."""
    _stub_getin_queue(he, b'X\x14Y' + bytes([F1_SAVE]))
    assert _eval_to_str(he, LOADE + 'E()') == b'Y'


def test_edit_cancel_returns_original(he):
    """edit('orig') + F3 → 'orig' (cancel returns the input arg)."""
    _stub_getin_queue(he, bytes([F3_CANCEL]))
    assert _eval_to_str(he, LOADE + 'E("orig")') == b'orig'


def test_edit_cancel_no_arg_returns_empty(he):
    """edit() + F3 → empty STR."""
    _stub_getin_queue(he, bytes([F3_CANCEL]))
    assert _eval_to_str(he, LOADE + 'E()') == b''


def test_edit_wrong_arg_type_panics(he):
    """edit(123) panics ERR_TYPE."""
    from conftest import ERROR_CODE_ZP, ERR_TYPE
    payload = list((LOADE + 'E(123)').encode("ascii"))
    handle = place_str(he, 0x8900, payload)
    he.rs_push(handle)
    with pytest.raises(Exception):
        he.call("parser_eval", max_steps=2_000_000)
    assert he.mpu.memory[ERROR_CODE_ZP] == ERR_TYPE


def test_edit_type_into_existing(he):
    """edit('AB') + cursor-left + 'X' + F1 → 'AXB'. Both seeded and typed
    bytes pass through verbatim post-charset migration."""
    CRSR_LEFT = 0x9D
    _stub_getin_queue(he, bytes([CRSR_LEFT, ord('X'), F1_SAVE]))
    assert _eval_to_str(he, LOADE + 'E("AB")') == b'AXB'


# --- edit() Phase E: kill / yank -------------------------------------------

F5_KILL = 0x87
F7_YANK = 0x88


def test_edit_kill_to_eol(he):
    """edit('hello') → cursor at end. Move left 5x → at start. F5 kills
    the whole line, save → ''."""
    CRSR_LEFT = 0x9D
    _stub_getin_queue(he, bytes([CRSR_LEFT] * 5 + [F5_KILL, F1_SAVE]))
    assert _eval_to_str(he, LOADE + 'E("hello")') == b''


def test_edit_yank_after_kill(he):
    """edit('hello') + 5 left + F5 + F7 + F1 → 'hello' (killed text yanked
    back at the same cursor position)."""
    CRSR_LEFT = 0x9D
    _stub_getin_queue(he, bytes([CRSR_LEFT] * 5 + [F5_KILL, F7_YANK, F1_SAVE]))
    assert _eval_to_str(he, LOADE + 'E("hello")') == b'hello'


def test_edit_yank_at_different_position(he):
    """edit('AB') + F5 (kill 'AB') + cursor-left + F7 → 'AB' inserted at start.
    But cursor-left at start is no-op, so still 'AB'."""
    CRSR_LEFT = 0x9D
    _stub_getin_queue(he, bytes([F5_KILL, CRSR_LEFT, F7_YANK, F1_SAVE]))
    assert _eval_to_str(he, LOADE + 'E("AB")') == b'AB'


def test_edit_yank_with_no_clip_is_noop(he):
    """edit('X') + F7 (no kill yet) + F1 → 'X'."""
    _stub_getin_queue(he, bytes([F7_YANK, F1_SAVE]))
    assert _eval_to_str(he, LOADE + 'E("X")') == b'X'


