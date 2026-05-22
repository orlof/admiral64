// -----------------------------------------------------------------------------
// int_lshift / int_rshift — fixed 32-bit shifts.
//
//   in:  RS bottom→top: a, n. Both TYPE_INT.
//   out: RV = a << n  (logical)  /  a >> n  (arithmetic, sign-preserving).
//
// Shift count n is read as 32-bit; n >= 32 (or any high byte set) yields the
// saturated result (0 for <<, 0/-1 for >>). << drops bits past bit 31.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"

// =============================================================================
// int_lshift — a << n.
// =============================================================================
int_lshift:
    preamble_args(2, 0)
    rs_peek_at(W0, 1)
    jsr int_load_a               // B0..B3 = a
    rs_peek_at(W1, 0)
    jsr int_load_b               // B4..B7 = n

    lda B5
    ora B6
    ora B7
    bne _ls_zero                 // n >= 65536 → 0
    lda B4
    cmp #32
    bcs _ls_zero                 // n >= 32 → 0
    tax
    beq _ls_done
_ls_loop:
    asl B0
    rol B1
    rol B2
    rol B3
    dex
    bne _ls_loop
_ls_done:
    jsr alloc_int_b0
    jmp postamble
_ls_zero:
    lda #0
    sta B0
    sta B1
    sta B2
    sta B3
    jsr alloc_int_b0
    jmp postamble

// =============================================================================
// int_rshift — a >> n (arithmetic right shift, sign-preserving).
// =============================================================================
int_rshift:
    preamble_args(2, 0)
    rs_peek_at(W0, 1)
    jsr int_load_a               // B0..B3 = a
    rs_peek_at(W1, 0)
    jsr int_load_b               // B4..B7 = n

    lda B5
    ora B6
    ora B7
    bne _rs_full                 // n >= 65536 → saturate
    lda B4
    cmp #32
    bcs _rs_full                 // n >= 32 → saturate
    tax
    beq _rs_done
_rs_loop:
    lda B3
    cmp #$80                     // C = sign bit → preserved through ROR
    ror B3
    ror B2
    ror B1
    ror B0
    dex
    bne _rs_loop
_rs_done:
    jsr alloc_int_b0
    jmp postamble
_rs_full:
    // Saturate: 0 if a >= 0, else -1 (all $FF).
    lda B3
    bmi _rs_neg1
    lda #0
    beq _rs_fill                 // always (A==0)
_rs_neg1:
    lda #$FF
_rs_fill:
    sta B0
    sta B1
    sta B2
    sta B3
    jsr alloc_int_b0
    jmp postamble
