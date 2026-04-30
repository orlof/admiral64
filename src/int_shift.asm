// -----------------------------------------------------------------------------
// int_lshift / int_rshift — variable-length signed integer shifts.
//
//   in:   RS bottom→top: a, n. Both TYPE_INT.
//   out:  RV = a << n  (or a >> n, arithmetic right shift).
//
// We read n's payload[0] as an 8-bit unsigned shift count. Caps n at 255 —
// fine for any real workload (max 32-byte ints).
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

// =============================================================================
// int_lshift — a << n.
// =============================================================================
int_lshift:
    preamble_args(2, 0)

    // n's value (low byte).
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    sta B0                       // B0 = shift count

    // a's length and sign byte.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    sta B1                       // B1 = a length
    jsr sign_byte_W2
    sta B2                       // B2 = sign_a

    // result_len = a.len + (n >> 3) + 1
    lda B0
    lsr
    lsr
    lsr
    sta B3                       // B3 = byte_count
    clc
    adc B1
    clc
    adc #1
    sta ALLOC_SIZE
    sta B4                       // B4 = result_len
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int

    // Re-deref a.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2          // W2 = a payload

    // Result payload pointer in W3.
    jsr deref_RV_to_W3

    // Save result-payload base in W0 — we'll advance W3 segment-by-segment
    // so single-Y indexing works, then restore for the bit-shift pass.
    lda W3
    sta W0
    lda W3+1
    sta W0+1

    // --- Segment 1: zero-fill result[0..byte_count-1]. ---
    ldy #0
    lda #0
_ils_zerofill:
    cpy B3
    beq _ils_done_zero
    sta (W3),y
    iny
    jmp _ils_zerofill
_ils_done_zero:

    // Advance W3 by byte_count.
    lda W3
    clc
    adc B3
    sta W3
    bcc !skip+
    inc W3+1
!skip:

    // --- Segment 2: copy a's bytes (single Y over both src and dst). ---
    ldy #0
_ils_copy_a:
    cpy B1
    beq _ils_done_copy
    lda (W2),y
    sta (W3),y
    iny
    jmp _ils_copy_a
_ils_done_copy:

    // Advance W3 by a.len (=B1).
    lda W3
    clc
    adc B1
    sta W3
    bcc !skip+
    inc W3+1
!skip:

    // --- Segment 3: sign-fill the rest. result_len - byte_count - a.len bytes. ---
    sec
    lda B4
    sbc B3
    sec
    sbc B1
    sta B5                       // B5 = sign-fill count (typically 1)
    ldy #0
    lda B2
_ils_signfill:
    cpy B5
    beq _ils_done_sign
    sta (W3),y
    iny
    jmp _ils_signfill
_ils_done_sign:

    // Restore W3 = original result payload base.
    lda W0
    sta W3
    lda W0+1
    sta W3+1

    // --- Bit-shift left by (n & 7) ---
    // Inner loop must not touch carry between byte ROLs. Use `dex; bne` for
    // counter (neither affects C); reset Y=0 and clear C once per outer pass.
    lda B0
    and #7
    sta B5                       // B5 = remaining bit-shift count
_ils_bs_outer:
    lda B5
    beq _ils_normalize
    clc                          // shift in 0 at the bottom
    ldy #0
    ldx B4                       // X = bytes remaining in this pass
_ils_bs_inner:
    lda (W3),y
    rol
    sta (W3),y
    iny
    dex
    bne _ils_bs_inner
    dec B5
    jmp _ils_bs_outer

_ils_normalize:
    rs_push(RV)
    jsr int_normalize
    jmp postamble


// =============================================================================
// int_rshift — a >> n  (arithmetic right shift, sign-preserving).
// =============================================================================
int_rshift:
    preamble_args(2, 0)

    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    sta B0                       // B0 = shift count

    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    sta B1                       // B1 = a length
    jsr sign_byte_W2
    sta B2                       // B2 = sign_a

    lda B0
    lsr
    lsr
    lsr
    sta B3                       // B3 = byte_count

    // If byte_count >= a.len → result is just sign_a (1 byte).
    cmp B1
    bcc _irs_normal
    lda #1
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2
    lda B2
    ldy #0
    sta (W2),y
    jmp postamble

_irs_normal:
    // result_len = a.len - byte_count
    sec
    lda B1
    sbc B3
    sta B4
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int

    // Re-deref a.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2          // W2 = a payload base

    // Advance W2 by byte_count so (W2),y reads from a[byte_count..].
    lda W2
    clc
    adc B3
    sta W2
    bcc !skip+
    inc W2+1
!skip:

    // Result payload into W3.
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    ldy #H_PTR
    lda (W0),y
    sta W3
    iny
    lda (W0),y
    sta W3+1
    clc
    lda W3
    adc #O_HEADER
    sta W3
    bcc !skip+
    inc W3+1
!skip:

    // Copy a[byte_count..byte_count+result_len-1] → result[0..result_len-1].
    ldy #0
_irs_copy:
    cpy B4
    beq _irs_bs_init
    lda (W2),y
    sta (W3),y
    iny
    jmp _irs_copy

_irs_bs_init:
    // Bit-shift right by (n & 7), preserving sign.
    lda B0
    and #7
    sta B5
_irs_bs_outer:
    lda B5
    beq _irs_normalize
    // Start at MSB. First byte: ASR pattern (cmp #$80; ror) sets carry from
    // sign bit, then ROR; result preserves sign bit while shifting in 0/1
    // depending on original sign.
    ldy B4
    dey
    lda (W3),y
    cmp #$80
    ror
    sta (W3),y
_irs_bs_inner:
    dey
    bmi _irs_bs_next
    lda (W3),y
    ror                          // carry-in from byte above
    sta (W3),y
    jmp _irs_bs_inner
_irs_bs_next:
    dec B5
    jmp _irs_bs_outer

_irs_normalize:
    rs_push(RV)
    jsr int_normalize
    jmp postamble
