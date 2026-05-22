// -----------------------------------------------------------------------------
// int_divmod — fixed 32-bit signed long division, BOTH quotient and remainder.
// Truncating (C/Java) semantics:  sign(q)=sign(a)^sign(b), sign(r)=sign(a),
// q*b + r == a.
//
//   in:  2 handles on RS — a (dividend, deeper), b (divisor, top)
//   out: RV  = signed quotient (inline int)
//        RV2 = signed remainder (inline int)
//
// Division by zero panics (ERR_DIV_ZERO).
//
// Operands reduced to unsigned magnitudes, then classic restoring division of
// the 64-bit (rem:quot) shift register: 32 iterations of "shift left; if
// rem>=divisor, rem-=divisor and set quot bit0". quot starts as |a| and ends
// as |q|; rem ends as |r|. Signs applied afterward.
//
// Register map during the loop:
//   B0..B3 = quot   B4..B7 = divisor   W0:W1 = rem   W2:W3 = trial-subtract
//   $FB = sign_a    $FC = sign_q    (spare ZP, untouched by GC and sub-calls)
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"

int_divmod:
    preamble_args(2, 0)
    rs_peek_at(W0, 1)
    jsr int_load_a               // B0..B3 = a → quotient register
    rs_peek_at(W1, 0)
    jsr int_load_b               // B4..B7 = b → divisor

    // Divisor zero?
    lda B4
    ora B5
    ora B6
    ora B7
    bne _dm_nonzero
    jmp panic_div_zero
_dm_nonzero:

    // sign_a (bit7 of B3), sign_q = sign_a XOR sign_b.
    lda B3
    sta $FB
    eor B7
    sta $FC

    // |a|
    lda B3
    bpl _dm_a_pos
    sec
    lda #0
    sbc B0
    sta B0
    lda #0
    sbc B1
    sta B1
    lda #0
    sbc B2
    sta B2
    lda #0
    sbc B3
    sta B3
_dm_a_pos:
    // |b|
    lda B7
    bpl _dm_b_pos
    sec
    lda #0
    sbc B4
    sta B4
    lda #0
    sbc B5
    sta B5
    lda #0
    sbc B6
    sta B6
    lda #0
    sbc B7
    sta B7
_dm_b_pos:

    // rem = 0
    lda #0
    sta W0
    sta W0+1
    sta W1
    sta W1+1

    ldy #32
_dm_loop:
    // (rem:quot) <<= 1
    asl B0
    rol B1
    rol B2
    rol B3
    rol W0
    rol W0+1
    rol W1
    rol W1+1
    // trial = rem - divisor  (W2:W3)
    sec
    lda W0
    sbc B4
    sta W2
    lda W0+1
    sbc B5
    sta W2+1
    lda W1
    sbc B6
    sta W3
    lda W1+1
    sbc B7
    sta W3+1
    bcc _dm_nosub                // borrow → rem < divisor
    lda W2
    sta W0
    lda W2+1
    sta W0+1
    lda W3
    sta W1
    lda W3+1
    sta W1+1
    lda B0
    ora #1
    sta B0
_dm_nosub:
    dey
    bne _dm_loop

    // Apply sign_q to quotient (B0..B3).
    lda $FC
    bpl _dm_q_pos
    sec
    lda #0
    sbc B0
    sta B0
    lda #0
    sbc B1
    sta B1
    lda #0
    sbc B2
    sta B2
    lda #0
    sbc B3
    sta B3
_dm_q_pos:
    // Apply sign_a to remainder (W0:W1).
    lda $FB
    bpl _dm_r_pos
    sec
    lda #0
    sbc W0
    sta W0
    lda #0
    sbc W0+1
    sta W0+1
    lda #0
    sbc W1
    sta W1
    lda #0
    sbc W1+1
    sta W1+1
_dm_r_pos:

    // Stash remainder on FS (survives the quotient allocation's GC), alloc
    // quotient, root it, then alloc remainder.
    fs_push(W0)                  // rem lo word
    fs_push(W1)                  // rem hi word
    jsr alloc_int_b0             // RV = quotient (from B0..B3)
    rs_push(RV)                  // root quotient across the remainder alloc
    fs_pop(W1)                   // LIFO: rem hi
    fs_pop(W0)                   // rem lo
    lda W0
    sta W2
    lda W0+1
    sta W2+1
    lda W1
    sta W3
    lda W1+1
    sta W3+1
    jsr alloc_inline_int         // RV = remainder (from W2:W3)

    // Harvest: RV2 = remainder, RV = quotient (popped from RS).
    lda RV
    sta RV2
    lda RV+1
    sta RV2+1
    rs_pop(W0)
    lda W0
    sta RV
    lda W0+1
    sta RV+1
    jmp postamble
