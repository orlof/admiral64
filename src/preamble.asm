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
// then jumps into `preamble`. The three most common signatures — (0,0),
// (1,0), (2,0) — collapse to a 3-byte `jsr preamble_N_0` against shared
// entry stubs (defined below); other shapes still expand inline.
.macro preamble_args(h, n) {
    .if (n == 0 && h == 0) { jsr preamble_0_0 }
    else .if (n == 0 && h == 1) { jsr preamble_1_0 }
    else .if (n == 0 && h == 2) { jsr preamble_2_0 }
    else {
        ldx #h
        ldy #n
        jsr preamble
    }
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
//
// Compiles to a 5-byte sequence (LDY #imm + JSR helper) for the common ZP
// destinations, falling back to inline for unusual targets. The shared
// helpers live in stacks.asm so they're available wherever arg_get is used.
.macro arg_get(i, dest) {
    ldy #(i*2)
    .if (dest == W0)      { jsr arg_get_w0 }
    else .if (dest == W1) { jsr arg_get_w1 }
    else .if (dest == W2) { jsr arg_get_w2 }
    else .if (dest == RV) { jsr arg_get_rv }
    else {
        lda (W3),y
        sta dest
        iny
        lda (W3),y
        sta dest+1
    }
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
// preamble_{0,1,2}_0 — shared entry stubs for the three most common
// preamble_args signatures. Each loads X=H, Y=0, then falls through to
// preamble. The chain uses the classic `.byte $2C` (BIT abs) trick so each
// upper entry skips the LDX of the entries below it without taking a real
// branch — three entry points in 13 bytes total. The BIT operands resolve
// to ZP+stack-page reads ($00A2/$01A2/$02A2), which are always safe RAM.
// -----------------------------------------------------------------------------
preamble_2_0:
    ldx #2
    .byte $2C            // BIT abs — eats `ldx #1` of preamble_1_0
preamble_1_0:
    ldx #1
    .byte $2C            // BIT abs — eats `ldx #0` of preamble_0_0
preamble_0_0:
    ldx #0
    ldy #0
    jmp preamble

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
    jmp panic_arity

// -----------------------------------------------------------------------------
// preamble_call_1_1_w0 — common opener for 1-arg builtins:
//     preamble_call(1, 1); arg_get(0, W0)
// Tail-jumps into arg_get_w0 so its rts returns to the builtin's body.
//
// preamble_call_2_2_w0_w1 — common opener for 2-arg builtins:
//     preamble_call(2, 2); arg_get(0, W0); arg_get(1, W1)
// -----------------------------------------------------------------------------
preamble_call_1_1_w0:
    ldx #1
    ldy #1
    jsr _preamble_call
    ldy #0
    jmp arg_get_w0

preamble_call_2_2_w0_w1:
    ldx #2
    ldy #2
    jsr _preamble_call
    ldy #0
    jsr arg_get_w0
    ldy #2
    jmp arg_get_w1

// -----------------------------------------------------------------------------
// postamble_return_{true,false,none} — labeled tail entries that load the
// matching static handle into A/X and fall through to postamble_set_rv_ax.
// The first two entries use `bne postamble_set_rv_ax` to skip the trailing
// entries; the BNE is always taken because `ldx #>HANDLE` clears Z whenever
// the handle's hi byte is non-zero (statics live well above page $00, so
// this holds for every reachable build layout).
//
// A call site that returns one of these handles becomes a 3-byte
//     jmp postamble_return_<x>
// instead of the 7-byte
//     lda #<H ; ldx #>H ; jmp postamble_set_rv_ax.
//
// postamble_set_rv_ax — generic tail helper for any non-handle-specific
// return. Caller passes A = lo, X = hi. Falls through into postamble.
// -----------------------------------------------------------------------------
postamble_return_true:
    lda #<TRUE
    ldx #>TRUE
    bne postamble_set_rv_ax  // always taken (hi != 0)
postamble_return_false:
    lda #<FALSE
    ldx #>FALSE
    bne postamble_set_rv_ax  // always taken (hi != 0)
postamble_return_none:
    lda #<NONE
    ldx #>NONE
postamble_set_rv_ax:
    sta RV
    stx RV+1
    jmp postamble

// postamble_peek_rv — read top of RS into RV (without popping), then fall
// through. Saves 3 bytes per use vs `rs_peek(RV) ; jmp postamble`.
postamble_peek_rv:
    jsr rs_peek_rv
    jmp postamble

// postamble_pop_rv — pop top of RS into RV, then fall through to postamble.
// Saves 3 bytes per use vs `rs_pop(RV) ; jmp postamble`.
postamble_pop_rv:
    jsr rs_pop_rv
    jmp postamble

// postamble_arg0_rv — write the call's first arg into RV, then fall through.
// Saves 5 bytes per use vs `arg_get(0, RV) ; jmp postamble`.
postamble_arg0_rv:
    ldy #0
    jsr arg_get_rv          // A is left in arg-deref's terminal state, but
                            // arg0_rv callers consume RV — the byte return
                            // bag below pha's whatever lands here.

// postamble_a_ff / _one / _zero — load a byte constant into A and fall through
// to postamble. Used by val_eq / val_cmp / val_truthy to return $FF / $01 / $00
// as a byte. The .byte $2C is `BIT abs` — it consumes the next 2 bytes (the
// following `lda #N` opcode + operand) as a harmless absolute-address read,
// leaving A untouched, so each upstream entry skips the lower entries.
postamble_a_ff:
    lda #$FF
    .byte $2C
postamble_a_one:
    lda #1
    .byte $2C
postamble_a_zero:
    lda #0

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

// -----------------------------------------------------------------------------
// postamble_set_rv_int_b0 — tail helper that allocates a 1-byte TYPE_INT
// holding the value in B0, points RV at it, and runs postamble. Used by every
// builtin whose return shape is "wrap a single byte as an INT" (builtin_len,
// builtin_type, builtin_ord positive case, builtin_int from BOOL, etc.).
//
// Caller: stash the byte in B0, then `jmp postamble_set_rv_int_b0`.
//
// postamble_set_rv_uint8_b0 — same idea but B0 is unsigned 0..255: bytes
// 128..255 land in a 2-byte INT with high byte 0 so the result stays
// non-negative. Used by builtin_ord and builtin_peek.
// -----------------------------------------------------------------------------
// Unsigned 0..255 → inline int (high 24 bits zero, always non-negative).
postamble_set_rv_uint8_b0:
    lda B0
    sta W2
    lda #0
    sta W2+1
    sta W3
    sta W3+1
    jsr alloc_inline_int
    jmp postamble
// Signed -128..127 → inline int (sign-extend B0 to 32 bits).
postamble_set_rv_int_b0:
    lda B0
    sta W2
    lda #0
    sta W2+1
    sta W3
    sta W3+1
    lda B0
    bpl _psib_alloc
    lda #$FF
    sta W2+1
    sta W3
    sta W3+1
_psib_alloc:
    jsr alloc_inline_int
    jmp postamble
// W2:W3 (lo16:hi16) already holds the 32-bit value → inline int.
postamble_set_rv_int32:
    jsr alloc_inline_int
    jmp postamble
