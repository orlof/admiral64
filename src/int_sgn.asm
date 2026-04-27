// -----------------------------------------------------------------------------
// int_sgn — return the sign of a signed int.
//
//   in:  handle on RS (top)
//   out: A = $00 (zero) / $01 (positive) / $FF (negative).
//
// A is preserved through postamble so the caller gets the byte directly in A.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

int_sgn:
    preamble_args(1, 0)

    rs_peek(W0)
    jsr deref_W0_to_W2        // W2 = payload, A = length
    tay                        // Y = length
    dey                        // Y = MSB index
    lda (W2),y                 // A = MSB
    bmi _sgn_neg
    bne _sgn_pos

    // MSB == 0. Normalized zero has length 1.
    tya                        // A = Y = length - 1
    bne _sgn_pos               // length > 1 → positive (e.g. [$FF, $00])
    lda #0                     // length == 1 and MSB == 0 → zero
    sta B0
    jmp _sgn_done

_sgn_pos:
    lda #1
    sta B0
    jmp _sgn_done

_sgn_neg:
    lda #$FF
    sta B0

_sgn_done:
    lda B0                     // reload sign into A
    jmp postamble              // preserves A across the restore loop
