// -----------------------------------------------------------------------------
// gfx.asm — position-independent 6510 graphics routines for the Admiral
// graphics memory config (REBOOT(TRUE)). Assembled offline by KickAssembler;
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
.const B4 = $1C
.const B5 = $1D
.const B6 = $1E
.const B7 = $1F

.const BITMAP = $E000
.const MATRIX = $DC00
.const YTBL   = $FF40

// DRAW Bresenham scratch (absolute RAM, in the free $FF72-$FFF9 gap above the
// row table). Touched only by DRAW; safe in the graphics memory config.
.const DX0    = $FF72   // word — current x
.const DY0    = $FF74   // byte — current y
.const DX1    = $FF75   // word — end x
.const DY1    = $FF77   // byte — end y
.const DDX    = $FF78   // word, >= 0  — |x1-x0|
.const DDY    = $FF7A   // word, <= 0  — -|y1-y0|
.const DSX    = $FF7C   // word, signed (+1 / -1)
.const DSY    = $FF7E   // byte, signed (+1 / -1)
.const DERR   = $FF7F   // word, signed — Bresenham error
.const DE2    = $FF81   // word, signed — 2*err per iteration
.const DLOOP  = $FF83   // word — JMP-indirect target (= loop_top abs)

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

// ===== HIRES_SHOW: build row table at $FF40, then VIC -> mono hi-res =========
HIRES_SHOW:
        ldx #0
        lda #<BITMAP
        sta W0
        lda #>BITMAP
        sta W0+1
        ldy #25
hs_tbl:
        lda W0
        sta YTBL,x
        lda W0+1
        sta YTBL+1,x
        lda W0                  // running addr += 320 ($0140)
        clc
        adc #$40
        sta W0
        lda W0+1
        adc #$01
        sta W0+1
        inx
        inx
        dey
        bne hs_tbl
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

// ===== HIRES_COLOR(fg=W0, bg=W1): fill matrix with (fg<<4)|bg ================
HIRES_COLOR:
        ldy #0
        lda (W0),y              // fg
        asl
        asl
        asl
        asl
        sta W2
        lda (W1),y              // bg
        and #$0F
        ora W2
        sta W2                  // color byte
        lda #0
        sta W0
        lda #>MATRIX
        sta W0+1
        ldx #3                  // 3 pages: $DC00-$DEFF
        ldy #0
        lda W2
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

// ===== HIRES_PLOT(x=W0 16-bit, y=W1): set the pixel bit ======================
HIRES_PLOT:
        ldy #0
        lda (W0),y              // x lo
        sta B6
        iny
        lda (W0),y              // x hi
        sta B7
        ldy #0
        lda (W1),y              // y
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

// ===== HIRES_DRAW(x0=W0, y0=W1, x1=W2, y1=W3): Bresenham line ===============
// Standard integer Bresenham with the inlined hi-res plot. The per-iteration
// body is well over 127 bytes, so a backward branch can't reach the top — we
// finish each iteration with JMP (DLOOP) (the only "JMP" PI code may use:
// indirect through fixed RAM, not absolute into our own bytes). builtin_call
// hands us our own load address in $FB:$FC, so DLOOP = $FB:$FC + (hd_loop -
// HIRES_DRAW) is an assembly-time-known offset.
HIRES_DRAW:
        clc
        lda $FB
        adc #<(hd_loop - HIRES_DRAW)
        sta DLOOP
        lda $FC
        adc #>(hd_loop - HIRES_DRAW)
        sta DLOOP+1

        // --- read args ---
        ldy #0
        lda (W0),y
        sta DX0
        iny
        lda (W0),y
        sta DX0+1
        ldy #0
        lda (W1),y
        sta DY0
        lda (W2),y
        sta DX1
        iny
        lda (W2),y
        sta DX1+1
        ldy #0
        lda (W3),y
        sta DY1

        // --- DDX = |x1-x0|, DSX in {+1,-1} ---
        sec
        lda DX1
        sbc DX0
        sta DDX
        lda DX1+1
        sbc DX0+1
        sta DDX+1
        bpl hd_dxpos
        // negative: negate DDX, DSX = -1
        sec
        lda #0
        sbc DDX
        sta DDX
        lda #0
        sbc DDX+1
        sta DDX+1
        lda #$FF
        sta DSX
        sta DSX+1
        bne hd_dxdone            // A=$FF -> always taken
hd_dxpos:
        lda #1
        sta DSX
        lda #0
        sta DSX+1
hd_dxdone:

        // --- DDY = -|y1-y0|, DSY in {+1,-1} ---
        sec
        lda DY1
        sbc DY0
        sta B5                   // ty = y1-y0 (signed byte)
        bpl hd_typos
        // ty < 0: DDY = ty (sign-extended), DSY = -1
        sta DDY
        lda #$FF
        sta DDY+1
        lda #$FF
        sta DSY
        bne hd_dydone
hd_typos:
        // ty >= 0: DDY = -ty (16-bit), DSY = +1
        sec
        lda #0
        sbc B5
        sta DDY
        lda #0
        sbc #0
        sta DDY+1
        lda #1
        sta DSY
hd_dydone:

        // --- DERR = DDX + DDY ---
        clc
        lda DDX
        adc DDY
        sta DERR
        lda DDX+1
        adc DDY+1
        sta DERR+1

hd_loop:
        // --- inline plot(DX0, DY0) ---
        lda DY0
        and #$07
        sta B5
        lda DY0
        lsr
        lsr
        lsr
        asl
        tax
        lda YTBL,x
        sta $FB
        lda YTBL+1,x
        clc
        adc DX0+1
        sta $FC
        lda DX0
        and #$F8
        ora B5
        tay
        lda DX0
        and #$07
        tax
        lda #$80
hd_mk:
        dex
        bmi hd_mset
        lsr
        bpl hd_mk
hd_mset:
        ora ($FB),y
        sta ($FB),y

        // --- termination: if DX0==DX1 && DY0==DY1, rts ---
        lda DX0
        cmp DX1
        bne hd_more
        lda DX0+1
        cmp DX1+1
        bne hd_more
        lda DY0
        cmp DY1
        bne hd_more
        rts
hd_more:

        // --- DE2 = 2 * DERR ---
        lda DERR
        asl
        sta DE2
        lda DERR+1
        rol
        sta DE2+1

        // --- if DE2 >= DDY (signed): DERR += DDY; DX0 += DSX ---
        sec
        lda DE2
        sbc DDY
        lda DE2+1
        sbc DDY+1
        bvc hd_cx_ok
        eor #$80
hd_cx_ok:
        bmi hd_skip_x
        clc
        lda DERR
        adc DDY
        sta DERR
        lda DERR+1
        adc DDY+1
        sta DERR+1
        clc
        lda DX0
        adc DSX
        sta DX0
        lda DX0+1
        adc DSX+1
        sta DX0+1
hd_skip_x:

        // --- if DE2 <= DDX (signed): DERR += DDX; DY0 += DSY ---
        // i.e. DDX - DE2 >= 0 (signed). If negative -> DE2 > DDX -> skip.
        sec
        lda DDX
        sbc DE2
        lda DDX+1
        sbc DE2+1
        bvc hd_cy_ok
        eor #$80
hd_cy_ok:
        bmi hd_skip_y
        clc
        lda DERR
        adc DDX
        sta DERR
        lda DERR+1
        adc DDX+1
        sta DERR+1
        lda DY0
        clc
        adc DSY
        sta DY0
hd_skip_y:

        jmp (DLOOP)
HIRES_DRAW_END:

// ===== MC_SHOW: like HIRES_SHOW plus multicolor bitmap mode ($D016 MCM) ======
MC_SHOW:
        ldx #0
        lda #<BITMAP
        sta W0
        lda #>BITMAP
        sta W0+1
        ldy #25
mcs_tbl:
        lda W0
        sta YTBL,x
        lda W0+1
        sta YTBL+1,x
        lda W0
        clc
        adc #$40
        sta W0
        lda W0+1
        adc #$01
        sta W0+1
        inx
        inx
        dey
        bne mcs_tbl
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
        dec $01
        rts
MC_SHOW_END:

// ===== MC_COLOR(c01=W0, c10=W1, c11=W2): matrix nibbles + color RAM ==========
MC_COLOR:
        ldy #0
        lda (W0),y              // c01
        asl
        asl
        asl
        asl
        sta B4
        lda (W1),y              // c10
        and #$0F
        ora B4
        sta B4                  // matrix byte = (c01<<4)|c10
        lda (W2),y              // c11
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

// ===== MC_PLOT(x=W0 0..159, y=W1, ink=W2 0..3): set the 2-bit pixel ==========
MC_PLOT:
        ldy #0
        lda (W0),y              // x (0..159)
        sta B6
        lda (W1),y              // y
        sta B4
        lda (W2),y              // ink (0..3)
        sta B7                  // save ink before Y is repurposed
        lda B4
        and #$07
        sta B5                  // y & 7
        lda B4
        lsr
        lsr
        lsr                     // charrow
        asl
        tax
        lda YTBL,x
        sta W0
        lda YTBL+1,x
        sta W0+1                // x<256 -> no hi carry
        lda B6                  // Y = (x>>2)*8 + (y&7)
        lsr
        lsr                     // x>>2 (0..39)
        asl
        asl
        asl                     // *8
        ora B5
        tay
        lda B6                  // shift = (3 - (x&3)) * 2  (0,2,4,6)
        and #$03
        eor #$03
        asl
        tax
        lda #$03                // field mask (2 bits) -> B6; ink -> B7, shifted
        sta B6
mp_sh:
        cpx #0
        beq mp_set
        asl B7
        asl B6
        dex
        bne mp_sh
mp_set:
        lda B6                  // ~fieldmask
        eor #$FF
        and (W0),y              // clear the 2-bit field
        ora B7                  // set ink<<shift
        sta (W0),y
        rts
MC_PLOT_END:
