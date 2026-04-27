// -----------------------------------------------------------------------------
// int_cmp — three-way signed comparison of two ints.
//
//   in:  2 handles on RS — a (deeper), b (top). Both assumed normalized.
//   out: A = $FF if a < b, $00 if a == b, $01 if a > b.
//        Both args consumed from RS.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

int_cmp:
    preamble_args(2, 0)

    // --- Deref both handles ---
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    sta B0                    // B0 = AL

    rs_peek_at(W1, 0)
    jsr deref_W1_to_W3
    sta B1                    // B1 = BL

    // --- Sign bytes ---
    lda B0
    jsr sign_byte_W2
    sta B2                    // B2 = AS

    lda B1
    jsr sign_byte_W3
    sta B3                    // B3 = BS

    // --- Different signs? ---
    lda B2
    cmp B3
    bne _cmp_sign_diff

    // --- Same sign. Lengths differ? ---
    lda B0
    cmp B1
    beq _cmp_same_len
    bcc _cmp_a_shorter
    // AL > BL: a has larger magnitude.
    lda B2                    // check sign
    bmi _cmp_neg
    bpl _cmp_pos

_cmp_a_shorter:
    // AL < BL: a has smaller magnitude.
    lda B2
    bmi _cmp_pos
    bpl _cmp_neg

_cmp_sign_diff:
    lda B2
    bmi _cmp_neg
    bpl _cmp_pos

_cmp_same_len:
    // Byte-wise unsigned compare from MSB (index AL-1) downward.
    ldy B0
    dey
_cmp_loop:
    lda (W2),y
    cmp (W3),y
    bne _cmp_byte_diff
    dey
    bpl _cmp_loop
    lda #0
    sta B4
    jmp _cmp_done

_cmp_byte_diff:
    bcs _cmp_pos              // a_byte > b_byte
_cmp_neg:
    lda #$FF
    sta B4
    jmp _cmp_done

_cmp_pos:
    lda #1
    sta B4

_cmp_done:
    lda B4                    // result
    jmp postamble
