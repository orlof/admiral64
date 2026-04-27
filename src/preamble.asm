// -----------------------------------------------------------------------------
// preamble / postamble — per-routine save/restore of the ZP register file AND
// both stacks' "target" pointers.
//
// Every user-facing routine:
//     my_routine:
//         preamble_args(H, N)     ; H = handle args on RS, N = non-handle args on FS
//         ... body — freely uses W/B regs, rs_push/fs_push, calls sub-routines ...
//         ; write result to RV (word) and/or A (byte) before exit
//         jmp postamble
//
// The callee-pops contract (symmetric for RS and FS):
//   - Caller pushes H handle args onto RS and N non-handle args onto FS before
//     the `jsr`. Pushes need not be balanced — postamble handles cleanup.
//   - Callee's postamble restores RSP, FSP, and FP to the values they held
//     immediately BEFORE the caller pushed any args. So:
//       * Caller-pushed args are consumed.
//       * Any `rs_push` / `fs_push` the callee did in its body is also swept.
//       * RV / A survive (they're not on any stack).
//
// Frame layout on FS (22 bytes, grows down, FP = base):
//   (FP, 0..15)  = saved W0..W3, B0..B7
//   (FP, 16..17) = target_RSP = RSP_at_entry + 2·H   (pre-arg-push RSP)
//   (FP, 18..19) = saved caller's FP
//   (FP, 20..21) = target_FSP = FSP_at_entry + 2·N   (pre-arg-push FSP)
//   (FP, 22..)   = caller-pushed non-handle args (accessed via fs_peek_arg)
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"

// Convenience macro for call sites. Sets X = handle_count, Y = nonhandle_count,
// then jumps into `preamble`.
.macro preamble_args(h, n) {
    ldx #h
    ldy #n
    jsr preamble
}

// -----------------------------------------------------------------------------
// preamble — carve a new frame on FS and save caller state.
//   in:  X = handle arg count (caller pushed H handles on RS)
//        Y = non-handle arg count (caller pushed N words on FS)
//   out: FP -> new frame base; FSP advanced; target pointers and saved FP
//        populated.
//   clobbers: A, X, Y. RV preserved (not touched).
// -----------------------------------------------------------------------------
preamble:
    pha                       // save A (may be byte arg)

    // Push caller's FP high+low to HW stack for later retrieval.
    lda FP+1
    pha
    lda FP
    pha

    // Compute target_FSP = FSP + 2·Y; push hi/lo to HW stack.
    tya
    asl
    clc
    adc FSP
    tay                       // Y = target_FSP_lo (temp)
    lda FSP+1
    adc #0
    pha                       // HW: target_FSP_hi
    tya
    pha                       // HW:   target_FSP_lo (on top of _hi)

    // Carve 22-byte frame: FSP -= 22.
    sec
    lda FSP
    sbc #22
    sta FSP
    bcs !+
    dec FSP+1
!:
    // FP = FSP — new frame base.
    lda FSP
    sta FP
    lda FSP+1
    sta FP+1

    // Save W0..W3, B0..B7 (16 bytes at $0010..$001F) into (FP, 0..15).
    ldy #15
!loop:
    lda $0010,y
    sta (FP),y
    dey
    bpl !loop-

    // target_RSP = RSP + 2·X (X = handle arg count).
    txa
    asl
    clc
    adc RSP
    ldy #16
    sta (FP),y
    lda RSP+1
    adc #0
    iny
    sta (FP),y

    // Pull target_FSP lo/hi from HW stack, store at (FP, 20..21).
    ldy #20
    pla                       // target_FSP_lo
    sta (FP),y
    iny
    pla                       // target_FSP_hi
    sta (FP),y

    // Pull caller's FP lo/hi from HW stack, store at (FP, 18..19).
    ldy #18
    pla                       // caller_FP_lo
    sta (FP),y
    iny
    pla                       // caller_FP_hi
    sta (FP),y

    pla                       // restore A
    rts

// -----------------------------------------------------------------------------
// postamble — restore caller state and return.
//   in:  FP -> current frame (as set by preamble); RV / A hold return values.
//   out: W0..W3, B0..B7 restored; RSP, FSP, FP restored to pre-args-push
//        values; rts to the routine's caller.
//   clobbers: Y. (A preserved so byte returns survive.)
// -----------------------------------------------------------------------------
postamble:
    pha                       // save A (may be byte return)

    // Restore W0..W3, B0..B7 from (FP, 0..15).
    ldy #15
!loop:
    lda (FP),y
    sta $0010,y
    dey
    bpl !loop-

    // Restore RSP from (FP, 16..17).
    ldy #16
    lda (FP),y
    sta RSP
    iny
    lda (FP),y
    sta RSP+1

    // Read target_FSP (FP, 20..21) and caller's FP (FP, 18..19) onto HW
    // stack; FP itself will be clobbered by the restore, so we stage first.
    ldy #20
    lda (FP),y
    pha                       // HW: target_FSP_lo
    iny
    lda (FP),y
    pha                       // HW: target_FSP_hi

    ldy #18
    lda (FP),y
    pha                       // HW: caller_FP_lo
    iny
    lda (FP),y
    pha                       // HW: caller_FP_hi

    // Restore FP = caller's FP.
    pla                       // caller_FP_hi
    sta FP+1
    pla                       // caller_FP_lo
    sta FP

    // Restore FSP = target_FSP.
    pla                       // target_FSP_hi
    sta FSP+1
    pla                       // target_FSP_lo
    sta FSP

    pla                       // restore A
    rts
