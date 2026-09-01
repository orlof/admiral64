// -----------------------------------------------------------------------------
// Window-target text output. Bypasses KERNAL CHROUT entirely — we own the
// PETSCII → screen-code translation, cursor state, and scrolling.
//
// The output target is the "current window", described by the wm_* statics
// below. At boot the target is a pseudo-window covering the whole VIC text
// screen (wm_buf = $0400, 40x25, origin 0,0, WM off): every routine below
// then behaves exactly like the pre-WM direct-screen code. When the window
// manager is live (WM_FLAGS bit 0), the target is a window's off-screen
// cell buffer, and writes are mirrored to the screen for cells the window
// owns per the MAP (write-through; see wm.asm and PLANS/ui-primitives.md).
//
// Cursor state stays in SCREEN_ROW / SCREEN_COL (window-relative; at boot
// window == screen so they are absolute, as before).
//
// Memory layout (assumes VIC-II bank 0 — default at reset):
//   SCREEN_BASE ($0400): 25×40 screen codes
//   COLOR_BASE  ($D800): 25×40 4-bit foreground colors (through I/O)
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"

// --- current output target (statics; switched by wm_use / boot init) ---------
wm_buf:    .word SCREEN_BASE   // cell buffer base (boot: the screen itself)
wm_w:      .byte SCREEN_COLS   // target width  (stride)
wm_h:      .byte SCREEN_ROWS   // target height
wm_x0:     .byte 0             // window origin on screen (cols)
wm_y0:     .byte 0             // window origin on screen (rows)
wm_idx:    .byte 0             // z-index in WINDOWS (write-through compare)

// -----------------------------------------------------------------------------
// screen_init — clear screen to space + COLOR_FG, set border/bg, reset cursor,
// and reset the output target to the boot pseudo-window (whole screen).
// Leaf helper: no preamble, no alloc.
//   clobbers: A, X, Y.
// -----------------------------------------------------------------------------
screen_init:
    // VIC registers and color RAM live in I/O space at $D000-$DFFF, which is
    // RAM under MEM_NORMAL ($34). Bank I/O in for the writes; bank out before
    // the screen_clear fall-through (SCREEN_BASE at $0400 is plain RAM and
    // doesn't need I/O on).
    inc $01                          // $34 → $35 (I/O in)
    lda #COLOR_BORDER
    sta VIC_BORDER
    lda #COLOR_BG
    sta VIC_BG
    // Select unshifted charset (uppercase + graphics) — same as C64 BASIC v2
    // boots into.
    lda #$15
    sta VIC_MEMPTR

    // Fill color RAM ($D800-$DBE7, 1000 bytes) with COLOR_FG.
    ldx #0
    lda #COLOR_FG
!loop:
    sta COLOR_BASE,x
    sta COLOR_BASE + $100,x
    sta COLOR_BASE + $200,x
    sta COLOR_BASE + $300,x
    inx
    bne !loop-

    dec $01                          // $35 → $34 (I/O out)

    // Boot output target = the whole screen, WM off.
    lda #<SCREEN_BASE
    sta wm_buf
    lda #>SCREEN_BASE
    sta wm_buf+1
    lda #SCREEN_COLS
    sta wm_w
    lda #SCREEN_ROWS
    sta wm_h
    lda #0
    sta wm_x0
    sta wm_y0
    sta wm_idx
    sta WM_FLAGS
    // Fall into screen_clear (fills the target with $20 + resets cursor).

// -----------------------------------------------------------------------------
// screen_clear — fill the current target with screen-code space ($20),
// cursor → 0,0. Leaves color RAM and VIC registers alone. At boot (target =
// screen) this is the old fullscreen clear; on a window it clears the
// window's buffer (write-through per row).
//   clobbers: A, X, Y, W2 (+ WM ptrs).
// -----------------------------------------------------------------------------
screen_clear:
    lda WM_FLAGS
    cmp #%00000001
    beq _scl_windowed
    // WM off or locked: the old fast fullscreen clear.
    ldx #0
    lda #$20
!loop:
    sta SCREEN_BASE,x
    sta SCREEN_BASE + $100,x
    sta SCREEN_BASE + $200,x
    sta SCREEN_BASE + $300,x
    inx
    bne !loop-
    lda #0
    sta SCREEN_ROW
    sta SCREEN_COL
    rts
_scl_windowed:
    lda #0
    sta SCREEN_ROW
    sta SCREEN_COL
_scl_row_loop:
    lda SCREEN_ROW
    cmp wm_h
    bcs _scl_done
    jsr scr_row_offset_to_w2         // W2 = row base (+ WM ptrs)
    lda #$20
    ldy wm_w
_scl_cell_loop:
    dey
    bmi _scl_row_done
    jsr _scr_write_cell              // (W2),y = A with write-through
    lda #$20
    jmp _scl_cell_loop
_scl_row_done:
    inc SCREEN_ROW
    jmp _scl_row_loop
_scl_done:
    lda #0
    sta SCREEN_ROW
    rts

// -----------------------------------------------------------------------------
// screen_show_cursor / screen_hide_cursor — set/clear the reverse-video bit
// of the cell at (SCREEN_ROW, SCREEN_COL) in the current target.
//   clobbers: A, Y. W2 written (+ WM ptrs).
// -----------------------------------------------------------------------------
screen_show_cursor:
    jsr scr_row_offset_to_w2
    ldy SCREEN_COL
    lda (W2),y
    ora #$80
    jmp _scr_write_cell

screen_hide_cursor:
    jsr scr_row_offset_to_w2
    ldy SCREEN_COL
    lda (W2),y
    and #$7F
    jmp _scr_write_cell

// -----------------------------------------------------------------------------
// screen_put_char — write one PETSCII char to the current target at the
// cursor, advance cursor, scroll the target if we fall off its bottom.
// NOTE: not screen-lock aware — the lock's only holder (EDIT) renders rows
// itself via scr_row_offset_to_w2_a and never calls put_char.
//   in:  A = PETSCII byte
//   clobbers: A, X, Y. (W2 + WM ptrs clobbered; W3/GC_DEST too on scroll.)
//
// Writes cells only — does NOT touch color RAM.
// -----------------------------------------------------------------------------
screen_put_char:
    // Control chars: both $0D (CR) and $0A (LF) trigger a newline so embedded
    // \n in strings renders as a line break, not as a glyph.
    cmp #$0D
    beq _scr_jmp_nl
    cmp #$0A
    bne scr_not_nl
_scr_jmp_nl:
    jmp scr_newline
scr_not_nl:

    jsr petscii_to_screen_code
    pha                              // stash the screen code

    jsr scr_row_offset_to_w2         // W2 = target row base (+ WM ptrs)
    ldy SCREEN_COL
    pla
    jsr _scr_write_cell              // write with write-through

    // Advance cursor.
    inc SCREEN_COL
    lda SCREEN_COL
    cmp wm_w
    bcc scr_done                     // still on current row
    // Wrapped off right edge: fall into newline.
scr_newline:
    lda #0
    sta SCREEN_COL
    inc SCREEN_ROW
    lda SCREEN_ROW
    cmp wm_h
    bcc scr_done
    // Cursor fell off the bottom: scroll the target up, stay on last row.
    jsr screen_scroll_up
    ldx wm_h
    dex
    stx SCREEN_ROW
scr_done:
    rts

// -----------------------------------------------------------------------------
// _scr_write_cell — store A into the current target at (W2),y and, when the
// WM is live and the target window owns the screen cell (MAP row base in
// WM_MAP_PTR matches wm_idx and the screen lock is off), mirror it to the
// screen row base in WM_SCR_PTR.
//   in:  A = screen code, Y = column, W2/WM_SCR_PTR/WM_MAP_PTR = row bases
//        (set by scr_row_offset_to_w2 for SCREEN_ROW).
//   out: A, Y preserved. X preserved.
// -----------------------------------------------------------------------------
_scr_write_cell:
    sta (W2),y
    pha
    lda WM_FLAGS
    lsr                              // bit0 (WM on) → C, bit1 (lock) → bit0
    bcc _swc_done                    // WM off → done
    lsr                              // lock → C
    bcs _swc_done                    // locked → buffer only
    lda (WM_MAP_PTR),y
    cmp wm_idx
    bne _swc_done                    // cell owned by a window above us
    pla
    sta (WM_SCR_PTR),y
    rts
_swc_done:
    pla
    rts

// -----------------------------------------------------------------------------
// scr_row_offset_to_w2 — W2 = target row base for SCREEN_ROW (and, when the
// WM is live, WM_SCR_PTR / WM_MAP_PTR = the matching screen / MAP row bases
// offset by the window origin).
// scr_row_offset_to_w2_a — same for an arbitrary row in A.
//
// Boot config (wm_buf = $0400, stride 40): exactly the old fullscreen
// row-table lookup. WM config: base + row*stride via an add loop (rows ≤ 24,
// cold path next to the per-row work that follows it).
//   clobbers: A, X. W2 written (+ WM ptrs). Y preserved.
// -----------------------------------------------------------------------------
scr_row_offset_to_w2:
    lda SCREEN_ROW
    // fall through
scr_row_offset_to_w2_a:
    tax
    lda WM_FLAGS
    cmp #%00000001                   // on without lock?
    beq _sro_wm                      // → generic window path
    // WM off, or screen lock held (EDIT owns the whole screen): fullscreen.
    // Boot: target IS the screen; table lookup, no mirror pointers needed.
    lda screen_row_lo,x
    sta W2
    lda screen_row_hi,x
    sta W2+1
    rts

_sro_wm:
    // W2 = wm_buf + X * wm_w  (X = row)
    lda wm_buf
    sta W2
    lda wm_buf+1
    sta W2+1
    cpx #0
    beq _sro_rows_done
_sro_mul_loop:
    clc
    lda W2
    adc wm_w
    sta W2
    bcc !+
    inc W2+1
!:
    dex
    bne _sro_mul_loop
_sro_rows_done:

    // Mirror row bases for write-through, computed from SCREEN_ROW (the
    // _a entry with an arbitrary row leaves these stale — its only WM-path
    // caller is screen_scroll_up's last-row clear, which writes the buffer
    // directly and re-blits afterwards).
    //   WM_SCR_PTR = SCREEN_BASE + (wm_y0 + row)*40 + wm_x0   (row table)
    //   WM_MAP_PTR = WM_SCR_PTR - SCREEN_BASE + wm_map_base
    lda SCREEN_ROW
    clc
    adc wm_y0
    tax
    lda screen_row_lo,x
    clc
    adc wm_x0
    sta WM_SCR_PTR
    lda screen_row_hi,x
    adc #0
    sta WM_SCR_PTR+1

    sec
    lda WM_SCR_PTR
    sbc #<SCREEN_BASE
    sta WM_MAP_PTR
    lda WM_SCR_PTR+1
    sbc #>SCREEN_BASE
    sta WM_MAP_PTR+1
    clc
    lda WM_MAP_PTR
    adc wm_map_base
    sta WM_MAP_PTR
    lda WM_MAP_PTR+1
    adc wm_map_base+1
    sta WM_MAP_PTR+1
    rts

// MAP base (payload address of the kernel-owned 1000-byte map string; kept
// fresh by wm.asm after any GC). Zero while WM is off.
wm_map_base: .word 0

// -----------------------------------------------------------------------------
// scr40_row_to_w2_a — the old fullscreen row-base helper: W2 = $0400 + A*40,
// unconditionally, regardless of the current window target. Used by WSET /
// WGET and by the EDIT plugin (SYS_SCR_ROW_W2_A), which are whole-screen
// operations by contract (EDIT runs under the screen lock in the WM phase).
//   clobbers: A, X. W2 written.
// -----------------------------------------------------------------------------
scr40_row_to_w2_a:
    tax
    lda screen_row_lo,x
    sta W2
    lda screen_row_hi,x
    sta W2+1
    rts

// -----------------------------------------------------------------------------
// screen_row_lo / screen_row_hi — 25-entry tables of SCREEN_BASE + row*40.
// -----------------------------------------------------------------------------
screen_row_lo:
    .fill SCREEN_ROWS, <(SCREEN_BASE + i * SCREEN_COLS)
screen_row_hi:
    .fill SCREEN_ROWS, >(SCREEN_BASE + i * SCREEN_COLS)

// -----------------------------------------------------------------------------
// petscii_to_screen_code — full PETSCII → C64 screen-code translation.
//   in:  A = PETSCII byte   out: A = screen code   clobbers: Y. (X preserved.)
// -----------------------------------------------------------------------------
petscii_to_screen_code:
    cmp #$FF
    bne _ptsc_convert
    lda #$5E                     // π → π
    rts
_ptsc_convert:
    pha
    lsr
    lsr
    lsr
    lsr
    lsr
    tay
    pla
    clc
    adc _ptsc_table,y
    rts

_ptsc_table:
    .byte $80, $00, $C0, $E0, $40, $C0, $80, $80

// -----------------------------------------------------------------------------
// screen_scroll_up — slide the target's rows 1..H-1 up one position; blank
// the last row. Boot config: byte-identical to the old fullscreen scroll.
// WM config: the buffer is scrolled, then the whole window is re-blitted by
// wm_blit_window (owned cells only).
//   clobbers: A, X, Y, W2 (src ptr), W3 (count), GC_DEST (dst ptr).
// -----------------------------------------------------------------------------
screen_scroll_up:
    // GC_DEST = wm_buf (dest = row 0), W2 = wm_buf + stride (src = row 1).
    lda wm_buf
    sta GC_DEST
    clc
    adc wm_w
    sta W2
    lda wm_buf+1
    sta GC_DEST+1
    adc #0
    sta W2+1

    // W3 = (H-1) * W  (8x8→16 product via add loop; H ≤ 25)
    lda #0
    sta W3
    sta W3+1
    ldx wm_h
    dex
    beq _sscr_cnt_done
_sscr_cnt_loop:
    clc
    lda W3
    adc wm_w
    sta W3
    bcc !+
    inc W3+1
!:
    dex
    bne _sscr_cnt_loop
_sscr_cnt_done:

    jsr mem_copy_down                // mutates W2/GC_DEST/W3

    // Clear the last row: W2 = row base of H-1, then wm_w spaces.
    ldx wm_h
    dex
    txa
    jsr scr_row_offset_to_w2_a
    lda #$20
    ldy wm_w
_sscr_clr_loop:
    dey
    bmi _sscr_clr_done
    sta (W2),y
    jmp _sscr_clr_loop
_sscr_clr_done:

    // WM live → re-blit the window (scroll moved every row; write-through
    // above only covered the cleared row). wm_blit_window lives in wm.asm;
    // a flag test avoids the call entirely at boot.
    lda WM_FLAGS
    lsr
    bcc _sscr_done
    jmp wm_blit_window
_sscr_done:
    rts
