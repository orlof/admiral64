// -----------------------------------------------------------------------------
// gfx.asm — position-independent 6510 graphics routines for the Admiral
// graphics memory config (BITMAP(TRUE)). Assembled offline by KickAssembler;
// tools/gfx_pack.py slices each routine by its label and emits the bytes as
// \xNN code strings into examples/{text,hires,mc}.admiral.
//
// CALL convention: args arrive as handle addresses in W0..W3 (an inline int's
// value bytes live AT the handle, so (W0),0 is its low byte; x is 16-bit via
// (W0),0/1). Result (unused here) would go in W0. Routines may clobber
// W0..W3 / B0..B7 / A / X / Y and end in RTS. They write plain RAM ($01=$34);
// only the SHOW routines bank I/O ($01=$35) to touch VIC registers.
//
// Position-independence: only relative branches internally (no JMP / no
// self-reference); all absolute addresses are FIXED targets (VIC regs, bitmap
// $E000, matrix $DC00, row table $FF40) — safe to relocate.
//
// Memory: bitmap $E000-$FF3F, color matrix $DC00-$DFE7, row table $FF40
// (25 words: bitmap address of each char row, $E000 + r*320).
// -----------------------------------------------------------------------------

.const W0 = $10
.const W1 = $12
.const W2 = $14
.const W3 = $16
.const B0 = $18
.const B1 = $19
.const B2 = $1A
.const B3 = $1B
.const B4 = $1C
.const B5 = $1D
.const B6 = $1E
.const B7 = $1F

.const BITMAP = $E000
.const MATRIX = $DC00
.const YTBL   = $FF40

// HIRES_DRAW scratch in the free $FF72+ gap (above the 50-byte row table).
// We only need 8 bytes total: 6 for the args (read once at entry, then dead)
// and 2 for the Bresenham error term (live across the loop).
.const ARG_X0   = $FF72       // word
.const ARG_Y0   = $FF74       // byte
.const ARG_X1   = $FF75       // word
.const ARG_Y1   = $FF77       // byte
.const DERR     = $FF78       // word, signed
.const DLOOP    = $FF7A       // word — HIRES_DRAW x-loop indirect-JMP target

* = $1000   // arbitrary; routines are position-independent

// ===== TEXT_SHOW: VIC -> 40x25 text, bank 0, screen $0400, charset ROM =======
TEXT_SHOW:
        inc $01                 // $34 -> $35 (I/O in)
        lda $DD02
        ora #$03
        sta $DD02
        lda $DD00
        ora #$03                // CIA2 bank bits = %11 -> bank 0
        sta $DD00
        lda #$15
        sta $D018               // screen $0400, charset ROM
        lda #$1B
        sta $D011               // DEN+RSEL, BMM=0 (text)
        lda #$C8
        sta $D016               // 40-col, MCM=0
        dec $01                 // $35 -> $34
        rts
TEXT_SHOW_END:

// ===== HIRES_SHOW: VIC -> mono hi-res (row table built by BITMAP(TRUE)) ====
HIRES_SHOW:
        inc $01                 // I/O in
        lda $DD02
        ora #$03
        sta $DD02
        lda $DD00
        and #$FC                // CIA2 bank bits = %00 -> bank 3
        sta $DD00
        lda #$78
        sta $D018               // matrix $DC00, bitmap $E000
        lda #$3B
        sta $D011               // BMM+DEN+RSEL
        lda #$C8
        sta $D016               // 40-col, MCM=0 (mono)
        dec $01
        rts
HIRES_SHOW_END:

// ===== HIRES_CLS / MC_CLS: zero the bitmap $E000-$FF3F (8000 bytes) ==========
GFX_CLS:
        lda #0
        sta W0
        lda #>BITMAP
        sta W0+1
        ldx #31                 // 31 full pages: $E000-$FEFF
        ldy #0
        lda #0
gc_pg:
        sta (W0),y
        iny
        bne gc_pg
        inc W0+1
        dex
        bne gc_pg
        ldy #0                  // tail: $FF00-$FF3F (64 bytes)
gc_tail:
        sta $FF00,y
        iny
        cpy #$40
        bne gc_tail
        rts
GFX_CLS_END:

// ===== HIRES_COLOR(fg=W1, bg=W2): fill matrix with (fg<<4)|bg ================
HIRES_COLOR:
        ldy #0
        lda (W1),y              // fg
        asl
        asl
        asl
        asl
        sta B4                  // B4 = fg<<4 (avoid clobbering W2 = bg arg)
        lda (W2),y              // bg
        and #$0F
        ora B4
        sta B4                  // B4 = color byte
        lda #0
        sta W0                  // W0 (base) is no longer needed → reuse as ptr
        lda #>MATRIX
        sta W0+1
        ldx #3                  // 3 pages: $DC00-$DEFF
        ldy #0
        lda B4
hc_pg:
        sta (W0),y
        iny
        bne hc_pg
        inc W0+1
        dex
        bne hc_pg
        ldy #0                  // tail: $DF00-$DFE7 (232 bytes)
hc_tail:
        sta $DF00,y
        iny
        cpy #$E8
        bne hc_tail
        rts
HIRES_COLOR_END:

// ===== HIRES_PLOT(x=W1 16-bit, y=W2): set the pixel bit ======================
HIRES_PLOT:
        ldy #0
        lda (W1),y              // x lo
        sta B6
        iny
        lda (W1),y              // x hi
        sta B7
        ldy #0
        lda (W2),y              // y
        sta B4
        and #$07
        sta B5                  // y & 7
        lda B4
        lsr
        lsr
        lsr                     // charrow
        asl                     // *2 (word index)
        tax
        lda YTBL,x
        sta W0
        lda YTBL+1,x
        clc
        adc B7                  // + x_hi
        sta W0+1
        lda B6
        and #$F8
        ora B5
        tay                     // Y = (x_lo & $F8) | (y&7)
        lda B6
        and #$07
        tax                     // shift count
        lda #$80
hp_msk:
        dex
        bmi hp_set
        lsr
        bpl hp_msk              // N=0 after LSR -> always taken
hp_set:
        ora (W0),y
        sta (W0),y
        rts
HIRES_PLOT_END:

// ===== HIRES_DRAW(x0=W1, y0=W2, x1=W3, y1=B0:B1): Bresenham line =============
// Port of xcb3 lib_gfx's `Draw` (single-buffer, set-mode-only). Count-driven,
// x-major / y-major split, incremental pointer — the body fits in backward-
// branch range so no JMP-indirect / DLOOP cell is needed (and W0 — the code
// base in the new ABI — is therefore free to repurpose as the bitmap ptr).
//
// State (after args are read into scratch):
//   W0 (16-bit) = current bitmap pointer (cell-base; pixel byte = W0 + Y)
//   W1 (16-bit) = dx = |x1-x0|
//   W2 (16-bit) = loop count
//   B0  = dy = |y1-y0|   (0..199 fits in a byte unsigned)
//   B1  = Xi: $00 = right, $FF = left
//   B2  = Yi: $00 = down,  $FF = up
//   B3  = current bit mask within the cell byte
//   DERR (16-bit) = Bresenham error term
//   Y reg = current within-cell row (0..7)
HIRES_DRAW:
        // W0 = our load address. The x-major loop body AND the dispatcher-to-
        // hd_x_major distance both sit just past 127 bytes, so we use one
        // DLOOP cell + JMP-indirect for both. Save the base in B5:B6 for the
        // mid-routine recompute, and set DLOOP = hd_x_major up front.
        lda W0
        sta B5
        lda W0+1
        sta B6
        clc
        lda B5
        adc #<(hd_x_major - HIRES_DRAW)
        sta DLOOP
        lda B6
        adc #>(hd_x_major - HIRES_DRAW)
        sta DLOOP+1

        // --- read args into ARG_* scratch (then ZP regs are free to reuse) ---
        ldy #0
        lda (W1),y                  // x0 lo
        sta ARG_X0
        iny
        lda (W1),y                  // x0 hi
        sta ARG_X0+1
        ldy #0
        lda (W2),y                  // y0
        sta ARG_Y0
        lda (W3),y                  // x1 lo
        sta ARG_X1
        iny
        lda (W3),y                  // x1 hi
        sta ARG_X1+1
        ldy #0
        lda (B0),y                  // y1   (arg 4 → B0:B1 indirect)
        sta ARG_Y1

        // --- dx = |x1-x0|, Xi in {0,$FF}; dy = |y1-y0|, Yi in {0,$FF} ---
        ldx #0                       // Xi default = right
        ldy #0                       // Yi default = down

        lda ARG_X1                   // dx = x1 - x0 (16-bit)
        sec
        sbc ARG_X0
        sta W1
        lda ARG_X1+1
        sbc ARG_X0+1
        sta W1+1
        bcs hd_dx_pos                // C=1 -> x1 >= x0 (unsigned) -> dx >= 0
        dex                          // Xi = $FF (left)
        lda #1                       // dx = abs(dx)  (carry-aware 2's-comp)
        sbc W1
        sta W1
        lda #0
        sbc W1+1
        sta W1+1
hd_dx_pos:

        lda ARG_Y1                   // dy = y1 - y0 (byte unsigned via BCS)
        sec
        sbc ARG_Y0
        bcs hd_dy_pos
        dey                          // Yi = $FF (up)
        eor #$FF                     // dy = abs(dy)
        adc #1
hd_dy_pos:
        sta B0                       // B0 = dy

        stx B1                       // B1 = Xi
        sty B2                       // B2 = Yi

        // --- initial bitmap pointer in W0, Y = y0 & 7, mask in B3 ---
        lda ARG_Y0
        and #$07
        tay                          // Y = within-cell row
        eor ARG_Y0                   // A = y0 & ~7 = charrow * 8
        lsr
        lsr                          // A = charrow * 2 (byte offset into YTBL)
        tax

        clc                          // (LSR cleared C; explicit clc for clarity)
        lda ARG_X0
        and #$F8                     // x0_lo & ~7 (byte offset within row)
        adc YTBL,x
        sta W0
        lda YTBL+1,x
        adc ARG_X0+1                 // + x0_hi (carry from low add)
        sta W0+1

        lda ARG_X0
        and #$07
        tax                          // X = x0 & 7 (mask shift count)
        lda #$80
hd_mk_loop:
        dex
        bmi hd_mk_done
        lsr
        bpl hd_mk_loop               // LSR clears N -> always taken
hd_mk_done:
        sta B3                       // B3 = mask

        // --- plot the first point ---
        ora (W0),y                   // A still = mask
        sta (W0),y

        // Local relay: hd_x_major is past the relative-branch reach, so the
        // dispatch branches BACKWARD to this short JMP indirect (DLOOP holds
        // hd_x_major's address at this point — set at entry).
        clv
        bvc _past_relay
hd_x_relay:
        jmp (DLOOP)
_past_relay:

        // --- choose major axis: x-major if dx >= dy (16-bit dx vs 8-bit dy) ---
        lda W1+1
        bne hd_x_relay
        lda W1
        cmp B0
        bcs hd_x_relay

        // ===== y-major: count = dy, each step moves y; sometimes also x =====
        // (dy == 0 can't reach here — that case took the bcs hd_x_major path.)
        lda B0
        sta W2                       // W2 = count = dy (byte; W2+1 ignored)
        lsr
        sta DERR                     // err = dy/2

hd_y_loop:
        lda B2                       // Yi
        bmi hd_y_up
hd_y_down:
        iny
        cpy #8
        bcc hd_y_err                 // Y still 0..7, no cell crossing
        ldy #0
        lda W0
        adc #$3F                     // C still 1 from cpy #8 -> +$40
        sta W0
        lda W0+1
        adc #1                       // overall W0 += $0140 = +320 (next row)
        bcc hd_y_base_hi             // (won't underflow within the bitmap)
hd_y_up:
        dey
        bpl hd_y_err                 // Y still in 0..6, no cell crossing
        ldy #7
        sec
        lda W0
        sbc #$40
        sta W0
        lda W0+1
        sbc #1                       // overall W0 -= $0140
hd_y_base_hi:
        sta W0+1

hd_y_err:
        // err += dx; if err >= dy, err -= dy and step x.
        // X holds a "phantom high bit of err": 1 if the low add didn't carry
        // (err_hi stays 0), 0 if it did (err_hi went to 1). After SBC dy of
        // the low byte, DEX gives 0 in the no-carry-and-also-lo<dy case (skip
        // step-x); $FF when lo carried but lo<dy after sbc (still step-x).
        ldx #0
        lda DERR
        clc
        adc W1                       // err_lo += dx_lo
        sta DERR
        bcs hd_y_sub
        inx                          // no low-carry -> phantom hi = 1
        sec                          // restore C for the next SBC
hd_y_sub:
        sbc B0                       // tentative err_lo - dy
        bcs hd_y_step_x
        dex
        beq hd_y_plot                // no low-carry AND lo<dy -> skip step-x
hd_y_step_x:
        sta DERR                     // commit subtracted err_lo
        lda B1                       // Xi
        bmi hd_y_left
hd_y_right:
        lsr B3                       // mask >>= 1
        bcc hd_y_plot
        ror B3                       // mask wrapped -> $80 again
        lda W0
        adc #8                       // (C=0 after ROR with C=0)
        sta W0
        bcc hd_y_plot
        inc W0+1
        bne hd_y_plot                // BNE always (inc rarely lands on 0)
hd_y_left:
        asl B3                       // mask <<= 1
        bcc hd_y_plot
        rol B3                       // mask wrapped -> $01 again
        lda W0
        sbc #7                       // C=0 after ROL -> effective -8
        sta W0
        bcs hd_y_plot
        dec W0+1

hd_y_plot:
        lda B3
        ora (W0),y
        sta (W0),y

        dec W2
        bne hd_y_loop
        rts

        // ===== x-major: count = dx (16-bit), each step moves x; sometimes y =====
hd_x_major:
        // DLOOP = base + (hd_x_loop - HIRES_DRAW). The base was saved into
        // B5:B6 at entry; W0 itself has been overwritten by the bitmap ptr.
        clc
        lda B5
        adc #<(hd_x_loop - HIRES_DRAW)
        sta DLOOP
        lda B6
        adc #>(hd_x_loop - HIRES_DRAW)
        sta DLOOP+1

        lda W1                       // count = dx
        sta W2
        lda W1+1
        sta W2+1
        ora W2
        bne _xm_have_count           // dx > 0 — proceed
        rts                           // dx == 0 — single point (already plotted)
_xm_have_count:

        lda W1+1                     // err = dx / 2
        lsr
        sta DERR+1
        lda W1
        ror
        sta DERR

hd_x_loop:
        lda B1                       // Xi
        bmi hd_x_left
hd_x_right:
        lsr B3
        bcc hd_x_err
        ror B3
        lda W0
        adc #8
        sta W0
        bcc hd_x_err
        inc W0+1
        bne hd_x_err
hd_x_left:
        asl B3
        bcc hd_x_err
        rol B3
        lda W0
        sbc #7
        sta W0
        bcs hd_x_err
        dec W0+1

hd_x_err:
        // err += dy (8-bit into 16-bit DERR)
        lda DERR
        clc
        adc B0
        sta DERR
        bcc hd_x_test_dx
        inc DERR+1
hd_x_test_dx:
        // if err >= dx, err -= dx and step y
        sec
        sbc W1                       // A still = DERR (sta doesn't change A)
        tax
        lda DERR+1
        sbc W1+1
        bcc hd_x_plot                // err < dx -> no y step
        stx DERR
        sta DERR+1
        lda B2                       // Yi
        bmi hd_x_up
hd_x_down:
        iny
        cpy #8
        bcc hd_x_plot
        ldy #0
        lda W0
        adc #$3F
        sta W0
        lda W0+1
        adc #1
        bcc hd_x_base_hi
hd_x_up:
        dey
        bpl hd_x_plot
        ldy #7
        lda W0
        sbc #$40
        sta W0
        lda W0+1
        sbc #1
hd_x_base_hi:
        sta W0+1

hd_x_plot:
        lda B3
        ora (W0),y
        sta (W0),y

        // 16-bit dec count, exit when both bytes zero. (Works for count up to
        // $01FF — our dx range tops at 319 = $013F, well within this.)
        ldx W2
        bne hd_x_dec_lo
        dec W2+1
        bne hd_done                  // hi went from 1 to 0 means lo wraps next iter
hd_x_dec_lo:
        dex
        stx W2
        txa
        ora W2+1
        beq hd_done
        jmp (DLOOP)                  // body is past branch range; indirect JMP
hd_done:
        rts
HIRES_DRAW_END:

// ===== MC_SHOW: VIC -> multicolor bitmap mode (row table from BITMAP) ======
// Also sets $D021 (ink-0 / bg) to blue as a sensible default. Color RAM at
// $D800 (ink-3) is left to MC.COLOR — filling it from here would write under
// VIC bank 3's bitmap RAM where the heap also lives (RAM and color RAM share
// $D800 addresses but live on different planes selected by $01; the tests run
// without banking so the auto-fill would clobber heap handles).
MC_SHOW:
        inc $01
        lda $DD02
        ora #$03
        sta $DD02
        lda $DD00
        and #$FC
        sta $DD00               // bank 3
        lda #$78
        sta $D018
        lda #$3B
        sta $D011               // BMM+DEN+RSEL
        lda #$D8
        sta $D016               // 40-col, MCM=1
        lda #$06
        sta $D021               // ink-0 bg = blue
        dec $01
        rts
MC_SHOW_END:

// ===== MC_COLOR(c01=W1, c10=W2, c11=W3): matrix nibbles + color RAM ==========
MC_COLOR:
        ldy #0
        lda (W1),y              // c01
        asl
        asl
        asl
        asl
        sta B4
        lda (W2),y              // c10
        and #$0F
        ora B4
        sta B4                  // matrix byte = (c01<<4)|c10
        lda (W3),y              // c11
        and #$0F
        sta B5                  // color-RAM byte
        // fill matrix $DC00-$DFE7 (1000) with B4
        lda #0
        sta W0
        lda #>MATRIX
        sta W0+1
        ldx #3
        ldy #0
        lda B4
mcc_pg:
        sta (W0),y
        iny
        bne mcc_pg
        inc W0+1
        dex
        bne mcc_pg
        ldy #0
        lda B4
mcc_tail:
        sta $DF00,y
        iny
        cpy #$E8
        bne mcc_tail
        // fill color RAM $D800-$DBE7 (1000) with B5 (needs I/O)
        inc $01
        lda #0
        sta W0
        lda #$D8
        sta W0+1
        ldx #3
        ldy #0
        lda B5
mcc_cpg:
        sta (W0),y
        iny
        bne mcc_cpg
        inc W0+1
        dex
        bne mcc_cpg
        ldy #0
        lda B5
mcc_ctail:
        sta $DB00,y             // $DB00-$DBE7 (232 bytes)
        iny
        cpy #$E8
        bne mcc_ctail
        dec $01
        rts
MC_COLOR_END:

// ===== MC_PLOT(x=W1 0..159, y=W2, ink=W3 0..3): set the 2-bit pixel ==========
// Port of xcb3 lib_gfx's PlotMC. Byte addressing uses the same `asl; rol W0+1`
// carry trick as the hi-res routines so x_mc >= 128 doesn't lose the high
// byte. Mask + pattern are computed inline (no fixed tables in RAM).
//
//   byte_addr  = YTBL[charrow] + (x & $FC) * 2
//   Y register = y & 7                       (within-cell row)
//   pixel bit-field = bits at position (3 - (x & 3)) * 2 within the byte
MC_PLOT:
        // Read args.
        ldy #0
        lda (W1),y              // x_mc (0..159)
        sta B6
        lda (W2),y              // y    (0..199)
        sta B4
        lda (W3),y              // ink  (0..3)
        sta B7

        // Y = y & 7 (within-cell row).
        lda B4
        and #$07
        tay
        sta B5                  // save for the charrow calc

        // X = charrow * 2 (word offset into YTBL).
        lda B4
        eor B5                  // y & ~7 = charrow * 8
        lsr                     // charrow * 4
        lsr                     // charrow * 2
        tax

        // W0 = YTBL[charrow] + (x & $FC) * 2 — the column byte offset within
        // the row is up to 320, so we asl into a fresh W0+1 to capture the
        // carry, then chain the row-base add.
        lda #0
        sta W0+1
        lda B6
        and #$FC
        asl                     // (x & $FC) * 2, low byte; C = carry
        rol W0+1                // shift carry into W0+1 bit 0
        adc YTBL,x              // + row base low
        sta W0
        lda YTBL+1,x
        adc W0+1                // + row base high + previous carry
        sta W0+1

        // Shift count = (3 - (x & 3)) * 2 in {0, 2, 4, 6}.
        lda B6
        and #$03
        eor #$03
        asl
        tax

        // B6 = field mask (3 << shift), B7 = ink << shift. Both start at the
        // low end and shift left together.
        lda #$03
        sta B6
mc_sh:
        cpx #0
        beq mc_set
        asl B7
        asl B6
        dex
        bne mc_sh
mc_set:
        lda B6
        eor #$FF
        and (W0),y              // clear the 2-bit field
        ora B7                  // set ink<<shift
        sta (W0),y
        rts
MC_PLOT_END:
