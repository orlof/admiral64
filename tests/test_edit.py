"""Tests for edit.asm — Phase A: gap-buffer primitives.

Drives the routines directly (no parser_eval). Tests use a small fake buffer
so the gap-buffer mechanics are easy to inspect.
"""
from __future__ import annotations

import pytest
from conftest import inject_edit_image


@pytest.fixture
def h(h, edit_plugin_image):
    """The edit core now lives in plugins/edit.asm — inject the assembled
    image (at EDIT_IMAGE_BASE) and its symbols into a fresh harness."""
    return inject_edit_image(h, edit_plugin_image)


W0 = 0x10
W2 = 0x14

# Editor state (resolved from VICE symbols at h.sym).
def _addrs(h) -> dict[str, int]:
    return {k: h.sym[k] for k in (
        "edit_buf_start", "edit_buf_end", "edit_gap_start", "edit_gap_end",
        "edit_pos", "edit_line", "edit_view_start", "edit_view_shift",
        "edit_scr_x", "edit_scr_y", "edit_dirty", "edit_clip_cut",
    )}


def _setup_buffer(h, contents: bytes, cursor: int, capacity: int = 32) -> int:
    """Place a fresh buffer at $C800, populate with `contents`, gap fills the
    rest, cursor at logical position `cursor`. Returns buffer base address.
    """
    base = 0xC800
    # Write content bytes into the pre-gap region [base..base+cursor).
    for i in range(cursor):
        h.mpu.memory[base + i] = contents[i]
    # Write rest of content into the post-gap region [base+capacity-(len-cursor)..base+capacity).
    tail_len = len(contents) - cursor
    tail_start = base + capacity - tail_len
    for i in range(tail_len):
        h.mpu.memory[tail_start + i] = contents[cursor + i]

    a = _addrs(h)
    h.write_word(a["edit_buf_start"], base)
    h.write_word(a["edit_buf_end"], base + capacity)
    h.write_word(a["edit_gap_start"], base + cursor)
    h.write_word(a["edit_gap_end"], tail_start)
    h.write_word(a["edit_pos"], tail_start)         # cursor at gap_end
    h.write_word(a["edit_line"], base)
    h.write_word(a["edit_view_start"], base)
    h.mpu.memory[a["edit_view_shift"]] = 0
    h.mpu.memory[a["edit_scr_x"]] = 0
    h.mpu.memory[a["edit_scr_y"]] = 0
    h.mpu.memory[a["edit_dirty"]] = 0
    h.mpu.memory[a["edit_clip_cut"]] = 0
    return base


def _logical(h) -> bytes:
    """Read [buf_start..gap_start) ++ [gap_end..buf_end) — the logical text."""
    a = _addrs(h)
    buf_start = h.read_word(a["edit_buf_start"])
    buf_end = h.read_word(a["edit_buf_end"])
    gap_start = h.read_word(a["edit_gap_start"])
    gap_end = h.read_word(a["edit_gap_end"])
    pre = bytes(h.mpu.memory[buf_start:gap_start])
    post = bytes(h.mpu.memory[gap_end:buf_end])
    return pre + post


# --- edit_init -------------------------------------------------------------

def test_edit_init_empty_state(h):
    """After init, gap covers the whole buffer; cursor at end (= buf_end)."""
    h.write_word(W0, 0xC800)
    h.write_word(W2, 100)
    h.call("edit_init")
    a = _addrs(h)
    assert h.read_word(a["edit_buf_start"]) == 0xC800
    assert h.read_word(a["edit_buf_end"]) == 0xC800 + 100
    assert h.read_word(a["edit_gap_start"]) == 0xC800
    assert h.read_word(a["edit_gap_end"]) == 0xC800 + 100
    assert h.read_word(a["edit_pos"]) == 0xC800 + 100
    assert h.read_word(a["edit_line"]) == 0xC800
    assert h.mpu.memory[a["edit_dirty"]] == 0


# --- edit_insert_char (cursor at end → easy case, no gap_move needed) ------

def test_insert_char_appends(h):
    _setup_buffer(h, b"AB", cursor=2)  # cursor after 'AB'
    h.call("edit_insert_char", a=ord("C"))
    assert _logical(h) == b"ABC"


def test_insert_char_marks_line_dirty(h):
    _setup_buffer(h, b"", cursor=0)
    h.call("edit_insert_char", a=ord("X"))
    a = _addrs(h)
    assert h.mpu.memory[a["edit_dirty"]] & 0x01  # current line dirty


def test_insert_newline_marks_screen_dirty(h):
    _setup_buffer(h, b"", cursor=0)
    h.call("edit_insert_char", a=0x0D)
    a = _addrs(h)
    assert h.mpu.memory[a["edit_dirty"]] & 0x02  # full screen dirty


def test_insert_full_buffer_no_op(h):
    """Insert into a buffer with no gap is a silent no-op."""
    base = 0xC800
    a = _addrs(h)
    # Buffer fully populated: gap_start == gap_end == buf_end.
    h.write_word(a["edit_buf_start"], base)
    h.write_word(a["edit_buf_end"], base + 4)
    h.write_word(a["edit_gap_start"], base + 4)
    h.write_word(a["edit_gap_end"], base + 4)
    h.write_word(a["edit_pos"], base + 4)
    for i, ch in enumerate(b"ABCD"):
        h.mpu.memory[base + i] = ch
    h.call("edit_insert_char", a=ord("E"))
    assert _logical(h) == b"ABCD"


# --- edit_gap_move ---------------------------------------------------------

def test_gap_move_to_middle_for_insert(h):
    """User typed 'AB', moved cursor to position 1, types 'X' → 'AXB'."""
    _setup_buffer(h, b"AB", cursor=2, capacity=8)
    a = _addrs(h)
    # Move cursor (pos) to logical position 1: between 'A' and 'B'.
    # In our layout, 'A' is at base+0, 'B' is at base+capacity-1 (= 0xC807).
    # Logical pos 1 = pointer to where 'B' is now (gap_end was pointing
    # there). Cursor at gap_end - 1 = 0xC806 wouldn't work because that's
    # inside the gap. The user-facing cursor logic moves pos to gap_start
    # when going left across the gap. Here we simulate "cursor between
    # A and B" by setting pos = base + 1 (within pre-gap, but gap is at [2,7)).
    h.write_word(a["edit_pos"], 0xC800 + 1)
    # Now insert 'X' — should trigger gap_move + insert.
    h.call("edit_insert_char", a=ord("X"))
    assert _logical(h) == b"AXB"


def test_gap_move_left(h):
    """Gap right of cursor → gap_move shifts gap leftward."""
    _setup_buffer(h, b"HELLO", cursor=5, capacity=10)
    a = _addrs(h)
    # Move cursor to position 2 (between 'E' and 'L').
    h.write_word(a["edit_pos"], 0xC800 + 2)
    h.call("edit_gap_move")
    # After move, gap_start should be at 2 (pre-gap = "HE").
    assert h.read_word(a["edit_gap_start"]) == 0xC800 + 2
    # gap_end == pos.
    assert h.read_word(a["edit_gap_end"]) == h.read_word(a["edit_pos"])
    # Logical content unchanged.
    assert _logical(h) == b"HELLO"


def test_gap_move_right(h):
    """Cursor right of gap → gap_move shifts gap rightward."""
    _setup_buffer(h, b"HELLO", cursor=2, capacity=10)
    a = _addrs(h)
    # Cursor was at gap_end (post-gap region start). Move it right to
    # logical position 4 (between 'L' and 'O') — physical: gap_end + 2.
    gap_end = h.read_word(a["edit_gap_end"])
    h.write_word(a["edit_pos"], gap_end + 2)
    h.call("edit_gap_move")
    # gap_start should now be 4 (pre-gap = "HELL").
    assert h.read_word(a["edit_gap_start"]) == 0xC800 + 4
    assert _logical(h) == b"HELLO"


# --- edit_remove_char (forward DEL) ----------------------------------------

def test_remove_char_at_cursor(h):
    """Cursor between 'A' and 'B'; DEL removes 'B'."""
    _setup_buffer(h, b"AB", cursor=1, capacity=8)
    h.call("edit_remove_char")
    assert _logical(h) == b"A"


def test_remove_char_at_end_no_op(h):
    """Cursor at end of buffer: DEL is a no-op."""
    _setup_buffer(h, b"AB", cursor=2, capacity=8)
    a = _addrs(h)
    # Force pos = buf_end (cursor at very end, nothing to delete to the right).
    h.write_word(a["edit_pos"], h.read_word(a["edit_buf_end"]))
    h.call("edit_remove_char")
    assert _logical(h) == b"AB"


def test_remove_newline_marks_screen_dirty(h):
    """Removing a newline forces a full-screen redraw."""
    _setup_buffer(h, b"A\rB", cursor=1, capacity=8)
    a = _addrs(h)
    h.mpu.memory[a["edit_dirty"]] = 0
    h.call("edit_remove_char")
    assert h.mpu.memory[a["edit_dirty"]] & 0x02


# --- edit_bol --------------------------------------------------------------

def test_bol_on_first_line(h):
    """BOL of first line is buf_start."""
    _setup_buffer(h, b"hello", cursor=3, capacity=10)
    a = _addrs(h)
    h.write_word(W0, h.read_word(a["edit_pos"]))
    h.call("edit_bol")
    assert h.read_word(W0) == h.read_word(a["edit_buf_start"])


def test_bol_after_newline(h):
    """BOL of line after a newline returns the char after the newline."""
    _setup_buffer(h, b"AB\rCD", cursor=5, capacity=10)
    a = _addrs(h)
    # cursor=5 puts entire "AB\rCD" in pre-gap, so 'C' is at base+3.
    h.write_word(W0, h.read_word(a["edit_pos"]))
    h.call("edit_bol")
    expected = h.read_word(a["edit_buf_start"]) + 3
    assert h.read_word(W0) == expected


# --- edit_eol --------------------------------------------------------------

def test_eol_to_newline(h):
    """EOL walks forward to the next '\\r'."""
    _setup_buffer(h, b"AB\rCD", cursor=0, capacity=10)
    a = _addrs(h)
    # Cursor at start. EOL should return pointer to the '\r'.
    h.write_word(W0, h.read_word(a["edit_buf_start"]))
    h.call("edit_eol")
    # '\r' is in post-gap region, at physical addr buf_start + capacity - 3.
    expected = h.read_word(a["edit_buf_end"]) - 3
    assert h.read_word(W0) == expected


def test_eol_at_end_returns_buf_end(h):
    """EOL on last (unterminated) line returns buf_end."""
    _setup_buffer(h, b"hello", cursor=0, capacity=10)
    a = _addrs(h)
    h.write_word(W0, h.read_word(a["edit_buf_start"]))
    h.call("edit_eol")
    assert h.read_word(W0) == h.read_word(a["edit_buf_end"])


# --- edit_prevline / edit_nextline -----------------------------------------

def test_nextline_advances_one_line(h):
    """nextline from line 0 goes to the start of line 1."""
    _setup_buffer(h, b"AB\rCD", cursor=0, capacity=10)
    a = _addrs(h)
    h.write_word(W0, h.read_word(a["edit_buf_start"]))
    h.call("edit_nextline")
    # Line 1 starts at the 'C': addr buf_end - 2.
    expected = h.read_word(a["edit_buf_end"]) - 2
    assert h.read_word(W0) == expected


def test_nextline_at_last_line_returns_buf_end(h):
    """No next line → buf_end."""
    _setup_buffer(h, b"hello", cursor=0, capacity=10)
    a = _addrs(h)
    h.write_word(W0, h.read_word(a["edit_buf_start"]))
    h.call("edit_nextline")
    assert h.read_word(W0) == h.read_word(a["edit_buf_end"])


def test_prevline_at_first_line_returns_buf_start(h):
    """No prev line → buf_start."""
    _setup_buffer(h, b"hello", cursor=3, capacity=10)
    a = _addrs(h)
    h.write_word(W0, h.read_word(a["edit_pos"]))
    h.call("edit_prevline")
    assert h.read_word(W0) == h.read_word(a["edit_buf_start"])


# --- Phase B: rendering ----------------------------------------------------

SCREEN_BASE = 0x0400
SCREEN_COLS = 40
SCREEN_ROWS = 25


def _read_screen_row(h, row: int) -> bytes:
    base = SCREEN_BASE + row * SCREEN_COLS
    return bytes(h.mpu.memory[base + i] for i in range(SCREEN_COLS))


def test_draw_line_short_pads_blanks(h):
    """A 3-char line on row 0 → first 3 cells are screen codes, rest are $20."""
    _setup_buffer(h, b"ABC", cursor=3, capacity=20)
    # Pre-paint row 0 with junk so we see real writes.
    for i in range(SCREEN_COLS):
        h.mpu.memory[SCREEN_BASE + i] = 0xEE
    h.write_word(W0, h.read_word(_addrs(h)["edit_buf_start"]))
    h.call("edit_draw_line", a=0)
    row = _read_screen_row(h, 0)
    # PETSCII 'A'=$41 → screen code $01 via the general octant-table formula
    # ($41 + $C0 = $01 mod 256).
    assert row[0:3] == bytes([0x01, 0x02, 0x03])  # A/B/C
    assert all(b == 0x20 for b in row[3:])


def test_draw_line_truncates_long_line(h):
    """A line longer than 40 chars → only first 40 visible."""
    payload = bytes(b"X") * 50
    _setup_buffer(h, payload, cursor=50, capacity=60)
    h.write_word(W0, h.read_word(_addrs(h)["edit_buf_start"]))
    h.call("edit_draw_line", a=0)
    row = _read_screen_row(h, 0)
    # 'X' = $58, lookup[2]=$C0, $C0+$58 = $18.
    assert all(b == 0x18 for b in row)


def test_draw_line_view_shift_skips_chars(h):
    """view_shift=2 → first two chars skipped, line starts at 'C'."""
    _setup_buffer(h, b"ABCDE", cursor=5, capacity=20)
    a = _addrs(h)
    h.mpu.memory[a["edit_view_shift"]] = 2
    h.write_word(W0, h.read_word(a["edit_buf_start"]))
    h.call("edit_draw_line", a=0)
    row = _read_screen_row(h, 0)
    # 'C' = $43, $C0 + $43 = $03.
    assert row[0] == 0x03
    assert row[1] == 0x04  # 'D'
    assert row[2] == 0x05  # 'E'
    assert row[3] == 0x20


def test_draw_line_advances_past_newline(h):
    """W0 is left pointing past the trailing '\\r'."""
    _setup_buffer(h, b"AB\rCD", cursor=5, capacity=10)
    a = _addrs(h)
    # Cursor=5 puts everything in pre-gap. Buffer: A B \r C D _ _ _ _ _.
    buf_start = h.read_word(a["edit_buf_start"])
    h.write_word(W0, buf_start)
    h.call("edit_draw_line", a=0)
    # After drawing line 0 ("AB"), W0 should be just past the '\r' — at buf_start+3.
    assert h.read_word(W0) == buf_start + 3


def test_draw_screen_renders_two_lines(h):
    """Two lines separated by '\\r' render to rows 0 and 1."""
    _setup_buffer(h, b"AB\rCD", cursor=5, capacity=10)
    # Pre-paint screen with junk.
    for i in range(SCREEN_BASE, SCREEN_BASE + SCREEN_COLS * 25):
        h.mpu.memory[i] = 0xEE
    h.call("edit_draw_screen")
    # Row 0: 'A' 'B' followed by blanks.
    row0 = _read_screen_row(h, 0)
    assert row0[0] == 0x01  # 'A'
    assert row0[1] == 0x02  # 'B'
    assert row0[2] == 0x20  # blank
    # Row 1: 'C' 'D' followed by blanks.
    row1 = _read_screen_row(h, 1)
    assert row1[0] == 0x03  # 'C'
    assert row1[1] == 0x04  # 'D'
    assert row1[2] == 0x20
    # Row 2: all blanks (no more content).
    row2 = _read_screen_row(h, 2)
    assert all(b == 0x20 for b in row2)


def test_draw_screen_clears_dirty(h):
    """After full redraw, dirty flag is cleared."""
    _setup_buffer(h, b"hello", cursor=5, capacity=20)
    a = _addrs(h)
    h.mpu.memory[a["edit_dirty"]] = 0x03
    h.call("edit_draw_screen")
    assert h.mpu.memory[a["edit_dirty"]] == 0


def test_draw_line_handles_gap_in_middle(h):
    """Content split across the gap renders as one continuous line."""
    _setup_buffer(h, b"HELLO", cursor=2, capacity=10)
    # Pre-gap = "HE", post-gap = "LLO". Should still render as "HELLO".
    h.write_word(W0, h.read_word(_addrs(h)["edit_buf_start"]))
    h.call("edit_draw_line", a=0)
    row = _read_screen_row(h, 0)
    # Screen codes: H=$08, E=$05, L=$0C, L=$0C, O=$0F.
    assert row[:5] == bytes([0x08, 0x05, 0x0C, 0x0C, 0x0F])
    assert all(b == 0x20 for b in row[5:])


# --- Phase C: cursor keys + view focus -------------------------------------

def test_key_left_decrements_pos(h):
    _setup_buffer(h, b"hello", cursor=3, capacity=10)
    a = _addrs(h)
    # cursor=3: pre-gap="hel", gap=[base+3..base+capacity-2), post="lo".
    # pos starts at gap_end. After left: pos = gap_start (= base+3).
    h.call("edit_key_left")
    assert h.read_word(a["edit_pos"]) == h.read_word(a["edit_gap_start"]) - 1


def test_key_left_at_buf_start_no_op(h):
    _setup_buffer(h, b"hello", cursor=0, capacity=10)
    a = _addrs(h)
    h.write_word(a["edit_pos"], h.read_word(a["edit_buf_start"]))
    h.call("edit_key_left")
    assert h.read_word(a["edit_pos"]) == h.read_word(a["edit_buf_start"])


def test_key_right_increments_pos(h):
    _setup_buffer(h, b"hello", cursor=2, capacity=10)
    a = _addrs(h)
    pos_before = h.read_word(a["edit_pos"])
    h.call("edit_key_right")
    # pos started at gap_end, advances to gap_end+1.
    assert h.read_word(a["edit_pos"]) == pos_before + 1


def test_key_right_at_buf_end_no_op(h):
    _setup_buffer(h, b"hello", cursor=5, capacity=10)
    a = _addrs(h)
    h.write_word(a["edit_pos"], h.read_word(a["edit_buf_end"]))
    h.call("edit_key_right")
    assert h.read_word(a["edit_pos"]) == h.read_word(a["edit_buf_end"])


def test_view_focus_computes_scr_x_simple(h):
    """View focus on a buffer that fits → scr_x = col, scr_y = 0."""
    _setup_buffer(h, b"hello", cursor=3, capacity=10)
    a = _addrs(h)
    h.call("edit_view_focus")
    assert h.mpu.memory[a["edit_scr_x"]] == 3  # col 3
    assert h.mpu.memory[a["edit_scr_y"]] == 0  # first line
    assert h.mpu.memory[a["edit_view_shift"]] == 0


def test_view_focus_scrolls_horizontally(h):
    """Cursor past column 40 → view_shift adjusts so cursor is on screen."""
    payload = bytes(b"X" * 50)
    _setup_buffer(h, payload, cursor=45, capacity=60)
    h.call("edit_view_focus")
    a = _addrs(h)
    # col=45, view_shift = 45 - 39 = 6.
    assert h.mpu.memory[a["edit_view_shift"]] == 6
    assert h.mpu.memory[a["edit_scr_x"]] == 39


def test_view_focus_two_line_buffer(h):
    """Multi-line buffer: scr_y reflects the cursor's line number."""
    _setup_buffer(h, b"AB\rCD", cursor=4, capacity=10)
    # cursor=4 puts pos at logical position 4 (between 'C' and 'D').
    a = _addrs(h)
    h.call("edit_view_focus")
    assert h.mpu.memory[a["edit_scr_y"]] == 1  # second line
    assert h.mpu.memory[a["edit_scr_x"]] == 1  # 1 char in (after 'C')


def test_key_down_advances_to_next_line(h):
    """K_DOWN sets line to next line and pos to same column on it."""
    _setup_buffer(h, b"AB\rCD", cursor=1, capacity=10)
    # cursor=1: pos is between 'A' and 'B', col=1.
    a = _addrs(h)
    h.call("edit_view_focus")  # establish scr_x=1, scr_y=0, line=buf_start
    h.call("edit_key_down")
    h.call("edit_view_focus")  # recompute
    assert h.mpu.memory[a["edit_scr_y"]] == 1
    assert h.mpu.memory[a["edit_scr_x"]] == 1


def test_key_up_at_first_line_clamps(h):
    """K_UP on first line → stays on first line."""
    _setup_buffer(h, b"AB\rCD", cursor=1, capacity=10)
    a = _addrs(h)
    h.call("edit_view_focus")
    h.call("edit_key_up")
    h.call("edit_view_focus")
    assert h.mpu.memory[a["edit_scr_y"]] == 0


def test_key_down_at_last_line_no_op(h):
    """K_DOWN on last line → no-op."""
    _setup_buffer(h, b"AB\rCD", cursor=4, capacity=10)
    a = _addrs(h)
    h.call("edit_view_focus")
    pos_before = h.read_word(a["edit_pos"])
    h.call("edit_key_down")
    assert h.read_word(a["edit_pos"]) == pos_before


# --- edit_key_newline (auto-indent) ----------------------------------------

def test_newline_no_indent_on_unindented_line(h):
    """RETURN at end of an unindented line just inserts '\\r'."""
    _setup_buffer(h, b"abc", cursor=3, capacity=20)
    h.call("edit_view_focus")
    h.call("edit_key_newline")
    assert _logical(h) == b"abc\r"


def test_newline_copies_leading_spaces(h):
    """RETURN at end of '    abc' inserts '\\r' + '    ' (auto-indent)."""
    _setup_buffer(h, b"    abc", cursor=7, capacity=32)
    h.call("edit_view_focus")
    h.call("edit_key_newline")
    assert _logical(h) == b"    abc\r    "


def test_newline_stops_at_first_non_space(h):
    """Auto-indent only copies the contiguous leading-space prefix."""
    _setup_buffer(h, b"  x  y", cursor=6, capacity=32)
    h.call("edit_view_focus")
    h.call("edit_key_newline")
    assert _logical(h) == b"  x  y\r  "


def test_newline_at_column_0_skips_indent(h):
    """RETURN at column 0 of an indented line doesn't duplicate the indent."""
    _setup_buffer(h, b"    abc", cursor=0, capacity=32)
    # cursor=0: edit_line == gap_end (post-gap). Auto-indent should be skipped.
    h.call("edit_view_focus")
    h.call("edit_key_newline")
    # Logical: "\r    abc". The new empty line above gets no indent.
    assert _logical(h) == b"\r    abc"


def test_newline_in_middle_of_indented_line(h):
    """RETURN in the middle of '    abc' splits it and indents the new line."""
    _setup_buffer(h, b"    abc", cursor=4, capacity=32)
    # cursor=4: between the trailing space and 'a'.
    h.call("edit_view_focus")
    h.call("edit_key_newline")
    # The new line's indent is copied from the line above's leading spaces.
    assert _logical(h) == b"    \r    abc"
