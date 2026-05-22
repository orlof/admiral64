// -----------------------------------------------------------------------------
// int_cmp — three-way signed comparison of two fixed 32-bit ints.
//   in:  2 handles on RS — a (deeper), b (top)
//   out: A = $FF (a<b) / $00 (a==b) / $01 (a>b). A survives postamble.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"

int_cmp:
    preamble_args(2, 0)
    rs_peek_at(W0, 1)
    jsr int_load_a               // B0..B3 = a
    rs_peek_at(W1, 0)
    jsr int_load_b               // B4..B7 = b

    // Differing sign bits: the negative one is smaller.
    lda B3
    eor B7
    bpl _cmp_same_sign
    lda B3
    bmi _cmp_lt                  // a negative, b positive → a < b
    bpl _cmp_gt                  // a positive, b negative → a > b

_cmp_same_sign:
    // Same sign → plain unsigned compare, MSB to LSB.
    lda B3
    cmp B7
    bne _cmp_byte
    lda B2
    cmp B6
    bne _cmp_byte
    lda B1
    cmp B5
    bne _cmp_byte
    lda B0
    cmp B4
    bne _cmp_byte
    lda #0                       // all equal
    jmp postamble
_cmp_byte:
    bcs _cmp_gt                  // A >= operand and != → a > b
_cmp_lt:
    lda #$FF
    jmp postamble
_cmp_gt:
    lda #1
    jmp postamble
