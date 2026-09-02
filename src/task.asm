// -----------------------------------------------------------------------------
// task.asm — cooperative context switch + task lifecycle (multitasking core).
//
// PLANS/multitasking.md, milestone B (core). This first cut is COOPERATIVE
// (YIELD / blocking-call yield) with a fixed 2-task table; preemption (a
// timer IRQ setting a switch-pending flag checked at parser_stmt), N>2, and
// focus/hotkey are the next layer.
//
// A task is an interpreter execution context. Per-task state that is NOT
// shared with the heap allocator:
//   - the software stacks FS/RS (each task its own region),
//   - the zero-page register file ($02-$1F, $31-$47: FSP/RSP/FP, RV/RV2,
//     W0-W3/B0-B7, LEX_*, SCREEN_ROW/COL, CURRENT_SCOPE/ROOT_SCOPE,
//     METHOD_RECEIVER),
//   - the 6510 hardware stack (page $01), copy-swapped through a per-task
//     buffer.
// SHARED (never swapped): the allocator + GC state ($20-$30, $48), WM_FLAGS,
// STOP_REQUESTED — one heap, one screen.
//
// Memory (fixed; carved below the heap — HEAP_DATA_START moved up to suit):
//   $8800-$8C00  task 0 FS (1 KB)          (unchanged; = FS_BEGIN..FS_END)
//   $8C00-$9000  task 0 RS (1 KB)          (unchanged; = RS_BEGIN..RS_END)
//   $9000+       heap (HEAP_DATA_START, unchanged)
//   $C000-$C200  task 1 FS (512 B)   \
//   $C200-$C400  task 1 RS (512 B)    |  in the always-RAM $C000 gap so the
//   $C400-$C4FF  task 0 HW buffer     |  base heap window is untouched (hfp's
//   $C500-$C5FF  task 1 HW buffer     |  $9000-$A000 stays 4 KB).
//   $C600-$C635  task 0 ZP save       |
//   $C640-$C675  task 1 ZP save      /
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

.const TASK_COUNT   = 2
.const T0_RS_END    = RS_END         // $9000
// task 1 stacks + the switch metadata live in the $C000-$CFFF always-RAM gap
// (free in every test fixture: below BASIC ROM $A000-$BFFF, KERNAL $E000+,
// and the handle table). This keeps HEAP_DATA_START at $9000 so the base
// heap window is unchanged.
.const T1_FS_BEGIN  = $C000
.const T1_FS_END    = $C200
.const T1_RS_BEGIN  = $C200
.const T1_RS_END    = $C400

.label t_hwbuf0  = $C400
.label t_hwbuf1  = $C500
.label t_zpsave0 = $C600
.label t_zpsave1 = $C640

// ZP save block: two ranges, $02-$1F (30 B) then $31-$47 (23 B) = 53 B.
.const ZPS_R1_LO = $02
.const ZPS_R1_HI = $20               // exclusive
.const ZPS_R2_LO = $31
.const ZPS_R2_HI = $48               // exclusive
.const ZPS_R1_N  = ZPS_R1_HI - ZPS_R1_LO   // 30

// Per-task scalars (code segment — tiny, not GC-relevant).
ts_cur:      .byte 0                 // index of the running task
ts_target:   .byte 0                 // switch destination (scratch)
t_state:     .byte 0, 0              // 0 = free, 1 = active
t_hwsp:      .byte 0, 0              // saved 6510 SP per task
t_func_lo:   .byte 0, 0              // task body handle (rooted on the task RS)
t_func_hi:   .byte 0, 0
ts_sp_tmp:   .byte 0

task_rs_end_lo: .byte <T0_RS_END, <T1_RS_END
task_rs_end_hi: .byte >T0_RS_END, >T1_RS_END

// -----------------------------------------------------------------------------
// task_gc_mark_all — mark the RS roots of every active task. The running task
// uses its live RSP; a suspended task uses the RSP saved in its ZP block
// (offset 2 = where $04 lands). Called from gc_mark. Clobbers A,X,Y,W0,W1,
// $0A,$0B. FS is not GC-scanned (it holds saved bytes, not handle roots).
// -----------------------------------------------------------------------------
task_gc_mark_all:
    // running task: live RSP, end = task_rs_end[ts_cur]
    lda RSP
    sta W0
    lda RSP+1
    sta W0+1
    ldx ts_cur
    lda task_rs_end_lo,x
    sta $0A
    lda task_rs_end_hi,x
    sta $0B
    jsr gc_mark_rs_range
    // the other task (2-task table), if active
    lda ts_cur
    eor #1
    tax                              // X = other index
    lda t_state,x
    bne !+
    rts
!:
    txa
    bne _tgma_other1
    // other = task 0: RSP from t_zpsave0 + 2
    lda t_zpsave0 + 2
    sta W0
    lda t_zpsave0 + 3
    sta W0+1
    ldx #0
    jmp _tgma_walk
_tgma_other1:
    lda t_zpsave1 + 2
    sta W0
    lda t_zpsave1 + 3
    sta W0+1
    ldx #1
_tgma_walk:
    lda task_rs_end_lo,x
    sta $0A
    lda task_rs_end_hi,x
    sta $0B
    jmp gc_mark_rs_range

// -----------------------------------------------------------------------------
// task_init — boot: task 0 is the running REPL; task 1 free.
// -----------------------------------------------------------------------------
task_init:
    lda #0
    sta ts_cur
    lda #1
    sta t_state+0
    lda #0
    sta t_state+1
    rts

// -----------------------------------------------------------------------------
// ZP-save address helpers. $08/$09 = zpsave base of ts_cur (save) or
// ts_target (load). Load uses a pointer OUTSIDE the $02-$1F range it writes,
// so it lives at $4C/$4D (WM_SCR_PTR — transient scratch).
// -----------------------------------------------------------------------------
ts_save_cur_zp:
    lda ts_cur
    bne _tscz_1
    lda #<t_zpsave0
    sta $08
    lda #>t_zpsave0
    sta $09
    jmp _tscz_go
_tscz_1:
    lda #<t_zpsave1
    sta $08
    lda #>t_zpsave1
    sta $09
_tscz_go:
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
    rts

ts_load_target_zp:
    lda ts_target
    bne _tltz_1
    lda #<t_zpsave0
    sta WM_SCR_PTR
    lda #>t_zpsave0
    sta WM_SCR_PTR+1
    jmp _tltz_go
_tltz_1:
    lda #<t_zpsave1
    sta WM_SCR_PTR
    lda #>t_zpsave1
    sta WM_SCR_PTR+1
_tltz_go:
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
    rts

// -----------------------------------------------------------------------------
// task_switch — round-robin to the next active task. No-op if this is the
// only active task. Called from YIELD and (later) the preemption check.
//
// The hardware-stack swap is a critical section: NO jsr/push/pull between
// "SP still = current" and the final rts, or the saved/restored stacks
// desync. ZP save/load happen before it (via jsr, clean).
// -----------------------------------------------------------------------------
task_switch:
    // next active task after ts_cur (2-task: the other one, if active)
    ldx ts_cur
    inx
    cpx #TASK_COUNT
    bcc !+
    ldx #0
!:
    lda t_state,x
    bne !+
    rts                              // the other task isn't active → stay
!:
    stx ts_target

    jsr ts_save_cur_zp               // current ZP → its save block
    jsr ts_load_target_zp            // target's save block → ZP (FSP/RSP/... )

    // --- critical section: no jsr / push / pull until the rts ---
    // Save current task's HW stack: hwbuf[cur][SP+1..FF] = $0100[SP+1..FF].
    tsx
    stx ts_sp_tmp
    ldy ts_cur
    lda ts_sp_tmp
    sta t_hwsp,y
    ldy ts_sp_tmp
_tsw_save:
    iny
    beq _tsw_save_done               // Y wrapped past $FF → empty above SP
    lda $0100,y
    ldx ts_cur
    beq _tsw_save0
    sta t_hwbuf1,y
    jmp _tsw_save
_tsw_save0:
    sta t_hwbuf0,y
    jmp _tsw_save
_tsw_save_done:

    // Restore target's HW stack into page $01.
    ldx ts_target
    lda t_hwsp,x
    sta ts_sp_tmp
    tay
_tsw_load:
    iny
    beq _tsw_load_done
    ldx ts_target
    beq _tsw_load0
    lda t_hwbuf1,y
    jmp _tsw_load_store
_tsw_load0:
    lda t_hwbuf0,y
_tsw_load_store:
    sta $0100,y
    jmp _tsw_load
_tsw_load_done:

    lda ts_target
    sta ts_cur
    ldx ts_sp_tmp
    txs
    rts                              // → target's continuation (yield / bootstrap)

// -----------------------------------------------------------------------------
// task_bootstrap — first entry of a freshly spawned task. Runs the task body
// (a callable TYPE_STR rooted on the task's RS) via parser_exec, then exits.
// Reached because SPAWN primed the task's HW buffer with this address.
// -----------------------------------------------------------------------------
task_bootstrap:
    ldx ts_cur
    lda t_func_lo,x
    sta W0
    lda t_func_hi,x
    sta W0+1
    rs_push(W0)
    jsr parser_exec                  // run the body in the task's own scope
    // fall into task_exit

// -----------------------------------------------------------------------------
// task_exit — the current (spawned) task is done: free its slot and switch to
// another active task. Task 0 (the REPL) never exits. Does NOT save the dying
// task's context.
// -----------------------------------------------------------------------------
task_exit:
    ldx ts_cur
    lda #0
    sta t_state,x

    // pick another active task (2-task: task 0).
    lda #0
    sta ts_target                    // fall back to task 0
    ldx #0
_tex_find:
    lda t_state,x
    bne _tex_found
    inx
    cpx #TASK_COUNT
    bcc _tex_find
    // no active task at all — shouldn't happen (task 0 is immortal); halt-ish
    lda #0
    sta ts_target
    jmp _tex_switch
_tex_found:
    stx ts_target
_tex_switch:
    jsr ts_load_target_zp            // load target ZP (dying task's not saved)
    ldx ts_target
    lda t_hwsp,x
    sta ts_sp_tmp
    tay
_tex_load:
    iny
    beq _tex_load_done
    ldx ts_target
    beq _tex_load0
    lda t_hwbuf1,y
    jmp _tex_store
_tex_load0:
    lda t_hwbuf0,y
_tex_store:
    sta $0100,y
    jmp _tex_load
_tex_load_done:
    lda ts_target
    sta ts_cur
    ldx ts_sp_tmp
    txs
    rts

// =============================================================================
// Builtins.
// =============================================================================

// --- YIELD() → NONE — cooperative switch to the next active task ------------
builtin_yield:
    preamble_call(0, 0)
    jsr task_switch
    jmp postamble_return_none

// --- SPAWN(body) → NONE — start `body` (a callable TYPE_STR) as a task ------
// 2-task core: only task slot 1. Panics if it's already busy.
builtin_spawn:
    jsr preamble_call_1_1_w0         // W0 = body handle
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq !+
    jmp panic_type
!:
    lda t_state+1
    beq !+
    jmp panic_type                   // no free task slot
!:
    // Root body + a fresh scope on task 1's RS: [body, scope], RSP1 = end-4.
    lda W0
    sta t_func_lo+1
    lda W0+1
    sta t_func_hi+1

    // fresh scope for the task
    jsr dict_alloc                   // RV = scope (may GC; body handle stable)
    // task 1 RS bottom two slots: [end-4] = body, [end-2] = scope
    lda #<(T1_RS_END-4)
    sta W2
    lda #>(T1_RS_END-4)
    sta W2+1
    ldy #0
    lda t_func_lo+1
    sta (W2),y
    iny
    lda t_func_hi+1
    sta (W2),y
    iny
    lda RV
    sta (W2),y
    iny
    lda RV+1
    sta (W2),y

    // Zero task 1's ZP-save block, then seed the fields.
    ldx #0
    lda #0
_bsp_zero:
    sta t_zpsave1,x
    inx
    cpx #(ZPS_R2_HI - ZPS_R1_LO)     // 53
    bne _bsp_zero

    // FSP ($02 → offset 0) = T1_FS_END
    lda #<T1_FS_END
    sta t_zpsave1 + 0
    lda #>T1_FS_END
    sta t_zpsave1 + 1
    // RSP ($04 → offset 2) = T1_RS_END - 4
    lda #<(T1_RS_END-4)
    sta t_zpsave1 + 2
    lda #>(T1_RS_END-4)
    sta t_zpsave1 + 3
    // FP ($06 → offset 4) = T1_FS_END
    lda #<T1_FS_END
    sta t_zpsave1 + 4
    lda #>T1_FS_END
    sta t_zpsave1 + 5
    // RV ($0E → offset 12) = NONE
    lda #<NONE
    sta t_zpsave1 + 12
    lda #>NONE
    sta t_zpsave1 + 13
    // CURRENT_SCOPE ($42 → offset 30 + ($42-$31)=47) = scope
    lda RV
    sta t_zpsave1 + 47
    lda RV+1
    sta t_zpsave1 + 48
    // ROOT_SCOPE ($44 → offset 49) = scope
    lda RV
    sta t_zpsave1 + 49
    lda RV+1
    sta t_zpsave1 + 50

    // HW buffer: prime the return to task_bootstrap. hwsp = $FD so rts pops
    // $01FE/$01FF = bootstrap-1.
    lda #<(task_bootstrap-1)
    sta t_hwbuf1 + $FE
    lda #>(task_bootstrap-1)
    sta t_hwbuf1 + $FF
    lda #$FD
    sta t_hwsp+1

    lda #1
    sta t_state+1
    jmp postamble_return_none
