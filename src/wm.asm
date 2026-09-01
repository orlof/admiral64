// -----------------------------------------------------------------------------
// wm.asm — the window manager (PLANS/ui-primitives.md v4).
//
// Model: WINDOWS (a TYPE_LIST) is the z-order, last = topmost. A window is a
// plain TYPE_DICT: {"X","Y","W","H" outer rect ints, "T" title STR (present
// only for bordered windows), "BUF" cell buffer STR (interior only, stride =
// interior width), "R","C" cursor ints}. MAP is a kernel-owned 1000-byte STR:
// per screen cell, the z-index of the owning window. The screen itself is
// painted only by wm_refresh and by screen.asm's write-through
// (_scr_write_cell) for owned cells.
//
// Lazy start: the first WINDOW() call allocates MAP + a fullscreen borderless
// ROOT window that inherits the current screen contents, binds it to the
// global name ROOT, and flips WM_FLAGS bit 0.
//
// Interior vs. outer: a bordered window's buffer covers the interior
// (W-2 x H-2 at X+1,Y+1); the border+title live only on screen, drawn by
// wm_refresh. A borderless window's buffer covers the full rect.
//
// GC: the five kernel handles below are marked via wm_gc_mark_roots (called
// from gc_mark) and the two derived raw pointers (wm_map_base in screen.asm,
// wm_buf target) are refreshed by wm_gc_rederef (called from gc_compact).
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"

// --- kernel window state (handles; 0 = not started) --------------------------
wm_windows:  .word 0     // TYPE_LIST, z-order
wm_map_h:    .word 0     // TYPE_STR, 1000 bytes
wm_root_h:   .word 0     // TYPE_DICT, fullscreen ROOT
wm_cur_h:    .word 0     // TYPE_DICT, current output window
wm_curbuf_h: .word 0     // TYPE_STR, current window's BUF (for re-deref)

// mkwin parameter block
wmk_x:     .byte 0
wmk_y:     .byte 0
wmk_w:     .byte 0
wmk_h:     .byte 0
wmk_title: .word 0       // TYPE_STR handle or 0 (borderless)
wmk_inherit: .byte 0     // 1 = BUF inherits screen cells, 0 = fill $20

// scratch (not live across V4' sub-calls)
wm_t0:     .byte 0
wm_t1:     .byte 0
wm_t2:     .byte 0
wm_t3:     .byte 0
wm_iw:     .byte 0       // interior width of the window being worked on
wm_ih:     .byte 0       // interior height
wm_ix:     .byte 0       // interior origin x (absolute)
wm_t4:     .byte 0       // border/title scratch
wm_attr_z: .byte 0       // ATTR: window z-index
wm_attr_f: .byte 0       // ATTR: flags
wm_iy:     .byte 0       // interior origin y (absolute)

// --- dict key statics (handle struct + inline payload, like statics.asm) ----
WM_STR_X:
    .word WM_STR_X_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
WM_STR_X_OBJ:
    .word 1
    .text "X"

WM_STR_Y:
    .word WM_STR_Y_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
WM_STR_Y_OBJ:
    .word 1
    .text "Y"

WM_STR_W:
    .word WM_STR_W_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
WM_STR_W_OBJ:
    .word 1
    .text "W"

WM_STR_H:
    .word WM_STR_H_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
WM_STR_H_OBJ:
    .word 1
    .text "H"

WM_STR_T:
    .word WM_STR_T_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
WM_STR_T_OBJ:
    .word 1
    .text "T"

WM_STR_R:
    .word WM_STR_R_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
WM_STR_R_OBJ:
    .word 1
    .text "R"

WM_STR_C:
    .word WM_STR_C_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
WM_STR_C_OBJ:
    .word 1
    .text "C"

WM_STR_BUF:
    .word WM_STR_BUF_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
WM_STR_BUF_OBJ:
    .word 3
    .text "BUF"

WM_STR_ROOT:
    .word WM_STR_ROOT_OBJ
    .word 6
    .word 0
    .byte TYPE_STR
    .byte 0
WM_STR_ROOT_OBJ:
    .word 4
    .text "ROOT"

// key table for wm_dget_x / wm_dset_int_x (X = key index)
.const WMK_X = 0
.const WMK_Y = 2
.const WMK_W = 4
.const WMK_H = 6
.const WMK_T = 8
.const WMK_R = 10
.const WMK_C = 12
.const WMK_BUF = 14
wm_key_tab:
    .word WM_STR_X, WM_STR_Y, WM_STR_W, WM_STR_H
    .word WM_STR_T, WM_STR_R, WM_STR_C, WM_STR_BUF

// -----------------------------------------------------------------------------
// wm_dget_x — RV = dict[key]. Plain subroutine (dict_get is V4' and preserves
// our W/B file).
//   in:  W0 = dict handle, X = WMK_* key index.
//   out: RV = value handle (NONE if absent). W0 preserved.
// -----------------------------------------------------------------------------
wm_dget_x:
    rs_push(W0)
    lda wm_key_tab,x
    ldy wm_key_tab+1,x
    sta W1
    sty W1+1
    rs_push(W1)
    jmp dict_get                     // consumes 2; RV = value; rts from there

// -----------------------------------------------------------------------------
// wm_dget_byte_x — A = low byte of int dict[key].
//   in:  W0 = dict, X = WMK_*.   out: A. W0 preserved.
// -----------------------------------------------------------------------------
wm_dget_byte_x:
    jsr wm_dget_x
    ldy #0
    lda (RV),y
    rts

// -----------------------------------------------------------------------------
// wm_dset_int_x — dict[key] = inline int A (0..255).
//   in:  W0 = dict handle, X = WMK_* key index, A = value.
//   out: W0 preserved (V4' sub-calls preserve it).
// -----------------------------------------------------------------------------
wm_dset_int_x:
    sta wm_t0
    stx wm_t1
    rs_push(W0)                      // RS: [dict] (also roots it)
    lda wm_t0
    sta W2
    lda #0
    sta W2+1
    sta W3
    sta W3+1
    jsr alloc_inline_int             // RV = int handle (may GC)
    rs_pop(W0)                       // W0 = dict again
    rs_push(W0)
    ldx wm_t1
    lda wm_key_tab,x
    ldy wm_key_tab+1,x
    sta W1
    sty W1+1
    rs_push(W1)
    rs_push(RV)
    jmp dict_set                     // consumes 3; rts from there

// -----------------------------------------------------------------------------
// wm_dset_h — dict[key] = handle in W1.
//   in:  W0 = dict, X = WMK_*, W1 = value handle.
// -----------------------------------------------------------------------------
wm_dset_h:
    rs_push(W0)
    lda wm_key_tab,x
    ldy wm_key_tab+1,x
    sta W2
    sty W2+1
    rs_push(W2)
    rs_push(W1)
    jmp dict_set

// -----------------------------------------------------------------------------
// wm_interior — read the window in W0's geometry into wm_ix/iy/iw/ih
// (interior) and set C = border flag (set = bordered).
//   in:  W0 = window dict.   clobbers: A, X, Y. W0 preserved.
// -----------------------------------------------------------------------------
wm_interior:
    ldx #WMK_X
    jsr wm_dget_byte_x
    sta wm_ix
    ldx #WMK_Y
    jsr wm_dget_byte_x
    sta wm_iy
    ldx #WMK_W
    jsr wm_dget_byte_x
    sta wm_iw
    ldx #WMK_H
    jsr wm_dget_byte_x
    sta wm_ih
    // bordered? ("T" present and != NONE)
    ldx #WMK_T
    jsr wm_dget_x
    lda RV
    cmp #<NONE
    bne _wi_bordered
    lda RV+1
    cmp #>NONE
    bne _wi_bordered
    clc
    rts
_wi_bordered:
    inc wm_ix
    inc wm_iy
    dec wm_iw
    dec wm_iw
    dec wm_ih
    dec wm_ih
    sec
    rts

// -----------------------------------------------------------------------------
// wm_row40 — WM_SCR_PTR = $0400 + A*40, WM_MAP_PTR = map_base + A*40.
// Absolute screen row helpers for refresh/blit. Leaf.
//   in: A = absolute row 0..24.  clobbers: A, X.
// -----------------------------------------------------------------------------
wm_row40:
    tax
    lda screen_row_lo,x
    sta WM_SCR_PTR
    lda screen_row_hi,x
    sta WM_SCR_PTR+1
    // WM_MAP_PTR = map_base + row*40 = map_base + (table[x] - SCREEN_BASE)
    sec
    lda screen_row_lo,x
    sbc #<SCREEN_BASE
    sta WM_MAP_PTR
    lda screen_row_hi,x
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

// -----------------------------------------------------------------------------
// wm_map_zero — zero the 1000-byte MAP payload. Leaf; clobbers A,X,Y,W2,W3.
// -----------------------------------------------------------------------------
wm_map_zero:
    lda wm_map_base
    sta W2
    lda wm_map_base+1
    sta W2+1
    lda #<1000
    sta W3
    lda #>1000
    sta W3+1
    ldy #0
_wmz_loop:
    lda W3
    ora W3+1
    beq _wmz_done
    lda #0
    sta (W2),y
    inc W2
    bne !+
    inc W2+1
!:
    lda W3
    bne !+
    dec W3+1
!:
    dec W3
    jmp _wmz_loop
_wmz_done:
    rts

// -----------------------------------------------------------------------------
// wm_gc_mark_roots — OR MARKED|GRAY into the kernel window handles. Called
// from gc_mark before phase 2. Clobbers A, Y, W1.
// -----------------------------------------------------------------------------
wm_gc_mark_roots:
    ldx #0
_wgm_loop:
    lda _wgm_tab,x
    sta W1
    lda _wgm_tab+1,x
    sta W1+1
    // W1 = address of the static cell; load the handle it holds
    ldy #0
    lda (W1),y
    pha
    iny
    lda (W1),y
    sta W1+1
    pla
    sta W1
    ora W1+1
    beq _wgm_next
    ldy #H_FLAGS
    lda (W1),y
    ora #FLAG_MARKED|FLAG_GRAY
    sta (W1),y
_wgm_next:
    inx
    inx
    cpx #10
    bne _wgm_loop
    rts
_wgm_tab:
    .word wm_windows, wm_map_h, wm_root_h, wm_cur_h, wm_curbuf_h

// -----------------------------------------------------------------------------
// wm_gc_rederef — refresh the raw payload pointers after a compaction moved
// heap payloads. Called from gc_compact's tail. Leaf; clobbers A, Y.
// -----------------------------------------------------------------------------
wm_gc_rederef:
    lda WM_FLAGS
    lsr
    bcc _wgr_done
    // wm_map_base = wm_map_h->H_PTR + O_HEADER
    lda wm_map_h
    sta WM_SCR_PTR                   // borrow as scratch ptr
    lda wm_map_h+1
    sta WM_SCR_PTR+1
    ldy #H_PTR
    lda (WM_SCR_PTR),y
    clc
    adc #O_HEADER
    sta wm_map_base
    iny
    lda (WM_SCR_PTR),y
    adc #0
    sta wm_map_base+1
    // wm_buf = wm_curbuf_h->H_PTR + O_HEADER
    lda wm_curbuf_h
    sta WM_SCR_PTR
    lda wm_curbuf_h+1
    sta WM_SCR_PTR+1
    ldy #H_PTR
    lda (WM_SCR_PTR),y
    clc
    adc #O_HEADER
    sta wm_buf
    iny
    lda (WM_SCR_PTR),y
    adc #0
    sta wm_buf+1
_wgr_done:
    rts

// -----------------------------------------------------------------------------
// wm_mkwin — build a window dict from the wmk_* parameter block.
//   in:  wmk_x/y/w/h (outer rect), wmk_title (STR handle or 0; must be rooted
//        by the caller if nonzero), wmk_inherit.
//   out: RV = window dict.
// V4' routine.
// -----------------------------------------------------------------------------
wm_mkwin:
    preamble_args(0, 0)

    jsr dict_alloc
    rs_push(RV)                      // RS: [win]

    // Int fields. rs_peek refreshes W0 after each set (handles are stable,
    // but wm_dset_int_x ends inside dict_set whose postamble restores our W0
    // anyway — peek is belt and braces).
    rs_peek(W0)
    lda wmk_x
    ldx #WMK_X
    jsr wm_dset_int_x
    rs_peek(W0)
    lda wmk_y
    ldx #WMK_Y
    jsr wm_dset_int_x
    rs_peek(W0)
    lda wmk_w
    ldx #WMK_W
    jsr wm_dset_int_x
    rs_peek(W0)
    lda wmk_h
    ldx #WMK_H
    jsr wm_dset_int_x
    rs_peek(W0)
    lda #0
    ldx #WMK_R
    jsr wm_dset_int_x
    rs_peek(W0)
    lda #0
    ldx #WMK_C
    jsr wm_dset_int_x

    // Title (bordered) before BUF so wm_interior sees it.
    lda wmk_title
    ora wmk_title+1
    beq _wmk_no_title
    rs_peek(W0)
    lda wmk_title
    sta W1
    lda wmk_title+1
    sta W1+1
    ldx #WMK_T
    jsr wm_dset_h
_wmk_no_title:

    // Interior geometry → wm_i*.
    rs_peek(W0)
    jsr wm_interior

    // BUF = STR of iw*ih cells.
    lda #0
    sta ALLOC_SIZE
    sta ALLOC_SIZE+1
    ldx wm_ih
    beq _wmk_size_done
_wmk_size_loop:
    clc
    lda ALLOC_SIZE
    adc wm_iw
    sta ALLOC_SIZE
    bcc !+
    inc ALLOC_SIZE+1
!:
    dex
    bne _wmk_size_loop
_wmk_size_done:
    jsr str_alloc                    // RV = buf (may GC; win rooted on RS)
    rs_push(RV)                      // RS: [win, buf]

    // Fill the buffer: inherit the screen cells under the interior, or $20.
    // (wm_interior's wm_i* statics survive — str_alloc doesn't touch them.)
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    jsr deref_W0_to_W2               // W2 = buf payload
    ldx #0                           // X = interior row
_wmk_fill_row:
    cpx wm_ih
    bcs _wmk_fill_done
    lda wmk_inherit
    beq _wmk_fill_blank
    // W3 = $0400 + (iy+row)*40 + ix   (source row on screen)
    txa
    pha
    clc
    adc wm_iy
    tay
    lda screen_row_lo,y
    clc
    adc wm_ix
    sta W3
    lda screen_row_hi,y
    adc #0
    sta W3+1
    pla
    tax
    ldy #0
_wmk_copy_cell:
    cpy wm_iw
    bcs _wmk_row_done
    lda (W3),y
    sta (W2),y
    iny
    jmp _wmk_copy_cell
_wmk_fill_blank:
    lda #$20
    ldy #0
_wmk_blank_cell:
    cpy wm_iw
    bcs _wmk_row_done
    sta (W2),y
    iny
    jmp _wmk_blank_cell
_wmk_row_done:
    // W2 += iw
    clc
    lda W2
    adc wm_iw
    sta W2
    bcc !+
    inc W2+1
!:
    inx
    jmp _wmk_fill_row
_wmk_fill_done:

    // win["BUF"] = buf   (RS: [win, buf])
    rs_peek_at(W0, 1)
    rs_peek_at(W1, 0)
    ldx #WMK_BUF
    jsr wm_dset_h
    rs_pop(W0)                       // drop buf; RS: [win]
    jmp postamble_pop_rv             // RV = win

// -----------------------------------------------------------------------------
// wm_use — make the window in W0 the current output target.
//   in:  W0 = window dict handle (must contain BUF).
//   out: RV = previous current window (or NONE before wm_start).
// V4' routine.
// -----------------------------------------------------------------------------
wm_use:
    preamble_args(0, 0)
    rs_push(W0)                      // RS: [new]

    // Write the cursor back into the outgoing window.
    lda wm_cur_h
    ora wm_cur_h+1
    beq _wu_no_writeback
    lda wm_cur_h
    sta W0
    lda wm_cur_h+1
    sta W0+1
    lda SCREEN_ROW
    ldx #WMK_R
    jsr wm_dset_int_x
    lda wm_cur_h
    sta W0
    lda wm_cur_h+1
    sta W0+1
    lda SCREEN_COL
    ldx #WMK_C
    jsr wm_dset_int_x
_wu_no_writeback:

    // RV (return) = old current — park it on RS across the loads below.
    lda wm_cur_h
    sta W0
    lda wm_cur_h+1
    sta W0+1
    ora W0
    bne !+
    lda #<NONE
    sta W0
    lda #>NONE
    sta W0+1
!:
    rs_push(W0)                      // RS: [new, old]

    // Current = new.
    rs_peek_at(W0, 1)
    lda W0
    sta wm_cur_h
    lda W0+1
    sta wm_cur_h+1

    // wm_idx = index of new in WINDOWS (linear scan).
    jsr wm_find_idx                  // A = index (W0 = window); panics if absent
    sta wm_idx

    // Geometry + buffer.
    rs_peek_at(W0, 1)
    jsr wm_interior
    lda wm_ix
    sta wm_x0
    lda wm_iy
    sta wm_y0
    lda wm_iw
    sta wm_w
    lda wm_ih
    sta wm_h
    rs_peek_at(W0, 1)
    ldx #WMK_BUF
    jsr wm_dget_x                    // RV = buf handle
    lda RV
    sta wm_curbuf_h
    sta W0
    lda RV+1
    sta wm_curbuf_h+1
    sta W0+1
    jsr deref_W0_to_W2
    lda W2
    sta wm_buf
    lda W2+1
    sta wm_buf+1

    // Cursor.
    rs_peek_at(W0, 1)
    ldx #WMK_R
    jsr wm_dget_byte_x
    sta SCREEN_ROW
    rs_peek_at(W0, 1)
    ldx #WMK_C
    jsr wm_dget_byte_x
    sta SCREEN_COL

    jmp postamble_pop_rv             // RV = old; postamble drops [new]

// -----------------------------------------------------------------------------
// wm_find_idx — A = z-index of the window in W0 within WINDOWS.
// Panics ERR_TYPE if not found. Plain subroutine (calls V4' list ops).
//   in: W0 = window dict.  clobbers: A,X,Y,W1-W3 (via list_get); W0 preserved.
// -----------------------------------------------------------------------------
wm_find_idx:
    lda #0
    sta wm_t2                        // index
_wfi_loop:
    lda wm_windows
    sta W1
    lda wm_windows+1
    sta W1+1
    rs_push(W1)
    jsr list_len                     // A = count (consumes arg)
    cmp wm_t2
    beq _wfi_missing
    // RV = WINDOWS[wm_t2]
    lda wm_windows
    sta W1
    lda wm_windows+1
    sta W1+1
    rs_push(W1)
    lda wm_t2
    sta W2
    lda #0
    sta W2+1
    fs_push(W2)
    jsr list_get                     // RV = element
    lda RV
    cmp W0
    bne _wfi_next
    lda RV+1
    cmp W0+1
    bne _wfi_next
    lda wm_t2
    rts
_wfi_next:
    inc wm_t2
    jmp _wfi_loop
_wfi_missing:
    jmp panic_type

// -----------------------------------------------------------------------------
// wm_refresh — rebuild MAP from the z-order and repaint the whole screen.
// V4' routine.
// -----------------------------------------------------------------------------
wm_refresh:
    preamble_args(0, 0)

    // --- Phase A: MAP. Index 0 (ROOT, fullscreen) → zero fill, then
    // rect-fill each window 1..n-1 with its index.
    jsr wm_map_zero

    // --- rect-fill windows 1.. with their index ---
    lda #1
    sta wm_t2                        // z-index walker
_wrf_rect_loop:
    lda wm_windows
    sta W1
    lda wm_windows+1
    sta W1+1
    rs_push(W1)
    jsr list_len
    cmp wm_t2
    beq _wrf_blit_all
    bcc _wrf_blit_all
    // RV = WINDOWS[i]
    lda wm_windows
    sta W1
    lda wm_windows+1
    sta W1+1
    rs_push(W1)
    lda wm_t2
    sta W2
    lda #0
    sta W2+1
    fs_push(W2)
    jsr list_get
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    // outer rect
    ldx #WMK_X
    jsr wm_dget_byte_x
    sta wm_t0                        // x
    ldx #WMK_Y
    jsr wm_dget_byte_x
    sta wm_t1                        // y
    ldx #WMK_W
    jsr wm_dget_byte_x
    sta wm_t3                        // w
    ldx #WMK_H
    jsr wm_dget_byte_x
    tax                              // X = h countdown
_wrf_rect_row:
    beq _wrf_rect_done
    txa
    pha
    lda wm_t1
    jsr wm_row40                     // MAP row base for absolute row
    // fill [x .. x+w) with index. Loop shape avoids the unsigned-underflow
    // trap at x=0: store first, then test for the left edge.
    lda wm_t0
    clc
    adc wm_t3
    tay                              // Y = x+w (end, exclusive; <= 40)
_wrf_rect_cell:
    dey
    lda wm_t2
    sta (WM_MAP_PTR),y
    cpy wm_t0
    bne _wrf_rect_cell
_wrf_rect_row_done:
    inc wm_t1
    pla
    tax
    dex
    jmp _wrf_rect_row
_wrf_rect_done:
    inc wm_t2
    jmp _wrf_rect_loop

    // --- Phase B: repaint every window bottom-up. ---
_wrf_blit_all:
    lda #0
    sta wm_t2
_wrf_blit_loop:
    lda wm_windows
    sta W1
    lda wm_windows+1
    sta W1+1
    rs_push(W1)
    jsr list_len
    cmp wm_t2
    beq _wrf_done
    bcc _wrf_done
    lda wm_windows
    sta W1
    lda wm_windows+1
    sta W1+1
    rs_push(W1)
    lda wm_t2
    sta W2
    lda #0
    sta W2+1
    fs_push(W2)
    jsr list_get
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    lda wm_t2
    jsr wm_blit_one                  // draw window W0 (owned cells only)
    inc wm_t2
    jmp _wrf_blit_loop
_wrf_done:
    jmp postamble

// -----------------------------------------------------------------------------
// wm_blit_one — repaint window W0 (z-index in A): border (if any) + interior
// cells the window owns per MAP.
//   in: W0 = window dict, A = its z-index. Plain subroutine (V4' sub-calls).
// -----------------------------------------------------------------------------
wm_blit_one:
    sta wm_t3                        // z-index
    jsr wm_interior                  // wm_i*; C = bordered
    bcc _wb_interior
    jsr wm_border                    // draw frame + title (W0 preserved)
_wb_interior:
    // BUF payload → W3.
    ldx #WMK_BUF
    jsr wm_dget_x
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    jsr deref_W0_to_W2
    lda W2
    sta W3
    lda W2+1
    sta W3+1

    ldx #0                           // interior row
_wb_row:
    cpx wm_ih
    bcs _wb_done
    txa
    pha
    clc
    adc wm_iy
    jsr wm_row40                     // WM_SCR_PTR/WM_MAP_PTR for abs row
    // copy owned cells: screen[x0+y] = buf[y] where MAP[x0+y] == index
    ldy wm_iw
_wb_cell:
    dey
    bmi _wb_row_next
    // map check at column wm_ix + y
    tya
    clc
    adc wm_ix
    tax                              // X = absolute column — but (ptr),x no...
    // use Y for indexing instead: swap roles
    stx wm_t0
    ldx #0                           // (X scratch)
    sty wm_t1                        // save interior column
    ldy wm_t0
    lda (WM_MAP_PTR),y
    cmp wm_t3
    bne _wb_cell_skip
    // fetch buf cell (interior column) → screen (absolute column)
    sty wm_t0
    ldy wm_t1
    lda (W3),y
    ldy wm_t0
    sta (WM_SCR_PTR),y
_wb_cell_skip:
    ldy wm_t1
    jmp _wb_cell
_wb_row_next:
    // W3 += iw
    clc
    lda W3
    adc wm_iw
    sta W3
    bcc !+
    inc W3+1
!:
    pla
    tax
    inx
    jmp _wb_row
_wb_done:
    rts

// -----------------------------------------------------------------------------
// wm_border — draw the frame + title of the bordered window in W0 into the
// screen (owned cells only). wm_i* hold the INTERIOR rect; the frame is one
// cell outside it. Screen codes: corners $70/$6E/$6D/$7D, horiz $40, vert $5D.
//   in: W0 = window dict (bordered), wm_t3 = z-index. W0 preserved.
// -----------------------------------------------------------------------------
wm_border:
    // top row (iy-1): corner, W-2 horiz, corner — with title text overlaid
    ldx wm_iy
    dex
    txa
    jsr wm_row40
    ldy wm_ix
    dey                              // Y = left corner column
    lda (WM_MAP_PTR),y
    cmp wm_t3
    bne !+
    lda #$70
    sta (WM_SCR_PTR),y
!:
    // horizontal run
    ldy wm_ix
_wbr_top:
    tya
    sec
    sbc wm_ix
    cmp wm_iw
    bcs _wbr_top_done
    lda (WM_MAP_PTR),y
    cmp wm_t3
    bne !+
    lda #$40
    sta (WM_SCR_PTR),y
!:
    iny
    jmp _wbr_top
_wbr_top_done:
    lda (WM_MAP_PTR),y
    cmp wm_t3
    bne !+
    lda #$6E
    sta (WM_SCR_PTR),y
!:
    // title text over the top-left run
    ldx #WMK_T
    jsr wm_dget_x                    // RV = title STR
    lda RV
    sta W1
    lda RV+1
    sta W1+1
    // W2 = payload, A:X = len via manual deref (leaf, no W0 clobber)
    ldy #H_PTR
    lda (W1),y
    sta W2
    iny
    lda (W1),y
    sta W2+1
    ldy #0
    lda (W2),y                       // O_LEN low
    sta wm_t0                        // title length (cap below)
    // payload starts at +O_HEADER
    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:
    // cap length to iw
    lda wm_t0
    cmp wm_iw
    bcc !+
    lda wm_iw
    sta wm_t0
!:
    // draw chars at columns ix..ix+len-1 of row iy-1 (ptrs still valid)
    ldy #0
_wbr_title:
    cpy wm_t0
    bcs _wbr_title_done
    sty wm_t4                        // title index (petscii_to_screen_code
    lda (W2),y                       //  clobbers Y)
    jsr petscii_to_screen_code
    sta wm_t1
    lda wm_t4
    clc
    adc wm_ix
    tay
    lda (WM_MAP_PTR),y
    cmp wm_t3
    bne !+
    lda wm_t1
    sta (WM_SCR_PTR),y
!:
    ldy wm_t4
    iny
    jmp _wbr_title
_wbr_title_done:

    // bottom row (iy+ih): corner, horiz, corner
    lda wm_iy
    clc
    adc wm_ih
    jsr wm_row40
    ldy wm_ix
    dey
    lda (WM_MAP_PTR),y
    cmp wm_t3
    bne !+
    lda #$6D
    sta (WM_SCR_PTR),y
!:
    ldy wm_ix
_wbr_bot:
    tya
    sec
    sbc wm_ix
    cmp wm_iw
    bcs _wbr_bot_done
    lda (WM_MAP_PTR),y
    cmp wm_t3
    bne !+
    lda #$40
    sta (WM_SCR_PTR),y
!:
    iny
    jmp _wbr_bot
_wbr_bot_done:
    lda (WM_MAP_PTR),y
    cmp wm_t3
    bne !+
    lda #$7D
    sta (WM_SCR_PTR),y
!:

    // side columns: rows iy .. iy+ih-1, columns ix-1 and ix+iw
    ldx #0
_wbr_side_row:
    cpx wm_ih
    bcs _wbr_sides_done
    txa
    pha
    clc
    adc wm_iy
    jsr wm_row40
    ldy wm_ix
    dey
    lda (WM_MAP_PTR),y
    cmp wm_t3
    bne !+
    lda #$5D
    sta (WM_SCR_PTR),y
!:
    lda wm_ix
    clc
    adc wm_iw
    tay
    lda (WM_MAP_PTR),y
    cmp wm_t3
    bne !+
    lda #$5D
    sta (WM_SCR_PTR),y
!:
    pla
    tax
    inx
    jmp _wbr_side_row
_wbr_sides_done:
    rts

// -----------------------------------------------------------------------------
// wm_start — first WINDOW() call: allocate MAP, build the fullscreen ROOT
// (inheriting the live screen), bind the global name ROOT, flip WM on.
// V4' routine.
// -----------------------------------------------------------------------------
wm_start:
    preamble_args(0, 0)

    // MAP: 1000-byte STR, zero-filled (index 0 = ROOT owns everything).
    lda #<1000
    sta ALLOC_SIZE
    lda #>1000
    sta ALLOC_SIZE+1
    jsr str_alloc
    lda RV
    sta wm_map_h
    sta W0
    lda RV+1
    sta wm_map_h+1
    sta W0+1
    jsr deref_W0_to_W2
    lda W2
    sta wm_map_base
    lda W2+1
    sta wm_map_base+1
    jsr wm_map_zero

    // WINDOWS = []
    lda #0
    jsr list_alloc
    lda RV
    sta wm_windows
    lda RV+1
    sta wm_windows+1

    // ROOT = fullscreen, borderless, inherits the screen.
    lda #0
    sta wmk_x
    sta wmk_y
    sta wmk_title
    sta wmk_title+1
    lda #SCREEN_COLS
    sta wmk_w
    lda #SCREEN_ROWS
    sta wmk_h
    lda #1
    sta wmk_inherit
    jsr wm_mkwin                     // RV = root
    lda RV
    sta wm_root_h
    lda RV+1
    sta wm_root_h+1
    // append to WINDOWS
    lda wm_windows
    sta W1
    lda wm_windows+1
    sta W1+1
    rs_push(W1)
    rs_push(RV)
    jsr list_append

    // Bind global ROOT.
    lda ROOT_SCOPE
    sta W1
    lda ROOT_SCOPE+1
    sta W1+1
    rs_push(W1)
    lda #<WM_STR_ROOT
    sta W1
    lda #>WM_STR_ROOT
    sta W1+1
    rs_push(W1)
    lda wm_root_h
    sta W1
    lda wm_root_h+1
    sta W1+1
    rs_push(W1)
    jsr dict_set

    // WM on, then make ROOT current (wm_use needs the flag for nothing, but
    // the write-through path needs map_base valid — it is).
    lda WM_FLAGS
    ora #1
    sta WM_FLAGS
    lda wm_root_h
    sta W0
    lda wm_root_h+1
    sta W0+1
    jsr wm_use

    jmp postamble

// -----------------------------------------------------------------------------
// wm_blit_window — repaint the CURRENT window (buffer → screen, owned cells).
// Called from screen_scroll_up after the buffer moved. V4'-wrapped so the
// print/put_char callers' W/B file survives (RV is clobbered — volatile by
// convention).
// -----------------------------------------------------------------------------
wm_blit_window:
    preamble_args(0, 0)
    lda wm_cur_h
    sta W0
    lda wm_cur_h+1
    sta W0+1
    ora W0
    beq !+
    lda wm_idx
    jsr wm_blit_one
!:
    jmp postamble

// -----------------------------------------------------------------------------
// wm_screen_lock / wm_screen_unlock — the EDIT plugin's whole-screen mode
// (SYS_SCREEN_LOCK / SYS_SCREEN_UNLOCK slots). While locked, write-through
// and windowed row math are suppressed (screen.asm treats the target as the
// raw screen). Unlock repaints the desktop.
// -----------------------------------------------------------------------------
wm_screen_lock:
    lda WM_FLAGS
    ora #2
    sta WM_FLAGS
    rts

wm_screen_unlock:
    lda WM_FLAGS
    and #$FF-2
    sta WM_FLAGS
    lsr                              // bit0 → C: WM live?
    bcc !+
    jsr wm_refresh                   // repaint windows over EDIT's leavings
!:
    rts

// -----------------------------------------------------------------------------
// wm_panic_reset — error_handler hook: clear the screen lock and make ROOT
// the output target so the panic message is visible. No-op while WM is off.
// -----------------------------------------------------------------------------
wm_panic_reset:
    lda WM_FLAGS
    and #$FF-2                       // drop a stale EDIT lock
    sta WM_FLAGS
    lsr
    bcc !+
    lda wm_root_h
    sta W0
    lda wm_root_h+1
    sta W0+1
    jsr wm_use
    jmp wm_refresh
!:
    rts

// =============================================================================
// Builtins.
// =============================================================================

// --- WINDOW(X, Y, W, H [, TITLE]) → window dict ------------------------------
builtin_window:
    preamble_call(4, 5)

    jsr _bw_read_args                // fill wmk_* from the args tuple

    // Bounds: X+W <= 40, Y+H <= 25; bordered needs W>=3, H>=3 else W,H >= 1.
    lda wmk_w
    beq _bw_bad
    lda wmk_h
    beq _bw_bad
    lda wmk_title
    ora wmk_title+1
    beq _bw_min_ok
    lda wmk_w
    cmp #3
    bcc _bw_bad
    lda wmk_h
    cmp #3
    bcc _bw_bad
_bw_min_ok:
    clc
    lda wmk_x
    adc wmk_w
    cmp #SCREEN_COLS+1
    bcs _bw_bad
    clc
    lda wmk_y
    adc wmk_h
    cmp #SCREEN_ROWS+1
    bcs _bw_bad
    jmp _bw_geom_ok
_bw_bad:
    jmp panic_type
_bw_geom_ok:

    // Lazy start. wm_start builds ROOT through the same wmk_* parameter
    // block, so the caller's args must be re-read afterwards.
    lda WM_FLAGS
    lsr
    bcs _bw_started
    jsr wm_start
    jsr _bw_read_args
_bw_started:

    // Titled windows clear their interior; borderless inherit the screen.
    lda #1
    ldx wmk_title
    bne _bw_inh
    ldx wmk_title+1
    bne _bw_inh
    jmp _bw_set_inh
_bw_inh:
    lda #0
_bw_set_inh:
    sta wmk_inherit

    jsr wm_mkwin                     // RV = win
    rs_push(RV)                      // RS: [args, win]

    // append + make current + repaint
    lda wm_windows
    sta W1
    lda wm_windows+1
    sta W1+1
    rs_push(W1)
    rs_peek_at(W0, 1)
    rs_push(W0)
    jsr list_append

    rs_peek(W0)
    jsr wm_use
    jsr wm_refresh

    jmp postamble_pop_rv             // RV = win

// wm_args_rederef — refresh W3 (args-tuple payload) from the RS root after
// any allocating call may have compacted the heap (the GC re-deref rule).
wm_args_rederef:
    rs_peek(W0)
    jsr deref_W0_to_W2
    lda W2
    sta W3
    lda W2+1
    sta W3+1
    rts

// _bw_read_args — fill wmk_x/y/w/h + wmk_title from the args tuple.
_bw_read_args:
    jsr wm_args_rederef
    jsr _bw_arg_byte_0
    sta wmk_x
    ldy #1
    jsr _bw_arg_byte
    sta wmk_y
    ldy #2
    jsr _bw_arg_byte
    sta wmk_w
    ldy #3
    jsr _bw_arg_byte
    sta wmk_h
    lda #0
    sta wmk_title
    sta wmk_title+1
    lda B7
    cmp #5
    bne _bra_no_title
    arg_get(4, W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq !+
    jmp panic_type
!:
    lda W0
    sta wmk_title
    lda W0+1
    sta wmk_title+1
_bra_no_title:
    rts

// arg helpers: A = int byte0 of arg Y (0-based index); panics on non-int.
_bw_arg_byte_0:
    ldy #0
_bw_arg_byte:
    tya
    asl
    tay
    jsr arg_get_w0                   // expects Y = 2*index
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq !+
    jmp panic_type
!:
    ldy #0
    lda (W0),y
    rts

// --- USE(P) → previous window ------------------------------------------------
builtin_use:
    jsr preamble_call_1_1_w0
    jsr _wm_require_window
    jsr wm_use
    jmp postamble                    // RV set by wm_use

// --- CLOSE(P) → NONE ---------------------------------------------------------
builtin_close:
    jsr preamble_call_1_1_w0
    jsr _wm_require_window

    // ROOT is immortal.
    lda W0
    cmp wm_root_h
    bne !+
    lda W0+1
    cmp wm_root_h+1
    bne !+
    jmp panic_type
!:
    jsr wm_find_idx                  // A = index (panics if absent)
    pha

    // Was it current? Then fall back to ROOT first.
    lda W0
    cmp wm_cur_h
    bne _bc_not_cur
    lda W0+1
    cmp wm_cur_h+1
    bne _bc_not_cur
    fs_push(W0)
    lda wm_root_h
    sta W0
    lda wm_root_h+1
    sta W0+1
    jsr wm_use
    fs_pop(W0)
_bc_not_cur:

    // WINDOWS.del(index)
    lda wm_windows
    sta W1
    lda wm_windows+1
    sta W1+1
    rs_push(W1)
    pla
    sta W2
    lda #0
    sta W2+1
    fs_push(W2)
    jsr list_del

    // wm_idx of the current window may have shifted — re-resolve.
    lda wm_cur_h
    sta W0
    lda wm_cur_h+1
    sta W0+1
    jsr wm_find_idx
    sta wm_idx

    jsr wm_refresh
    jmp postamble_return_none

// --- AT(P, X, Y) → NONE ------------------------------------------------------
builtin_at:
    preamble_call(3, 3)
    arg_get(0, W0)
    jsr _wm_require_window
    // Type-check the coordinate args up front.
    arg_get(1, W1)
    ldy #H_TYPE
    lda (W1),y
    cmp #TYPE_INT
    beq !+
    jmp panic_type
!:
    arg_get(2, W1)
    ldy #H_TYPE
    lda (W1),y
    cmp #TYPE_INT
    beq !+
    jmp panic_type
!:
    // P["C"] = col (arg1). NOTE: wm_dset_int_x owns wm_t0/wm_t1, so args are
    // re-read from the tuple around every set (V4' restores W3 for arg_get).
    arg_get(1, W1)
    ldy #0
    lda (W1),y
    ldx #WMK_C
    jsr wm_dset_int_x
    jsr wm_args_rederef
    arg_get(0, W0)
    arg_get(2, W1)
    ldy #0
    lda (W1),y
    ldx #WMK_R
    jsr wm_dset_int_x
    jsr wm_args_rederef

    // If P is current, mirror into the live cursor.
    arg_get(0, W0)
    lda W0
    cmp wm_cur_h
    bne _ba_done
    lda W0+1
    cmp wm_cur_h+1
    bne _ba_done
    arg_get(1, W1)
    ldy #0
    lda (W1),y
    sta SCREEN_COL
    arg_get(2, W1)
    ldy #0
    lda (W1),y
    sta SCREEN_ROW
_ba_done:
    jmp postamble_return_none

// --- ATTR(P, X, Y, W, F) → NONE ----------------------------------------------
// Modify W cells of P's interior row Y starting at column X:
//   F = 1 → reverse on (set bit 7), F = 2 → reverse off (clear bit 7).
// Buffer cells are changed and mirrored to the screen where P owns the cell.
// (No allocs anywhere below, so the args tuple stays put.)
builtin_attr:
    preamble_call(5, 5)
    arg_get(0, W0)
    jsr _wm_require_window

    // ints: col, row, width, flags
    ldy #1
    jsr _bw_arg_byte
    sta wm_t0                        // col
    ldy #2
    jsr _bw_arg_byte
    sta wm_t1                        // row
    ldy #3
    jsr _bw_arg_byte
    sta wm_t4                        // width
    ldy #4
    jsr _bw_arg_byte
    sta wm_attr_f

    arg_get(0, W0)
    jsr wm_interior                  // wm_i* for P
    // bounds: row < ih, width in [1, iw], col < iw, col+width <= iw.
    // The col/width caps also rule out 8-bit wrap in the sum (39+40 < 256).
    lda wm_t4
    beq _batr_bad
    lda wm_t1
    cmp wm_ih
    bcs _batr_bad
    lda wm_t0
    cmp wm_iw
    bcs _batr_bad
    lda wm_t4
    cmp wm_iw
    bcc !+
    beq !+
    jmp _batr_bad
!:
    clc
    lda wm_t0
    adc wm_t4
    cmp wm_iw
    bcc !+
    beq !+
_batr_bad:
    jmp panic_type
!:

    arg_get(0, W0)
    jsr wm_find_idx
    sta wm_attr_z

    // W3 = BUF payload + row*iw
    arg_get(0, W0)
    ldx #WMK_BUF
    jsr wm_dget_x
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    jsr deref_W0_to_W2
    lda W2
    sta W3
    lda W2+1
    sta W3+1
    ldx wm_t1
    beq _batr_rowed
_batr_rowmul:
    clc
    lda W3
    adc wm_iw
    sta W3
    bcc !+
    inc W3+1
!:
    dex
    bne _batr_rowmul
_batr_rowed:

    // screen/map row ptrs for absolute row iy+row
    lda wm_iy
    clc
    adc wm_t1
    jsr wm_row40

    // loop k = 0..width-1
    ldx #0
_batr_loop:
    cpx wm_t4
    bcs _batr_done
    txa
    clc
    adc wm_t0
    tay                              // Y = interior column
    lda (W3),y
    pha
    lda wm_attr_f
    cmp #2
    beq _batr_off
    pla
    ora #$80
    jmp _batr_store
_batr_off:
    pla
    and #$7F
_batr_store:
    sta (W3),y
    sta wm_t2                        // cell value for the mirror
    // mirror: absolute column = ix + interior column
    tya
    clc
    adc wm_ix
    tay
    lda (WM_MAP_PTR),y
    cmp wm_attr_z
    bne _batr_next
    lda wm_t2
    sta (WM_SCR_PTR),y
_batr_next:
    inx
    jmp _batr_loop
_batr_done:
    jmp postamble_return_none

// --- REFRESH() → NONE --------------------------------------------------------
builtin_refresh:
    preamble_call(0, 0)
    lda WM_FLAGS
    lsr
    bcc !+
    jsr wm_refresh
!:
    jmp postamble_return_none

// _wm_require_window — panic unless W0 is a dict and WM is on.
_wm_require_window:
    lda WM_FLAGS
    lsr
    bcc _wrw_bad
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_DICT
    bne _wrw_bad
    rts
_wrw_bad:
    jmp panic_type
