// -----------------------------------------------------------------------------
// int_sub(a, b) = int_add(a, int_negate(b))
//
//   in:  2 handles on RS — a (deeper), b (top)
//   out: RV = (a - b), fully normalized.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

int_sub:
    preamble_args(2, 0)

    // int_negate consumes RS top (b), returns -b in RV. RS: [a].
    jsr int_negate

    // Push -b back onto RS so int_add sees [a, -b].
    rs_push(RV)

    // int_add consumes top 2; RV = a - b.
    jsr int_add

    jmp postamble
