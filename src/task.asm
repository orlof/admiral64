// -----------------------------------------------------------------------------
// task.asm — preemptive multitasking core: context switch + N-task lifecycle.
//
// PLANS/multitasking.md, milestone B. A task is an interpreter execution
// context. Per-task (swapped on a switch): the software stacks FS/RS, the
// zero-page register file ($02-$1F, $31-$47 — FSP/RSP/FP, RV/RV2, W0-W3/
// B0-B7, LEX_*, SCREEN_ROW/COL, CURRENT_SCOPE/ROOT_SCOPE, METHOD_RECEIVER),
// and the 6510 hardware stack (page $01), copy-swapped through a per-task
// buffer. SHARED (never swapped): the heap allocator + GC ($20-$30, $48),
// WM_FLAGS, STOP_REQUESTED — one heap, one screen. Scopes are per-task.
//
// Scheduling: cooperative via YIELD(), plus preemption — the jiffy IRQ sets
// TASK_SWITCH_PENDING and parser_stmt switches at the next statement boundary
// (GC-safe: live state is on FS/RS there, transient ZP is idle).
//
// Memory: task 0 uses FS/RS $9000-$9800. Tasks 1..N-1 and all switch metadata
// live in the $C000-$CFFF always-RAM gap (free in every fixture; below BASIC
// ROM $A000-$BFFF and KERNAL $E000+). Heap starts at $9800.
//   $C000-$C3FF  hwbuf[0..3]   (256 B each; index = stack address)
//   $C400-$C4FF  zpsave[0..3]  (64 B each; 53 used)
//   $C500-$C700  task 1 FS/RS  (256 B each)
//   $C700-$C900  task 2 FS/RS
//   $C900-$CB00  task 3 FS/RS
//   $CB00-$CB50  indent-state save[0..3]  (17 B each; lexer indent stack)
//   $CB50-$CC70  line-editor save[0..3]   (72 B each; repl_line_buf + scalars)
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

.const MAX_TASKS = 4

// ZP save block: two ranges, $02-$1F (30 B) then $31-$47 (23 B) = 53 B.
.const ZPS_R1_LO = $02
.const ZPS_R1_HI = $20               // exclusive
.const ZPS_R2_LO = $31
.const ZPS_R2_HI = $48               // exclusive
.const ZPS_N     = (ZPS_R1_HI - ZPS_R1_LO) + (ZPS_R2_HI - ZPS_R2_LO)   // 53

// Per-task scalars.
ts_cur:      .byte 0
ts_target:   .byte 0
ts_sp_tmp:   .byte 0
_bsp_slot:   .byte 0
_tgma_i:     .byte 0
t_state:     .fill MAX_TASKS, 0      // 0 = free, 1 = active
t_hwsp:      .fill MAX_TASKS, 0
t_func_lo:   .fill MAX_TASKS, 0
t_func_hi:   .fill MAX_TASKS, 0

// Address tables (indexed by task).
t_hwbuf_hi:   .byte $C0, $C1, $C2, $C3           // hwbuf page (lo = $00)
t_zpsave_lo:  .byte $00, $40, $80, $C0
t_zpsave_hi:  .byte $C4, $C4, $C4, $C4
t_fs_end_lo:  .byte <$9400, <$C600, <$C800, <$CA00
t_fs_end_hi:  .byte >$9400, >$C600, >$C800, >$CA00
t_rs_end_lo:  .byte <$9800, <$C700, <$C900, <$CB00
t_rs_end_hi:  .byte >$9800, >$C700, >$C900, >$CB00
// per-task save of the lexer's static indent state (indent_stack 16 +
// indent_depth 1 = 17 B, contiguous at `indent_stack`). 20 B/slot.
t_indent_lo:  .byte <$CB00, <$CB14, <$CB28, <$CB3C
t_indent_hi:  .byte >$CB00, >$CB14, >$CB28, >$CB3C
// per-task save of the line editor: repl_line_buf (64 B, at $033C) followed
// by the 7-byte scalar block (repl_ledit_scalars). 72 B/slot at $CB50..$CC6F.
// Restored so two shells editing lines concurrently don't share one buffer.
.const T_LEDIT_BUF_N = 64
.const T_LEDIT_SCAL_N = 7        // = REPL_LEDIT_N (repl.asm); kept in sync
t_ledit_lo:   .byte <$CB50, <$CB98, <$CBE0, <$CC28
t_ledit_hi:   .byte >$CB50, >$CB98, >$CBE0, >$CC28
// per-task saved current-window handle (wm_cur_h). buf/geometry are re-derived
// from the handle on restore (a GC-moved buffer is handled), so only the
// handle is saved. 0 = fullscreen (no window).
t_wmcur_lo:   .fill MAX_TASKS, 0
t_wmcur_hi:   .fill MAX_TASKS, 0

// Preemption flag: set by the IRQ, checked (and cleared) at parser_stmt.
TASK_SWITCH_PENDING: .byte 0

// Keyboard focus: the task index whose kbd_getchar/GETC may read keys. Other
// tasks' input waits (yields) until focused. Cycled by the C= (Commodore)
// key via the IRQ. CBM_LAST latches the key level for edge detection.
TASK_FOCUS: .byte 0
CBM_LAST:   .byte 0
WM_REFRESH_PENDING: .byte 0          // focus changed -> repaint colors

// -----------------------------------------------------------------------------
// task_init — boot: task 0 = the running REPL; others free.
// -----------------------------------------------------------------------------
task_init:
    lda #0
    sta ts_cur
    sta TASK_SWITCH_PENDING
    sta TASK_FOCUS
    sta CBM_LAST
    sta WM_REFRESH_PENDING
    ldx #MAX_TASKS-1
    lda #0
_ti_clear:
    sta t_state,x
    dex
    bpl _ti_clear
    lda #1
    sta t_state+0
    rts

// -----------------------------------------------------------------------------
// task_focus_next — advance keyboard focus to the next active task (wraps).
// Byte-only, IRQ-safe. Leaf.
// -----------------------------------------------------------------------------
task_focus_next:
    ldx TASK_FOCUS
    ldy #MAX_TASKS
_tfn_loop:
    inx
    cpx #MAX_TASKS
    bcc !+
    ldx #0
!:
    lda t_state,x
    bne _tfn_done
    dey
    bne _tfn_loop
    ldx TASK_FOCUS                   // no other active task
_tfn_done:
    stx TASK_FOCUS
    rts

// -----------------------------------------------------------------------------
// ts_pick_next — X = next active task after ts_cur (round-robin), or ts_cur if
// no other task is active. Leaf.
// -----------------------------------------------------------------------------
ts_pick_next:
    ldx ts_cur
    ldy #MAX_TASKS
_tpn_loop:
    inx
    cpx #MAX_TASKS
    bcc !+
    ldx #0
!:
    lda t_state,x
    bne _tpn_done
    dey
    bne _tpn_loop
    ldx ts_cur                       // nobody else active
_tpn_done:
    rts

// -----------------------------------------------------------------------------
// ts_save_cur_zp / ts_load_target_zp — copy the 53-byte ZP register file to/
// from a task's save block. Run before the critical section (jsr-clean). Save
// uses a $08/$09 pointer; load uses $4C/$4D (outside the $02-$1F range it
// writes — WM_SCR_PTR, transient scratch).
// -----------------------------------------------------------------------------
ts_save_cur_zp:
    ldx ts_cur
    lda t_zpsave_lo,x
    sta $08
    lda t_zpsave_hi,x
    sta $09
    ldy #0
    ldx #ZPS_R1_LO
_tscz_r1:
    lda $00,x
    sta ($08),y
    inx
    iny
    cpx #ZPS_R1_HI
    bne _tscz_r1
    ldx #ZPS_R2_LO
_tscz_r2:
    lda $00,x
    sta ($08),y
    inx
    iny
    cpx #ZPS_R2_HI
    bne _tscz_r2
    // indent_stack(16)+indent_depth(1) -> t_indent[cur]
    ldx ts_cur
    lda t_indent_lo,x
    sta $08
    lda t_indent_hi,x
    sta $09
    ldy #16
_tscz_ind:
    lda indent_stack,y               // indent_depth = indent_stack+16
    sta ($08),y
    dey
    bpl _tscz_ind
    // line editor: repl_line_buf(64) + repl_ledit_scalars(7) -> t_ledit[cur]
    ldx ts_cur
    lda t_ledit_lo,x
    sta $08
    lda t_ledit_hi,x
    sta $09
    ldy #T_LEDIT_BUF_N - 1
_tscz_lbuf:
    lda repl_line_buf,y
    sta ($08),y
    dey
    bpl _tscz_lbuf
    // advance pointer past the 64-byte line buffer, then copy the 7 scalars
    lda $08
    clc
    adc #T_LEDIT_BUF_N
    sta $08
    bcc !+
    inc $09
!:
    ldy #T_LEDIT_SCAL_N - 1
_tscz_lsc:
    lda repl_ledit_scalars,y
    sta ($08),y
    dey
    bpl _tscz_lsc
    // save current-window handle
    ldx ts_cur
    lda wm_cur_h
    sta t_wmcur_lo,x
    lda wm_cur_h+1
    sta t_wmcur_hi,x
    rts

ts_load_target_zp:
    ldx ts_target
    lda t_zpsave_lo,x
    sta WM_SCR_PTR
    lda t_zpsave_hi,x
    sta WM_SCR_PTR+1
    ldy #0
    ldx #ZPS_R1_LO
_tltz_r1:
    lda (WM_SCR_PTR),y
    sta $00,x
    inx
    iny
    cpx #ZPS_R1_HI
    bne _tltz_r1
    ldx #ZPS_R2_LO
_tltz_r2:
    lda (WM_SCR_PTR),y
    sta $00,x
    inx
    iny
    cpx #ZPS_R2_HI
    bne _tltz_r2
    // t_indent[target] -> indent_stack(16)+indent_depth(1)
    ldx ts_target
    lda t_indent_lo,x
    sta WM_SCR_PTR
    lda t_indent_hi,x
    sta WM_SCR_PTR+1
    ldy #16
_tltz_ind:
    lda (WM_SCR_PTR),y
    sta indent_stack,y
    dey
    bpl _tltz_ind
    // t_ledit[target] -> repl_line_buf(64) + repl_ledit_scalars(7)
    ldx ts_target
    lda t_ledit_lo,x
    sta WM_SCR_PTR
    lda t_ledit_hi,x
    sta WM_SCR_PTR+1
    ldy #T_LEDIT_BUF_N - 1
_tltz_lbuf:
    lda (WM_SCR_PTR),y
    sta repl_line_buf,y
    dey
    bpl _tltz_lbuf
    lda WM_SCR_PTR
    clc
    adc #T_LEDIT_BUF_N
    sta WM_SCR_PTR
    bcc !+
    inc WM_SCR_PTR+1
!:
    ldy #T_LEDIT_SCAL_N - 1
_tltz_lsc:
    lda (WM_SCR_PTR),y
    sta repl_ledit_scalars,y
    dey
    bpl _tltz_lsc
    // restore current-window handle and re-derive buf/geometry from it
    ldx ts_target
    lda t_wmcur_lo,x
    sta wm_cur_h
    lda t_wmcur_hi,x
    sta wm_cur_h+1
    jmp wm_reactivate                // (rts from there)

// -----------------------------------------------------------------------------
// task_switch — round-robin to the next active task; no-op if alone. The HW-
// stack swap is a jsr/push/pull-free critical section (self-modified absolute
// addresses select the per-task buffer page).
// -----------------------------------------------------------------------------
task_switch:
    jsr ts_pick_next
    cpx ts_cur
    bne !+
    rts
!:
    stx ts_target
    jsr ts_save_cur_zp
    jsr ts_load_target_zp

    // --- critical section: no jsr / push / pull until the rts ---
    // IRQ-off: a timer IRQ mid-swap would push onto the stack we are copying.
    sei
    ldx ts_cur
    lda t_hwbuf_hi,x
    sta _tsw_sv_st+2
    tsx
    stx ts_sp_tmp
    txa
    ldy ts_cur
    sta t_hwsp,y
    ldy ts_sp_tmp
_tsw_sv:
    iny
    beq _tsw_sv_done
    lda $0100,y
_tsw_sv_st:
    sta $C000,y                      // hi byte patched to hwbuf[cur]
    jmp _tsw_sv
_tsw_sv_done:

    ldx ts_target
    lda t_hwbuf_hi,x
    sta _tsw_ld_ld+2
    lda t_hwsp,x
    sta ts_sp_tmp
    tay
_tsw_ld:
    iny
    beq _tsw_ld_done
_tsw_ld_ld:
    lda $C000,y                      // hi byte patched to hwbuf[target]
    sta $0100,y
    jmp _tsw_ld
_tsw_ld_done:

    lda ts_target
    sta ts_cur
    ldx ts_sp_tmp
    txs
    cli
    rts

// -----------------------------------------------------------------------------
// task_bootstrap — first entry of a fresh task: run its body (a callable
// TYPE_STR rooted on the task RS) via parser_exec, then exit.
// -----------------------------------------------------------------------------
task_bootstrap:
    ldx ts_cur
    lda t_func_lo,x
    sta W0
    lda t_func_hi,x
    sta W0+1
    rs_push(W0)
    jsr parser_exec
    // fall into task_exit

// -----------------------------------------------------------------------------
// task_exit — free the current task and switch to another active one. Does NOT
// save the dying task. Task 0 (the REPL) never exits.
// -----------------------------------------------------------------------------
task_exit:
    ldx ts_cur
    lda #0
    sta t_state,x
    jsr ts_pick_next                 // X = another active task (task 0 at worst)
    stx ts_target
    // If the dying task held focus, hand it to the surviving target.
    lda ts_cur
    cmp TASK_FOCUS
    bne !+
    stx TASK_FOCUS
!:
    jsr ts_load_target_zp
    sei
    ldx ts_target
    lda t_hwbuf_hi,x
    sta _tex_ld+2
    lda t_hwsp,x
    sta ts_sp_tmp
    tay
_tex_loop:
    iny
    beq _tex_done
_tex_ld:
    lda $C000,y                      // hi patched to hwbuf[target]
    sta $0100,y
    jmp _tex_loop
_tex_done:
    lda ts_target
    sta ts_cur
    ldx ts_sp_tmp
    txs
    cli
    rts

// -----------------------------------------------------------------------------
// task_gc_mark_all — mark the RS roots of every active task. Running task uses
// its live RSP; suspended tasks use the RSP saved in their ZP block (offset 2
// = where $04 lands). FS is not GC-scanned. Clobbers A,X,Y,W0,W1,$0A,$0B.
// -----------------------------------------------------------------------------
task_gc_mark_all:
    lda #0
    sta _tgma_i
_tgma_loop:
    ldx _tgma_i
    lda t_state,x
    beq _tgma_next
    lda t_rs_end_lo,x
    sta $0A
    lda t_rs_end_hi,x
    sta $0B
    cpx ts_cur
    bne _tgma_saved
    lda RSP
    sta W0
    lda RSP+1
    sta W0+1
    jmp _tgma_walk
_tgma_saved:
    lda t_zpsave_lo,x
    clc
    adc #2
    sta WM_MAP_PTR
    lda t_zpsave_hi,x
    adc #0
    sta WM_MAP_PTR+1
    ldy #0
    lda (WM_MAP_PTR),y
    sta W0
    iny
    lda (WM_MAP_PTR),y
    sta W0+1
_tgma_walk:
    jsr gc_mark_rs_range
_tgma_next:
    inc _tgma_i
    lda _tgma_i
    cmp #MAX_TASKS
    bne _tgma_loop
    rts

// -----------------------------------------------------------------------------
// task_set_others_root_window — set the saved current-window of every active
// task EXCEPT the running one to the ROOT handle (A:X). Called from wm_start:
// tasks that were fullscreen default to the ROOT console once the WM starts.
// -----------------------------------------------------------------------------
task_set_others_root_window:
    sta _tsorw_lo
    stx _tsorw_hi
    ldy #0
_tsorw_loop:
    cpy ts_cur
    beq _tsorw_next
    lda t_state,y
    beq _tsorw_next
    lda _tsorw_lo
    sta t_wmcur_lo,y
    lda _tsorw_hi
    sta t_wmcur_hi,y
_tsorw_next:
    iny
    cpy #MAX_TASKS
    bne _tsorw_loop
    rts
_tsorw_lo: .byte 0
_tsorw_hi: .byte 0

// =============================================================================
// Builtins.
// =============================================================================

// --- YIELD() → NONE — cooperative switch to the next active task ------------
builtin_yield:
    preamble_call(0, 0)
    jsr task_switch
    jmp postamble_return_none

// --- SPAWN(body) → NONE — start `body` (a callable TYPE_STR) as a task ------
builtin_spawn:
    jsr preamble_call_1_1_w0         // W0 = body handle
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq !+
    jmp panic_type
!:
    // Find a free slot (1..MAX_TASKS-1).
    ldx #1
_bsp_find:
    lda t_state,x
    beq _bsp_got
    inx
    cpx #MAX_TASKS
    bcc _bsp_find
    jmp panic_task                   // all task slots busy
_bsp_got:
    stx _bsp_slot
    lda W0
    sta t_func_lo,x
    lda W0+1
    sta t_func_hi,x

    // Fresh scope (may GC; body rooted via the args tuple on the caller RS).
    jsr dict_alloc                   // RV = scope

    ldx _bsp_slot
    // Root [body, scope] at the task RS bottom: [end-4]=body, [end-2]=scope.
    lda t_rs_end_lo,x
    sec
    sbc #4
    sta W2
    lda t_rs_end_hi,x
    sbc #0
    sta W2+1
    ldy #0
    lda t_func_lo,x
    sta (W2),y
    iny
    lda t_func_hi,x
    sta (W2),y
    iny
    lda RV
    sta (W2),y
    iny
    lda RV+1
    sta (W2),y

    // Zero the task's ZP-save block.
    ldx _bsp_slot
    lda t_zpsave_lo,x
    sta W2
    lda t_zpsave_hi,x
    sta W2+1
    ldy #ZPS_N-1
    lda #0
_bsp_zero:
    sta (W2),y
    dey
    bpl _bsp_zero

    // Seed fields (W2 = zpsave base).
    ldx _bsp_slot
    ldy #0                           // FSP ($02, off 0) = fs_end
    lda t_fs_end_lo,x
    sta (W2),y
    iny
    lda t_fs_end_hi,x
    sta (W2),y
    iny                              // RSP ($04, off 2) = rs_end - 4
    lda t_rs_end_lo,x
    sec
    sbc #4
    sta (W2),y
    iny
    lda t_rs_end_hi,x
    sbc #0
    sta (W2),y
    iny                              // FP ($06, off 4) = fs_end
    lda t_fs_end_lo,x
    sta (W2),y
    iny
    lda t_fs_end_hi,x
    sta (W2),y
    ldy #12                          // RV ($0E, off 12) = NONE
    lda #<NONE
    sta (W2),y
    iny
    lda #>NONE
    sta (W2),y
    ldy #47                          // CURRENT_SCOPE ($42, off 47) = scope
    lda RV
    sta (W2),y
    iny
    lda RV+1
    sta (W2),y
    iny                              // ROOT_SCOPE ($44, off 49) = scope
    lda RV
    sta (W2),y
    iny
    lda RV+1
    sta (W2),y

    // Prime the HW buffer to enter task_bootstrap on first switch-to:
    // hwbuf[slot][$FE:$FF] = (task_bootstrap-1), hwsp = $FD.
    ldx _bsp_slot
    lda t_hwbuf_hi,x
    sta _bsp_hwlo+2
    sta _bsp_hwhi+2
    ldy #$FE
    lda #<(task_bootstrap-1)
_bsp_hwlo:
    sta $C000,y
    iny
    lda #>(task_bootstrap-1)
_bsp_hwhi:
    sta $C000,y
    lda #$FD
    sta t_hwsp,x

    // Default current window: the ROOT console if the WM is running, else
    // fullscreen (0). The task can open its own window with WINDOW().
    ldx _bsp_slot
    lda WM_FLAGS
    lsr
    bcc _bsp_win0
    lda wm_root_h
    sta t_wmcur_lo,x
    lda wm_root_h+1
    sta t_wmcur_hi,x
    jmp _bsp_win_done
_bsp_win0:
    lda #0
    sta t_wmcur_lo,x
    sta t_wmcur_hi,x
_bsp_win_done:

    // Clean lexer indent state for the fresh task: all zero (depth 0,
    // stack[0]=0). parser_exec/lexer_init will set it up on entry.
    ldx _bsp_slot
    lda t_indent_lo,x
    sta W2
    lda t_indent_hi,x
    sta W2+1
    ldy #16
    lda #0
_bsp_ind:
    sta (W2),y
    dey
    bpl _bsp_ind

    ldx _bsp_slot
    lda #1
    sta t_state,x
    jmp postamble_return_none
