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
    lda #COLOR_BORDER
    sta VIC_BORDER
    lda #COLOR_BG
    sta VIC_BG

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
// screen_show_cursor — paint a static cursor at (SCREEN_ROW, SCREEN_COL).
//
// We write screen code $A0 (reverse-video space → solid block in default
// charset) directly to the cell. This is non-blinking; a 60 Hz IRQ-driven
// blink can be hooked at $0314 (CINV) later. The cursor mark is destroyed by
// the next `screen_put_char` at that position — callers refresh it after
// any output that should leave a visible "I'm waiting" indicator.
//
//   in:  (uses SCREEN_ROW / SCREEN_COL)
//   clobbers: A. W0/W1/W3/B preserved. W2 written.
// -----------------------------------------------------------------------------
screen_show_cursor:
    jsr scr_row_offset_to_w2         // W2 = SCREEN_BASE + row*40
    ldy SCREEN_COL
    lda #$A0                         // reverse-video space (solid block)
    sta (W2),y
    rts

// -----------------------------------------------------------------------------
// screen_put_char — write one PETSCII char to the screen at the cursor,
// advance cursor, scroll if we fall off the bottom.
//   in:  A = PETSCII byte
//   clobbers: A, X, Y. (W2, W3, GC_DEST clobbered if a scroll happens.)
// -----------------------------------------------------------------------------
screen_put_char:
    // Handle control chars first. $0D (carriage return) is the only one now.
    cmp #$0D
    bne scr_not_nl
    jmp scr_newline
scr_not_nl:

    // PETSCII → screen code translation.
    cmp #$40
    bcc scr_trans_done               // < $40: pass through
    cmp #$60
    bcs scr_trans_done               // >= $60: pass through (for now)
    sec
    sbc #$40                         // $40-$5F → $00-$1F (uppercase + @[\]^_)
scr_trans_done:

    // Compute screen RAM offset: (row * 40) + col. Row 0..24, col 0..39.
    // Stash the screen code on HW stack while we compute the pointer.
    pha

    // W2 = SCREEN_BASE + row*40 + col.
    // W3 = COLOR_BASE  + row*40 + col (shares low byte with W2; high byte
    // differs by ($D8 - $04) = $D4).
    jsr scr_row_offset_to_w2
    // W2 is now SCREEN_BASE + row*40.
    ldy SCREEN_COL
    pla                              // recover screen code
    sta (W2),y                       // write to screen RAM
    // Also write color (same offset, different base). Compose pointer inline.
    lda W2
    sta W3
    lda W2+1
    clc
    adc #>COLOR_BASE - >SCREEN_BASE  // $D4
    sta W3+1
    lda #COLOR_FG
    sta (W3),y

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
    // 40 = 32 + 8. Strategy: shift (W2) left 3 times → row*8, stash on HW
    // stack, shift 2 more → row*32, add back → row*40, then + SCREEN_BASE.
    lda SCREEN_ROW
    sta W2
    lda #0
    sta W2+1
    asl W2
    rol W2+1                         // * 2
    asl W2
    rol W2+1                         // * 4
    asl W2
    rol W2+1                         // * 8 — save this on HW stack
    lda W2+1
    pha
    lda W2
    pha
    asl W2
    rol W2+1                         // * 16
    asl W2
    rol W2+1                         // * 32
    // W2 += saved row*8.
    pla                              // row*8 low
    clc
    adc W2
    sta W2
    pla                              // row*8 high
    adc W2+1
    sta W2+1
    // W2 += SCREEN_BASE.
    clc
    lda W2
    adc #<SCREEN_BASE
    sta W2
    lda W2+1
    adc #>SCREEN_BASE
    sta W2+1
    rts

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
