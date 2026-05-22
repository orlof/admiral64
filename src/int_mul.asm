// -----------------------------------------------------------------------------
// int_mul — fixed 32-bit multiplication, low 32 bits (wraps; no overflow trap).
//
//   in:  2 handles on RS — a (deeper), b (top)
//   out: RV = (a * b) mod 2^32 (inline int).
//
// Bit-serial shift-add: 32 iterations of "if (b&1) result += a; a <<= 1;
// b >>= 1". Two's-complement low bits are sign-agnostic, so no sign handling
// is needed. Result accumulates in W0:W1 ($10..$13), then moves to B0..B3.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"

int_mul:
    preamble_args(2, 0)
    rs_peek_at(W0, 1)
    jsr int_load_a               // B0..B3 = a (multiplicand, shifts left)
    rs_peek_at(W1, 0)
    jsr int_load_b               // B4..B7 = b (multiplier, shifts right)

    // result = 0  (W0:W1 = $10..$13)
    lda #0
    sta W0
    sta W0+1
    sta W1
    sta W1+1

    ldy #32
_mul_loop:
    lda B4
    and #1
    beq _mul_noadd
    clc
    lda W0
    adc B0
    sta W0
    lda W0+1
    adc B1
    sta W0+1
    lda W1
    adc B2
    sta W1
    lda W1+1
    adc B3
    sta W1+1
_mul_noadd:
    asl B0                       // a <<= 1
    rol B1
    rol B2
    rol B3
    lsr B7                       // b >>= 1 (logical)
    ror B6
    ror B5
    ror B4
    dey
    bne _mul_loop

    lda W0                       // result → B0..B3
    sta B0
    lda W0+1
    sta B1
    lda W1
    sta B2
    lda W1+1
    sta B3
    jsr alloc_int_b0
    jmp postamble
