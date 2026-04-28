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
// Calling convention v2 — args tuple
//
// Variadic builtins (and future user functions) receive their args as a single
// TYPE_TUPLE on RS. `preamble_call(MIN, MAX)` does the standard frame save
// (preamble_args(1, 0)) + derefs the tuple into W3 + arity-checks against
// [MIN, MAX], panicking ERR_ARITY on mismatch.
//
// After preamble_call:
//   W3  = tuple payload pointer (callee-saved by the V4' frame)
//   B7  = arg count cached for arg_get_or fallback checks
//
// Helpers:
//   arg_get(i, dest)              dest = tuple[i]                    (no bounds check)
//   arg_get_or(i, fallback, dest) dest = tuple[i] if i < count, else fallback
//
// GC re-deref rule: any sub-call that may allocate (alloc, alloc_int, jsr to
// another builtin, etc.) can move the tuple's payload via gc_compact. After
// such a call, the body must rerun the deref before another arg_get:
//
//     rs_peek(W0)        ; W0 = args tuple handle (still on RS top)
//     jsr deref_W0_to_W2
//     lda W2 ; sta W3
//     lda W2+1 ; sta W3+1
//
// (Same pattern str_upper already uses for its receiver after alloc.)
// -----------------------------------------------------------------------------

.macro preamble_call(min, max) {
    ldx #min
    ldy #max
    jsr _preamble_call
}

// Read tuple[i] (a 2-byte handle) into `dest`. No bounds check — caller must
// have arity-checked at preamble_call. `i` is a literal slot index 0..N-1.
.macro arg_get(i, dest) {
    ldy #(i*2)
    lda (W3),y
    sta dest
    iny
    lda (W3),y
    sta dest+1
}

// Read tuple[i] if i < arg_count, else load constant `fallback` (a static
// handle label). Used for optional positional args (e.g., `dict.get(key,
// default=NONE)`).
.macro arg_get_or(i, fallback, dest) {
    lda B7
    cmp #(i + 1)
    bcc !default+
    ldy #(i*2)
    lda (W3),y
    sta dest
    iny
    lda (W3),y
    sta dest+1
    jmp !done+
!default:
    lda #<fallback
    sta dest
    lda #>fallback
    sta dest+1
!done:
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
// _preamble_call — back end for the `preamble_call(MIN, MAX)` macro.
//
//   in:  X = MIN, Y = MAX. RS top = args tuple handle.
//   out: standard V4' frame established (1 RS arg consumed at postamble);
//        W3 = tuple payload pointer, B7 = element count.
//        Panics ERR_ARITY if count not in [MIN, MAX].
//   clobbers: A, X, Y, W0..W3, B7. (Only the body's view of registers matters
//             — preamble.s frame already saved the caller's W/B.)
// -----------------------------------------------------------------------------
_preamble_call:
    // SMC the immediate operands of the two cmp instructions below with MIN/MAX.
    stx _pcs_min_imm + 1
    sty _pcs_max_imm + 1

    // Standard V4' frame save: 1 RS arg, 0 FS args.
    ldx #1
    ldy #0
    jsr preamble

    // Read args tuple handle from RS top.
    ldy #0
    lda (RSP),y
    sta W0
    iny
    lda (RSP),y
    sta W0+1

    // Deref → W2 = payload pointer (post-header), A = element count.
    jsr deref_W0_to_W2

    // Cache payload pointer in W3 (V4' frame keeps it across body sub-calls).
    ldx W2
    stx W3
    ldx W2+1
    stx W3+1

    // Cache count in B7.
    sta B7

_pcs_min_imm:
    cmp #$00                  // SMC: cmp #min  ← X at entry
    bcc _pcs_panic            // count < min → panic
_pcs_max_imm:
    cmp #$00                  // SMC: cmp #max  ← Y at entry
    beq _pcs_done             // count == max → ok
    bcs _pcs_panic            // count > max → panic
_pcs_done:
    rts

_pcs_panic:
    lda #ERR_ARITY
    sta ERROR_CODE
    jmp error_handler

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
