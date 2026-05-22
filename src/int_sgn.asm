// -----------------------------------------------------------------------------
// int_sgn — sign of a fixed 32-bit int.
//   in:  handle on RS (top)
//   out: A = $00 (zero) / $01 (positive) / $FF (negative). A survives postamble.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"

int_sgn:
    preamble_args(1, 0)
    rs_peek(W0)
    jsr int_load_a               // B0..B3 = value
    lda B3
    bmi _sgn_neg
    lda B0
    ora B1
    ora B2
    ora B3
    beq _sgn_zero
    lda #1
    jmp postamble
_sgn_zero:
    lda #0
    jmp postamble
_sgn_neg:
    lda #$FF
    jmp postamble
