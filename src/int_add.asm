// -----------------------------------------------------------------------------
// int_add — fixed 32-bit addition (wraps mod 2^32; no overflow trap).
//   in:  2 handles on RS — a (deeper), b (top)
//   out: RV = a + b (inline int).
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"

int_add:
    preamble_args(2, 0)
    rs_peek_at(W0, 1)
    jsr int_load_a               // B0..B3 = a
    rs_peek_at(W1, 0)
    jsr int_load_b               // B4..B7 = b
    clc
    lda B0
    adc B4
    sta B0
    lda B1
    adc B5
    sta B1
    lda B2
    adc B6
    sta B2
    lda B3
    adc B7
    sta B3
    jsr alloc_int_b0
    jmp postamble
