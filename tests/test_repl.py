"""Tests for the REPL line editor — `_rpl_read_line` (repl.asm).

Drives the routine by intercepting `kbd_getchar` from Python. Each test
defines a sequence of PETSCII bytes the "user typed"; the driver injects them
one per `kbd_getchar` call and runs the MPU until `_rpl_read_line` returns.
After return, the test inspects `repl_line_buf` / `repl_line_len` /
`repl_line_pos` and (for redraw checks) screen RAM at the anchor row.

Driving via the kbd_getchar entry address (rather than calling the line
editor and stepping the keyboard helper for real) lets each test run in a
few thousand instructions without involving KERNAL_GETIN's spin loop.
"""

from __future__ import annotations

import pytest

from conftest import ERROR_CODE_ZP

# PETSCII control bytes used by the REPL editor.
PET_RETURN = 0x0D
PET_DOWN = 0x11
PET_HOME = 0x13
PET_DEL = 0x14
PET_RIGHT = 0x1D
PET_UP = 0x91
PET_SHIFT_HOME = 0x93
PET_INS = 0x94
PET_LEFT = 0x9D
PET_SHIFT_SPACE = 0xA0

SCREEN_BASE = 0x0400
SCREEN_ROW_ZP = 0x33
SCREEN_COL_ZP = 0x34


def _drive_read_line(h, keys: list[int], anchor_row: int = 0,
                     max_steps: int = 2_000_000) -> None:
    """Call `_rpl_read_line`, intercepting `kbd_getchar` to feed `keys`.

    `kbd_getchar` is replaced with a Python hook: the next byte from `keys`
    is loaded into A, the JSR return address is popped off the HW stack,
    and execution resumes at the instruction after the JSR. When `keys` is
    exhausted the driver injects $0D so the routine terminates cleanly.

    The harness pre-arms the screen state to mimic `repl_loop` having just
    printed a `>` prompt: SCREEN_ROW = anchor_row, SCREEN_COL = 1, and
    `repl_line_anchor_row` = anchor_row.
    """
    sym = h.sym
    h.mpu.memory[SCREEN_ROW_ZP] = anchor_row
    h.mpu.memory[SCREEN_COL_ZP] = 1
    h.mpu.memory[sym["repl_line_anchor_row"]] = anchor_row

    # NOTE: don't wipe repl_hist_count/head/view here — tests that pre-seed
    # history via `_save_to_history` must keep that state across this call.

    sentinel = 0xFFFE
    h.mpu.memory[0x0100 + h.mpu.sp] = (sentinel >> 8) & 0xFF
    h.mpu.sp = (h.mpu.sp - 1) & 0xFF
    h.mpu.memory[0x0100 + h.mpu.sp] = sentinel & 0xFF
    h.mpu.sp = (h.mpu.sp - 1) & 0xFF
    h.mpu.pc = sym["_rpl_read_line"]

    panic_pc = sym.get("error_handler", -1)
    kbd_pc = sym["kbd_getchar"]
    feed = list(keys) + [PET_RETURN]
    idx = 0

    for _ in range(max_steps):
        pc = h.mpu.pc
        if pc == sentinel + 1:
            return
        if pc == panic_pc:
            raise AssertionError(
                f"_rpl_read_line() panicked with ERROR_CODE="
                f"${h.mpu.memory[ERROR_CODE_ZP]:02X}"
            )
        if pc == kbd_pc:
            byte = feed[idx] if idx < len(feed) else PET_RETURN
            if idx < len(feed):
                idx += 1
            h.mpu.a = byte & 0xFF
            sp = h.mpu.sp
            lo = h.mpu.memory[0x0100 + ((sp + 1) & 0xFF)]
            hi = h.mpu.memory[0x0100 + ((sp + 2) & 0xFF)]
            h.mpu.sp = (sp + 2) & 0xFF
            h.mpu.pc = (((hi << 8) | lo) + 1) & 0xFFFF
            continue
        h.mpu.step()
    raise TimeoutError(
        f"_rpl_read_line did not return within {max_steps} steps "
        f"(pc=${h.mpu.pc:04X}, fed {idx}/{len(feed)})"
    )


def _line(h) -> bytes:
    """Return the current `repl_line_buf` truncated to `repl_line_len`."""
    base = h.sym["repl_line_buf"]
    n = h.mpu.memory[h.sym["repl_line_len"]]
    return bytes(h.mpu.memory[base + i] for i in range(n))


def _len(h) -> int:
    return h.mpu.memory[h.sym["repl_line_len"]]


def _pos(h) -> int:
    return h.mpu.memory[h.sym["repl_line_pos"]]


# --- basic typing ------------------------------------------------------------

def test_empty_line_returns_immediately(h):
    """RETURN with no input → empty buffer."""
    _drive_read_line(h, [])
    assert _len(h) == 0
    assert _line(h) == b""


def test_typing_appends_to_buffer(h):
    _drive_read_line(h, [ord(c) for c in "hi"])
    assert _line(h) == b"hi"
    assert _len(h) == 2


def test_keyboard_bytes_pass_through_unchanged(h):
    """Internal storage is PETSCII uppercase ($41-$5A), which is exactly what
    the keyboard produces in the default unshifted mode. The line reader does
    no case fold — bytes pass through verbatim."""
    _drive_read_line(h, [ord(c) for c in "PrInT 1"])
    assert _line(h) == b"PrInT 1"


def test_shift_space_normalizes_to_plain_space(h):
    """VICE keymaps occasionally emit $A0 (shift-space) when modifiers drag."""
    _drive_read_line(h, [ord("a"), PET_SHIFT_SPACE, ord("b")])
    assert _line(h) == b"a b"


def test_non_printable_chars_dropped(h):
    """$00..$1F (except the editing keys we handle) and $7F..$9F (non-cursor)
    bytes must not enter the buffer."""
    _drive_read_line(h, [ord("a"), 0x05, 0x7F, 0x80, ord("b")])
    assert _line(h) == b"ab"


def test_buffer_full_drops_extra_chars(h):
    """REPL_LINE_CAP = 64; extra chars beyond that are silently dropped."""
    keys = [ord("x")] * 80
    _drive_read_line(h, keys)
    assert _len(h) == 64
    assert _line(h) == b"x" * 64


# --- backspace / delete ------------------------------------------------------

def test_backspace_at_end(h):
    _drive_read_line(h, [ord("a"), ord("b"), ord("c"), PET_DEL])
    assert _line(h) == b"ab"
    assert _pos(h) == 2


def test_backspace_at_start_is_noop(h):
    _drive_read_line(h, [PET_DEL, ord("x")])
    assert _line(h) == b"x"


def test_backspace_mid_line(h):
    """Move cursor left twice (`abcd|` → `ab|cd`), backspace deletes the `b`."""
    _drive_read_line(h, [
        ord("a"), ord("b"), ord("c"), ord("d"),
        PET_LEFT, PET_LEFT,
        PET_DEL,
    ])
    assert _line(h) == b"acd"
    assert _pos(h) == 1


# --- cursor navigation -------------------------------------------------------

def test_left_clamps_at_zero(h):
    _drive_read_line(h, [ord("x"), PET_LEFT, PET_LEFT, PET_LEFT])
    assert _pos(h) == 0


def test_right_clamps_at_len(h):
    _drive_read_line(h, [ord("x"), ord("y"), PET_RIGHT, PET_RIGHT])
    # Already at end after typing; RIGHT should be no-op.
    assert _pos(h) == 2


def test_home_jumps_to_zero(h):
    _drive_read_line(h, [ord("a"), ord("b"), ord("c"), PET_HOME])
    assert _pos(h) == 0


def test_shift_home_jumps_to_end(h):
    _drive_read_line(h, [
        ord("a"), ord("b"), ord("c"),
        PET_HOME,                       # pos = 0
        PET_SHIFT_HOME,                 # pos = len
    ])
    assert _pos(h) == 3


def test_finish_parks_cursor_at_end(h):
    """RETURN must position SCREEN_COL = 1 + len even if user finished
    mid-line, so the caller's `$0D` lands past the typed text."""
    _drive_read_line(h, [
        ord("a"), ord("b"), ord("c"),
        PET_LEFT, PET_LEFT,             # finish with pos=1
    ])
    assert h.mpu.memory[SCREEN_COL_ZP] == 4   # 1 (anchor) + 3 (len)


# --- mid-line insert ---------------------------------------------------------

def test_typing_mid_line_inserts(h):
    """`ABC` then HOME then RIGHT then `X` → `AXBC`."""
    _drive_read_line(h, [
        ord("A"), ord("B"), ord("C"),
        PET_HOME, PET_RIGHT,            # pos = 1
        ord("X"),
    ])
    assert _line(h) == b"AXBC"
    assert _pos(h) == 2


def test_insert_blank_opens_hole(h):
    """SHIFT-INST inserts a space and leaves the cursor put — so the next
    typed char overwrites the blank from the user's perspective."""
    _drive_read_line(h, [
        ord("a"), ord("b"),
        PET_HOME,                        # pos = 0
        PET_INS,                         # blank inserted at pos 0; pos still 0
    ])
    assert _line(h) == b" ab"
    assert _pos(h) == 0


def test_insert_blank_at_end(h):
    _drive_read_line(h, [
        ord("a"), ord("b"),              # pos = 2 = len
        PET_INS,
    ])
    assert _line(h) == b"ab "
    assert _pos(h) == 2


def test_insert_blank_full_buffer_noop(h):
    keys = [ord("x")] * 64 + [PET_HOME, PET_INS]
    _drive_read_line(h, keys)
    assert _len(h) == 64
    assert _line(h) == b"x" * 64


# --- redraw / screen contents -------------------------------------------------

def test_redraw_paints_buffer(h):
    """After typing, screen row 0 col 1.. should hold the screen-codes for
    the buffer. A trailing space pads col len+1."""
    _drive_read_line(h, [ord("H"), ord("I")])
    # PETSCII $48/$49 → screen-codes $08/$09 via petscii_to_screen_code's
    # general octant table.
    assert h.mpu.memory[SCREEN_BASE + 1] == 0x08    # 'H'
    assert h.mpu.memory[SCREEN_BASE + 2] == 0x09    # 'I'
    assert h.mpu.memory[SCREEN_BASE + 3] == 0x20    # trailing pad


def test_delete_erases_trailing_cell(h):
    """A delete at the end of the line must blank the cell where the
    deleted char used to be, not leave the old glyph behind."""
    _drive_read_line(h, [ord("A"), ord("B"), ord("C"), PET_DEL])
    # 'A','B' remain at cols 1,2; col 3 must be the trailing pad ($20),
    # NOT the old 'C' screen-code.
    assert h.mpu.memory[SCREEN_BASE + 1] == 0x01    # 'A'
    assert h.mpu.memory[SCREEN_BASE + 2] == 0x02    # 'B'
    assert h.mpu.memory[SCREEN_BASE + 3] == 0x20    # erased


def test_redraw_clears_to_end_of_row(h):
    """After a shorter line replaces a longer one (history recall, repeated
    backspace, etc.), the entire tail of the row must be blanked — not just
    one cell past `len`. Otherwise `UP` onto a short entry leaves the old
    line's tail visible past the new content."""
    # First drive: type a 6-char line. screen row 0 ends up holding the
    # screen-codes for 'A'..'F' at cols 1..6.
    _drive_read_line(h, [ord(c) for c in "ABCDEF"])
    assert h.mpu.memory[SCREEN_BASE + 4] == 0x04    # 'D'
    assert h.mpu.memory[SCREEN_BASE + 6] == 0x06    # 'F'

    # Seed history with a shorter entry.
    _save_to_history(h, b"XYZ")

    # Second drive on the same anchor row — UP recalls "XYZ", redraw must
    # blank cells 4..39 even though only cells 4..6 held stale glyphs.
    _drive_read_line(h, [PET_UP])
    assert h.mpu.memory[SCREEN_BASE + 1] == 0x18    # 'X'
    assert h.mpu.memory[SCREEN_BASE + 2] == 0x19    # 'Y'
    assert h.mpu.memory[SCREEN_BASE + 3] == 0x1A    # 'Z'
    # Critical: the trailing 'D','E','F' must be erased.
    assert h.mpu.memory[SCREEN_BASE + 4] == 0x20
    assert h.mpu.memory[SCREEN_BASE + 5] == 0x20
    assert h.mpu.memory[SCREEN_BASE + 6] == 0x20


# --- history -----------------------------------------------------------------

def _set_anchor(h, row: int) -> None:
    h.mpu.memory[h.sym["repl_line_anchor_row"]] = row
    h.mpu.memory[SCREEN_ROW_ZP] = row
    h.mpu.memory[SCREEN_COL_ZP] = 1


def _save_to_history(h, line: bytes) -> None:
    """Force a (line) into history by writing the buffer directly and calling
    `_rpl_hist_save`. Avoids needing to drive a full submission cycle."""
    base = h.sym["repl_line_buf"]
    h.mpu.memory[h.sym["repl_line_len"]] = len(line)
    for i, b in enumerate(line):
        h.mpu.memory[base + i] = b
    h.call("_rpl_hist_save")


def test_history_save_skips_empty_line(h):
    h.mpu.memory[h.sym["repl_line_len"]] = 0
    h.call("_rpl_hist_save")
    assert h.mpu.memory[h.sym["repl_hist_count"]] == 0


def test_history_save_increments_count(h):
    _save_to_history(h, b"a")
    _save_to_history(h, b"bc")
    assert h.mpu.memory[h.sym["repl_hist_count"]] == 2


def test_history_count_caps_at_slots(h):
    for line in [b"a", b"b", b"c", b"d", b"e", b"f"]:
        _save_to_history(h, line)
    # Ring is 2 slots (traded depth for the 64-char line); count saturates.
    assert h.mpu.memory[h.sym["repl_hist_count"]] == 2


def test_history_up_recalls_newest(h):
    _save_to_history(h, b"first")
    _save_to_history(h, b"second")
    _drive_read_line(h, [PET_UP])
    assert _line(h) == b"second"
    assert _pos(h) == 6                   # cursor at end of recalled line


def test_history_up_then_up_walks_older(h):
    _save_to_history(h, b"older")
    _save_to_history(h, b"newer")
    _drive_read_line(h, [PET_UP, PET_UP])
    assert _line(h) == b"older"


def test_history_up_clamps_at_oldest(h):
    """Extra UPs after only two stored entries should not crash or wrap."""
    _save_to_history(h, b"a")
    _save_to_history(h, b"b")
    _drive_read_line(h, [PET_UP, PET_UP, PET_UP, PET_UP])
    assert _line(h) == b"a"               # still at oldest


def test_history_down_returns_to_empty(h):
    """UP into history then DOWN past it should empty the line."""
    _save_to_history(h, b"hello")
    _drive_read_line(h, [PET_UP, PET_DOWN])
    assert _len(h) == 0


def test_history_overflow_evicts_oldest(h):
    """After 3 saves into a 2-slot ring, UP*2 reaches the 2nd entry, not the
    1st (which was rotated out)."""
    for line in [b"one", b"two", b"three"]:
        _save_to_history(h, line)
    _drive_read_line(h, [PET_UP, PET_UP, PET_UP])
    assert _line(h) == b"two"
    assert h.mpu.memory[h.sym["repl_hist_count"]] == 2


def test_history_then_edit(h):
    """Recall a line, then append to it — recalled buffer must be writable."""
    _save_to_history(h, b"abc")
    _drive_read_line(h, [PET_UP, ord("d")])
    assert _line(h) == b"abcd"


def test_history_view_resets_on_new_line(h):
    """After submitting, repl_hist_view must reset to 0 so the next UP starts
    from the newest, not from wherever the previous walk left off."""
    _save_to_history(h, b"one")
    _save_to_history(h, b"two")

    # First read: walk back to "one", finish.
    _drive_read_line(h, [PET_UP, PET_UP])
    assert _line(h) == b"one"

    # Second read: a single UP should land on "two", not deeper.
    _drive_read_line(h, [PET_UP])
    assert _line(h) == b"two"
