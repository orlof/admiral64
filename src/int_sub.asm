// -----------------------------------------------------------------------------
// int_sub — fixed 32-bit subtraction (wraps mod 2^32; no overflow trap).
//   in:  2 handles on RS — a (deeper), b (top)
//   out: RV = a - b (inline int).
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"

int_sub:
    preamble_args(2, 0)
    rs_peek_at(W0, 1)
    jsr int_load_a               // B0..B3 = a
    rs_peek_at(W1, 0)
    jsr int_load_b               // B4..B7 = b
    sec
    lda B0
    sbc B4
    sta B0
    lda B1
    sbc B5
    sta B1
    lda B2
    sbc B6
    sta B2
    lda B3
    sbc B7
    sta B3
    jsr alloc_int_b0
    jmp postamble
