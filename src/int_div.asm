// -----------------------------------------------------------------------------
// int_div(a, b) — truncating signed quotient.
//
//   in:  2 handles on RS — a (deeper), b (top)
//   out: RV = (a / b), normalized.
//
// Thin wrapper around int_divmod; discards the remainder half of the result.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

int_div:
    preamble_args(2, 0)
    jsr int_divmod               // consumes a,b; RV=q, RV2=r
    // RV already holds q. RV2 unused by caller; handle will be collected at
    // next GC since no RS root anchors it.
    jmp postamble
