// -----------------------------------------------------------------------------
// Direct VIC-II text screen output. Bypasses KERNAL CHROUT entirely — we own
// the PETSCII → screen-code translation, cursor state, and scrolling. KERNAL
// stays mapped for keyboard / disk I/O but we don't route output through it.
//
// Memory layout (assumes VIC-II bank 0 — default at reset):
//   SCREEN_BASE ($0400): 25×40 screen codes (different byte values from PETSCII)
//   COLOR_BASE  ($D800): 25×40 4-bit foreground colors (dual-ported through I/O)
//
// Assumes BASIC has been banked out ($01 = $36) before screen_init is called.
// None of the routines here touch BASIC ROM address space, but they all
// depend on I/O being mapped so writes to $D020 / $D021 / $D800 reach VIC-II
// instead of CHAREN-shadowed character ROM.
//
// PETSCII → screen-code translation (minimal subset for step 1):
//   $20-$3F: identity (digits, space, punctuation)
//   $40-$5F: subtract $40 (@, uppercase A-Z, [\]^_)
//   anything else: passed through unchanged for now
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"

// -----------------------------------------------------------------------------
// screen_init — clear screen to space + COLOR_FG, set border/bg, reset cursor.
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
    // boots into. This makes uppercase PETSCII render as proper uppercase
    // glyphs, which our banner and most user-typed source rely on. Switching
    // to $17 (shifted) would give lowercase a-z glyphs at the cost of having
    // uppercase PETSCII render as lowercase, which doesn't match BASIC.
    lda #$15
    sta VIC_MEMPTR

    // Fill color RAM ($D800-$DBE7, 1000 bytes) with COLOR_FG.
    // Use $D800..$DBFF (1024 bytes) — the extra 24 slots past row 24 are
    // harmless; no 16-bit loop needed.
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
    // Fall into screen_clear (which fills SCREEN_BASE with $20 + resets cursor).
    // No JSR — screen_clear ends with rts.

// -----------------------------------------------------------------------------
// screen_clear — fill SCREEN_BASE with screen-code space ($20), cursor → 0,0.
// Leaves color RAM and VIC registers alone.
//   clobbers: A, X.
// -----------------------------------------------------------------------------
screen_clear:
    ldx #0
    lda #$20                         // screen code for space
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

// -----------------------------------------------------------------------------
// screen_show_cursor — mark the cell at (SCREEN_ROW, SCREEN_COL) as the
// cursor by setting its screen-code's reverse-video bit (bit 7).
//
// Read-modify-write: we OR $80 into whatever glyph is already there. Over an
// empty cell ($20 space) that produces $A0 (reversed space = solid block);
// over a letter it inverts the letter's foreground/background. Either way
// the cell's underlying character is preserved, so screen_hide_cursor can
// strip the bit to restore the original glyph — important during line edit
// when the cursor sits over a typed character that must remain visible.
//
//   in:  (uses SCREEN_ROW / SCREEN_COL)
//   clobbers: A, Y. W0/W1/W3/B preserved. W2 written.
// -----------------------------------------------------------------------------
screen_show_cursor:
    jsr scr_row_offset_to_w2         // W2 = SCREEN_BASE + row*40
    ldy SCREEN_COL
    lda (W2),y
    ora #$80
    sta (W2),y
    rts

// -----------------------------------------------------------------------------
// screen_hide_cursor — counterpart of screen_show_cursor: clears bit 7 on the
// cell at (SCREEN_ROW, SCREEN_COL) so any glyph beneath the cursor returns to
// its non-reversed appearance. Cells that weren't reversed in the first place
// are unchanged.
//   clobbers: A, Y. (W2 written.)
// -----------------------------------------------------------------------------
screen_hide_cursor:
    jsr scr_row_offset_to_w2
    ldy SCREEN_COL
    lda (W2),y
    and #$7F
    sta (W2),y
    rts

// -----------------------------------------------------------------------------
// screen_put_char — write one PETSCII char to the screen at the cursor,
// advance cursor, scroll if we fall off the bottom.
//   in:  A = PETSCII byte
//   clobbers: A, X, Y. (W2 clobbered; GC_DEST clobbered if a scroll happens.)
//
// Writes screen RAM only — does NOT touch color RAM. The color of each cell
// stays whatever it was (initialized to COLOR_FG by screen_init at boot, and
// then under the user's control via MC.COLOR / direct POKE). SCREEN_BASE at
// $0400 is plain RAM regardless of $01, so no banking flip is needed.
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

    // Compute screen RAM offset: (row * 40) + col. Row 0..24, col 0..39.
    // Stash the screen code on HW stack while we compute the pointer.
    pha

    // W2 = SCREEN_BASE + row*40 + col.
    jsr scr_row_offset_to_w2
    ldy SCREEN_COL
    pla                              // recover screen code
    sta (W2),y                       // write to screen RAM

    // Advance cursor.
    inc SCREEN_COL
    lda SCREEN_COL
    cmp #SCREEN_COLS
    bcc scr_done                     // < 40: still on current row
    // Wrapped off right edge: fall into newline.
scr_newline:
    lda #0
    sta SCREEN_COL
    inc SCREEN_ROW
    lda SCREEN_ROW
    cmp #SCREEN_ROWS
    bcc scr_done                     // row still < 25
    // Row hit 25: scroll up, keep cursor at row 24.
    jsr screen_scroll_up
    lda #SCREEN_ROWS - 1
    sta SCREEN_ROW
scr_done:
    rts

// -----------------------------------------------------------------------------
// scr_row_offset_to_w2 — helper: W2 = SCREEN_BASE + SCREEN_ROW * 40.
// Uses HW stack for the one 16-bit temp so B regs remain untouched — this
// lets V4' callers (print_str and friends) keep their own B-state across
// screen_put_char.
//   clobbers: A. W2 written.
// -----------------------------------------------------------------------------
scr_row_offset_to_w2:
    lda SCREEN_ROW
    // fall through — wset/wget call _a with an arbitrary row in A instead.
scr_row_offset_to_w2_a:
    tax
    lda screen_row_lo,x
    sta W2
    lda screen_row_hi,x
    sta W2+1
    rts

// -----------------------------------------------------------------------------
// screen_row_lo / screen_row_hi — 25-byte tables holding the low/high bytes of
// `SCREEN_BASE + row * SCREEN_COLS` for each row 0..24. KickAss `.fill`
// computes them at assembly time from the ZP-friendly `row * 40` step.
//
// Replaces the previous shift-and-add; cuts ~95 cycles off every row-address
// calc (full-screen redraws save ~2.4 ms at 1 MHz). Net storage cost over the
// old shift code is ~+3 bytes; the speed win is worth the table.
// -----------------------------------------------------------------------------
screen_row_lo:
    .fill SCREEN_ROWS, <(SCREEN_BASE + i * SCREEN_COLS)
screen_row_hi:
    .fill SCREEN_ROWS, >(SCREEN_BASE + i * SCREEN_COLS)

// -----------------------------------------------------------------------------
// petscii_to_screen_code — full PETSCII → C64 screen-code translation.
//
//   in:  A = PETSCII byte (0..255)
//   out: A = screen code
//   clobbers: Y. (X preserved.)
//
// Strategy: use the top 3 bits of the PETSCII byte (P >> 5, range 0..7) to
// index an 8-byte offset table; the screen code is `table[P >> 5] + P`
// (mod 256). The general formula maps PETSCII uppercase $41..$5A to screen
// codes $01..$1A directly via `table[2] = $C0`. Single special case:
//   - PETSCII $FF is the π glyph; the formula would map to $7F (✓ check),
//     so we route it to $5E (π in screen codes).
// Mirrors common C64 BASIC editor practice.
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
// screen_scroll_up — slide rows 1-24 up one position; blank row 24.
// Reuses mem_copy_down from gc.asm for the 960-byte bulk copy.
//   clobbers: A, X, Y, W2 (src ptr), W3 (count), GC_DEST (dst ptr).
// -----------------------------------------------------------------------------
screen_scroll_up:
    // W2 = SCREEN_BASE + 40 (source = start of row 1).
    lda #<(SCREEN_BASE + SCREEN_COLS)
    sta W2
    lda #>(SCREEN_BASE + SCREEN_COLS)
    sta W2+1
    // GC_DEST = SCREEN_BASE (dest = start of row 0).
    lda #<SCREEN_BASE
    sta GC_DEST
    lda #>SCREEN_BASE
    sta GC_DEST+1
    // W3 = 24 * 40 = 960 bytes.
    lda #<((SCREEN_ROWS - 1) * SCREEN_COLS)
    sta W3
    lda #>((SCREEN_ROWS - 1) * SCREEN_COLS)
    sta W3+1
    jsr mem_copy_down

    // Clear row 24 (last row): 40 bytes at SCREEN_BASE + 24*40.
    ldx #SCREEN_COLS
    lda #$20
!loop:
    sta SCREEN_BASE + (SCREEN_ROWS - 1) * SCREEN_COLS - 1,x
    dex
    bne !loop-
    rts
