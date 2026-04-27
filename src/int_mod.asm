// -----------------------------------------------------------------------------
// int_mod(a, b) — truncating signed remainder.
//
//   in:  2 handles on RS — a (deeper), b (top)
//   out: RV = (a % b), normalized. sign(r) == sign(a).
//
// Thin wrapper around int_divmod; discards the quotient and promotes the
// remainder from RV2 into RV.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

int_mod:
    preamble_args(2, 0)
    jsr int_divmod               // consumes a,b; RV=q, RV2=r
    lda RV2
    sta RV
    lda RV2+1
    sta RV+1
    jmp postamble
