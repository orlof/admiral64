"""Tests for screen.asm — direct VIC-II text output.

Note: py65 models RAM at $D020, $D021, $D800+ as plain RAM. We can't validate
that VIC-II actually *renders* from those addresses (that requires VICE), but
we can confirm our code writes the correct bytes to the correct addresses.
The boot smoke test + a visual pass in VICE closes the parity.
"""

from __future__ import annotations

SCREEN_BASE = 0x0400
COLOR_BASE = 0xD800
VIC_BORDER = 0xD020
VIC_BG = 0xD021
SCREEN_COLS = 40
SCREEN_ROWS = 25

COLOR_BORDER = 0x0D
COLOR_BG = 0x05
COLOR_FG = 0x0D

SCREEN_ROW_ZP = 0x33
SCREEN_COL_ZP = 0x34


def _screen_offset(row: int, col: int) -> int:
    return SCREEN_BASE + row * SCREEN_COLS + col


def _color_offset(row: int, col: int) -> int:
    return COLOR_BASE + row * SCREEN_COLS + col


# --- screen_init -------------------------------------------------------------

def test_screen_init_sets_border_and_bg(h):
    h.call("screen_init")
    assert h.mpu.memory[VIC_BORDER] == COLOR_BORDER
    assert h.mpu.memory[VIC_BG] == COLOR_BG


def test_screen_init_fills_color_ram(h):
    h.call("screen_init")
    # All 1000 cells should hold COLOR_FG.
    for i in range(SCREEN_ROWS * SCREEN_COLS):
        assert h.mpu.memory[COLOR_BASE + i] == COLOR_FG, f"cell {i}"


def test_screen_init_fills_screen_ram_with_space(h):
    h.call("screen_init")
    for i in range(SCREEN_ROWS * SCREEN_COLS):
        assert h.mpu.memory[SCREEN_BASE + i] == 0x20, f"cell {i}"


def test_screen_init_resets_cursor(h):
    # Pre-dirty the cursor ZP to confirm init actually resets it.
    h.mpu.memory[SCREEN_ROW_ZP] = 7
    h.mpu.memory[SCREEN_COL_ZP] = 13
    h.call("screen_init")
    assert h.mpu.memory[SCREEN_ROW_ZP] == 0
    assert h.mpu.memory[SCREEN_COL_ZP] == 0


# --- screen_clear ------------------------------------------------------------

def test_screen_clear_wipes_screen_and_resets_cursor(h):
    h.call("screen_init")
    # Write something visible first.
    h.mpu.memory[SCREEN_BASE] = 0x01
    h.mpu.memory[SCREEN_BASE + 500] = 0x02
    h.mpu.memory[SCREEN_ROW_ZP] = 5
    h.mpu.memory[SCREEN_COL_ZP] = 20

    h.call("screen_clear")

    assert h.mpu.memory[SCREEN_BASE] == 0x20
    assert h.mpu.memory[SCREEN_BASE + 500] == 0x20
    assert h.mpu.memory[SCREEN_ROW_ZP] == 0
    assert h.mpu.memory[SCREEN_COL_ZP] == 0


def test_screen_clear_leaves_color_ram_alone(h):
    h.call("screen_init")
    # Poke a distinguishing color so we can see if clear preserves it.
    h.mpu.memory[COLOR_BASE + 100] = 0x0A
    h.call("screen_clear")
    assert h.mpu.memory[COLOR_BASE + 100] == 0x0A


# --- screen_put_char ---------------------------------------------------------

def test_put_char_petscii_digit_is_identity(h):
    h.call("screen_init")
    # Seed an unusual color and confirm put_char leaves it alone — REPL output
    # writes screen RAM only, color is whatever the user / MC.COLOR / boot set.
    h.mpu.memory[_color_offset(0, 0)] = 0x07          # yellow
    h.call("screen_put_char", a=ord("3"))             # PETSCII $33
    assert h.mpu.memory[_screen_offset(0, 0)] == 0x33
    assert h.mpu.memory[_color_offset(0, 0)] == 0x07  # unchanged
    assert h.mpu.memory[SCREEN_COL_ZP] == 1
    assert h.mpu.memory[SCREEN_ROW_ZP] == 0


def test_put_char_uppercase_a_translates_to_screen_code_01(h):
    h.call("screen_init")
    h.call("screen_put_char", a=ord("A"))  # PETSCII $41 → screen $01
    assert h.mpu.memory[_screen_offset(0, 0)] == 0x01


def test_put_char_uppercase_z_translates_to_screen_code_1a(h):
    h.call("screen_init")
    h.call("screen_put_char", a=ord("Z"))  # PETSCII $5A → screen $1A
    assert h.mpu.memory[_screen_offset(0, 0)] == 0x1A


def test_put_char_at_sign_translates_to_screen_code_00(h):
    h.call("screen_init")
    h.call("screen_put_char", a=0x40)  # PETSCII @ → screen $00
    assert h.mpu.memory[_screen_offset(0, 0)] == 0x00


def test_put_char_advances_to_next_row_on_col_wrap(h):
    h.call("screen_init")
    for _ in range(SCREEN_COLS):
        h.call("screen_put_char", a=ord("A"))
    # We've written 40 chars; cursor should now be at (1, 0).
    assert h.mpu.memory[SCREEN_ROW_ZP] == 1
    assert h.mpu.memory[SCREEN_COL_ZP] == 0
    # Row 0 column 39 should hold the last 'A'.
    assert h.mpu.memory[_screen_offset(0, 39)] == 0x01


def test_put_char_cr_moves_to_start_of_next_row(h):
    h.call("screen_init")
    h.call("screen_put_char", a=ord("X"))  # (0, 0) now (0, 1) after advance
    h.call("screen_put_char", a=0x0D)       # CR
    assert h.mpu.memory[SCREEN_ROW_ZP] == 1
    assert h.mpu.memory[SCREEN_COL_ZP] == 0
    # CR must not have written a char anywhere unexpected.
    assert h.mpu.memory[_screen_offset(0, 1)] == 0x20  # still space


def test_put_char_cr_at_col0_still_advances_row(h):
    h.call("screen_init")
    h.call("screen_put_char", a=0x0D)
    assert h.mpu.memory[SCREEN_ROW_ZP] == 1
    assert h.mpu.memory[SCREEN_COL_ZP] == 0


def test_put_char_lf_also_newlines(h):
    """LF ($0A) triggers a newline just like CR — embedded \\n in printed
    strings renders as a real line break, not a stray glyph."""
    h.call("screen_init")
    h.call("screen_put_char", a=ord("X"))     # (0, 0); cursor advances to (0, 1)
    h.call("screen_put_char", a=0x0A)         # LF
    assert h.mpu.memory[SCREEN_ROW_ZP] == 1
    assert h.mpu.memory[SCREEN_COL_ZP] == 0
    assert h.mpu.memory[_screen_offset(0, 1)] == 0x20  # LF didn't print a glyph


# --- scrolling ---------------------------------------------------------------

def _fill_row(h, row: int, petscii_char: int):
    """Directly poke screen RAM so we can verify scroll moves bytes."""
    # Use the screen-code equivalent. For uppercase A-Z we subtract $40.
    if 0x40 <= petscii_char <= 0x5F:
        code = petscii_char - 0x40
    else:
        code = petscii_char
    for col in range(SCREEN_COLS):
        h.mpu.memory[_screen_offset(row, col)] = code


def test_scroll_triggers_when_row_exceeds_bottom(h):
    h.call("screen_init")
    # Fill each row with a distinct marker so we can see the shift.
    for r in range(SCREEN_ROWS):
        _fill_row(h, r, 0x41 + r)  # row 0 = 'A', row 1 = 'B', ...

    # Place cursor at end of last row, then write one more char to trigger
    # col-wrap → row increment → scroll.
    h.mpu.memory[SCREEN_ROW_ZP] = SCREEN_ROWS - 1
    h.mpu.memory[SCREEN_COL_ZP] = SCREEN_COLS - 1
    h.call("screen_put_char", a=ord("!"))

    # After scroll, row 0 should hold what was row 1 ('B' = screen code $02),
    # row 23 should hold what was row 24 ('Y' = $19), and the new last row is blank.
    assert h.mpu.memory[_screen_offset(0, 0)] == 0x02, "row 0 should be old row 1 (B)"
    assert h.mpu.memory[_screen_offset(23, 0)] == 0x19, "row 23 should be old row 24 (Y)"
    # Row 24 is blank (all spaces) — but the final '!' was written at
    # (24, 39) BEFORE the scroll, so the scroll wiped it. After scroll the
    # whole row 24 should be space.
    for col in range(SCREEN_COLS):
        assert h.mpu.memory[_screen_offset(24, col)] == 0x20, f"row 24 col {col}"

    # Cursor should be at (24, 0) — the scroll keeps us at the bottom row.
    assert h.mpu.memory[SCREEN_ROW_ZP] == 24
    assert h.mpu.memory[SCREEN_COL_ZP] == 0


# --- show/hide cursor: bit-7 toggle preserves underlying glyph -----------------

def test_show_cursor_sets_reverse_bit_on_empty_cell(h):
    """Over a freshly cleared cell ($20 space), show flips bit 7 → $A0
    (reverse-video space, the classic solid-block cursor)."""
    h.call("screen_init")
    h.mpu.memory[SCREEN_ROW_ZP] = 3
    h.mpu.memory[SCREEN_COL_ZP] = 7
    h.call("screen_show_cursor")
    assert h.mpu.memory[_screen_offset(3, 7)] == 0xA0


def test_show_cursor_reverses_existing_glyph(h):
    """Over a typed character, show inverts the glyph rather than replacing
    it — the underlying letter must remain visible (in reverse video) so the
    user can still read what's under the cursor while editing mid-line."""
    h.call("screen_init")
    h.mpu.memory[_screen_offset(3, 7)] = 0x02   # screen-code 'B'
    h.mpu.memory[SCREEN_ROW_ZP] = 3
    h.mpu.memory[SCREEN_COL_ZP] = 7
    h.call("screen_show_cursor")
    assert h.mpu.memory[_screen_offset(3, 7)] == 0x82   # 'B' with bit 7


def test_hide_cursor_restores_underlying_glyph(h):
    """show + hide must round-trip back to the original cell — important when
    the cursor moves over a typed char then off it on the next keystroke."""
    h.call("screen_init")
    h.mpu.memory[_screen_offset(3, 7)] = 0x02
    h.mpu.memory[SCREEN_ROW_ZP] = 3
    h.mpu.memory[SCREEN_COL_ZP] = 7
    h.call("screen_show_cursor")
    h.call("screen_hide_cursor")
    assert h.mpu.memory[_screen_offset(3, 7)] == 0x02


def test_hide_cursor_on_unreversed_cell_is_idempotent(h):
    """Defensive: hide on a cell that wasn't reversed must leave it alone."""
    h.call("screen_init")
    h.mpu.memory[_screen_offset(3, 7)] = 0x05
    h.mpu.memory[SCREEN_ROW_ZP] = 3
    h.mpu.memory[SCREEN_COL_ZP] = 7
    h.call("screen_hide_cursor")
    assert h.mpu.memory[_screen_offset(3, 7)] == 0x05


def test_scroll_preserves_middle_rows(h):
    h.call("screen_init")
    # Put distinct markers in rows 5 and 15.
    _fill_row(h, 5, 0x41)   # 'A' = code $01
    _fill_row(h, 15, 0x5A)  # 'Z' = code $1A

    # Trigger scroll by advancing off the bottom.
    h.mpu.memory[SCREEN_ROW_ZP] = SCREEN_ROWS - 1
    h.mpu.memory[SCREEN_COL_ZP] = SCREEN_COLS - 1
    h.call("screen_put_char", a=ord("X"))

    # Those rows should now be at row 4 and row 14 respectively.
    assert h.mpu.memory[_screen_offset(4, 0)] == 0x01
    assert h.mpu.memory[_screen_offset(4, 20)] == 0x01
    assert h.mpu.memory[_screen_offset(14, 0)] == 0x1A
    assert h.mpu.memory[_screen_offset(14, 20)] == 0x1A
