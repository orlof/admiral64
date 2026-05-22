// -----------------------------------------------------------------------------
// int_negate — fixed 32-bit two's-complement negation.
//   in:  handle on RS (top)
//   out: RV = -value (inline int). Negating INT_MIN wraps to itself (standard
//        two's-complement; no overflow trap).
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"

int_negate:
    preamble_args(1, 0)
    rs_peek(W0)
    jsr int_load_a               // B0..B3 = value
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
    jsr alloc_int_b0
    jmp postamble
