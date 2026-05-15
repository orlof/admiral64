"""Drive the actual EDIT() dispatcher path in py65 with the real HELP text,
dump the screen + cursor position after each UP keypress.

Reproduces the user-reported bug: after ~12 UP presses on a 40+-line text,
the cursor visually warps back near the bottom without the screen scrolling.
"""
from pathlib import Path

HELP = (Path(__file__).parent.parent / "examples" / "help.admiral").read_bytes().replace(b"\n", b"\r")

SCREEN_BASE = 0x0400
SCREEN_ROW = 0x33
SCREEN_COL = 0x34


def _addrs(h):
    return {k: h.sym[k] for k in (
        "edit_buf_start", "edit_buf_end", "edit_gap_start", "edit_gap_end",
        "edit_pos", "edit_line", "edit_view_start", "edit_view_shift",
        "edit_scr_x", "edit_scr_y", "edit_dirty",
    )}


def _setup(h, base=0xC000, capacity=800):
    """Match builtin_edit exactly: EDIT_BUF_SIZE=800, edit_init + insert."""
    a = _addrs(h)
    W0 = 0x10
    W2 = 0x14
    h.write_word(W0, base)
    h.write_word(W2, capacity)
    h.call("edit_init")
    for byte in HELP:
        h.call("edit_insert_char", a=byte)
    return a


def _screen_row(h, row):
    """Pull one screen row (40 bytes) and decode to ASCII-ish."""
    addr = SCREEN_BASE + row * 40
    raw = bytes(h.mpu.memory[addr:addr + 40])
    # Screen codes: $00 = '@', $01..$1A = 'A'..'Z', $20 = ' ', $80+x = reversed.
    out = bytearray()
    for b in raw:
        b &= 0x7F   # strip cursor highlight bit
        if 0x01 <= b <= 0x1A:
            out.append(b + 0x40)   # 'A'..'Z'
        elif b == 0x00:
            out.append(0x40)       # '@'
        elif 0x20 <= b <= 0x3F:
            out.append(b)
        else:
            out.append(0x3F)       # '?'
    return out.decode("ascii", errors="replace")


def _cursor_row(h):
    """Find which row has bit-7 set (cursor highlight)."""
    for row in range(25):
        addr = SCREEN_BASE + row * 40
        for col in range(40):
            if h.mpu.memory[addr + col] & 0x80:
                return row, col
    return None, None


def _dispatch_after_key(h, a, tag=""):
    """Mirror src/builtins.asm _bedit_after_key exactly."""
    if tag:
        pos = h.read_word(a["edit_pos"])
        ln = h.read_word(a["edit_line"])
        print(f"   [post-key {tag}]: pos=${pos:04X} line=${ln:04X}")
    pre_vh = h.mpu.memory[a["edit_view_shift"]]
    pre_vs = h.read_word(a["edit_view_start"])
    h.call("edit_view_focus", max_steps=5_000_000)
    post_vh = h.mpu.memory[a["edit_view_shift"]]
    post_vs = h.read_word(a["edit_view_start"])
    if pre_vh != post_vh or pre_vs != post_vs:
        h.mpu.memory[a["edit_dirty"]] |= 0x02
    d = h.mpu.memory[a["edit_dirty"]]
    if d & 0x02:
        h.call("edit_draw_screen", max_steps=5_000_000)
    elif d & 0x01:
        h.call("edit_draw_current_line", max_steps=5_000_000)
    h.mpu.memory[SCREEN_COL] = h.mpu.memory[a["edit_scr_x"]]
    h.mpu.memory[SCREEN_ROW] = h.mpu.memory[a["edit_scr_y"]]


def _set_cursor(h):
    """screen_show_cursor — set bit 7 at SCREEN_ROW/COL."""
    row = h.mpu.memory[SCREEN_ROW]
    col = h.mpu.memory[SCREEN_COL]
    addr = SCREEN_BASE + row * 40 + col
    h.mpu.memory[addr] |= 0x80


def _unset_cursor(h):
    """screen_hide_cursor — clear bit 7."""
    row = h.mpu.memory[SCREEN_ROW]
    col = h.mpu.memory[SCREEN_COL]
    addr = SCREEN_BASE + row * 40 + col
    h.mpu.memory[addr] &= 0x7F


def test_up_arrow_does_not_warp(h):
    """Regression: edit_prevline mis-detected gap_end when only the low byte
    matched, sending the cursor back to the last line. The bug surfaced as a
    cursor warp on the 13th UP from end-of-buffer when a regular line-start
    address (e.g. $C220) shared its low byte with gap_end (e.g. $C320).
    """
    a = _setup(h)
    h.call("screen_clear", max_steps=200_000)
    h.call("edit_view_focus", max_steps=5_000_000)
    h.call("edit_draw_screen", max_steps=5_000_000)
    h.mpu.memory[SCREEN_COL] = h.mpu.memory[a["edit_scr_x"]]
    h.mpu.memory[SCREEN_ROW] = h.mpu.memory[a["edit_scr_y"]]
    _set_cursor(h)

    trace = [(h.mpu.memory[a["edit_scr_y"]], h.read_word(a["edit_view_start"]))]
    for _ in range(30):
        _unset_cursor(h)
        h.call("edit_key_up")
        _dispatch_after_key(h, a)
        _set_cursor(h)
        trace.append((h.mpu.memory[a["edit_scr_y"]], h.read_word(a["edit_view_start"])))

    # Monotonic: cursor must never jump *down* unless view_start retreats.
    for i in range(1, len(trace)):
        prev_y, prev_vs = trace[i - 1]
        y, vs = trace[i]
        assert y <= prev_y or vs < prev_vs, (
            f"step {i}: cursor jumped DOWN to row {y} (prev {prev_y}) "
            f"without view_start retreating ({prev_vs:04X} -> {vs:04X}). "
            f"Full trace: {trace}"
        )
    # And view_start must eventually retreat after enough UPs.
    assert trace[-1][1] < trace[0][1], "view_start never retreated"
