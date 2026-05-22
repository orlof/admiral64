// -----------------------------------------------------------------------------
// int_pow — integer exponentiation base ^ exp via square-and-multiply.
//
//   in:  RS bottom→top: base, exp. Both TYPE_INT.
//   out: RV = base ^ exp (inline int; products wrap mod 2^32).
//
//   exp <  0 → INT_0   (truncating 1/x**|n|)
//   exp == 0 → INT_1
//   else: p=base, r=1; while exp: if exp&1: r*=p; p*=p; exp>>=1
//
// exp's 32-bit magnitude lives in B0..B3 throughout. int_mul preserves the
// caller's B regs across the call (V4' preamble/postamble), so the running
// exponent survives each multiply.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"

int_pow:
    preamble_args(2, 0)
    rs_peek_at(W0, 0)
    jsr int_load_a               // B0..B3 = exp
    lda B3
    bmi _ipow_to_int0            // exp < 0 → 0
    lda B0
    ora B1
    ora B2
    ora B3
    bne _ipow_init
    lda #<INT_1                  // exp == 0 → 1
    ldx #>INT_1
    jmp postamble_set_rv_ax
_ipow_to_int0:
    lda #<INT_0
    ldx #>INT_0
    jmp postamble_set_rv_ax

_ipow_init:
    // RS: [base, exp, r, p].  r = INT_1, p = base.
    rs_push_const(INT_1)
    rs_peek_at(W0, 2)
    rs_push(W0)

_ipow_loop:
    lda B0
    and #1
    beq _ipow_skip
    // r = r * p
    rs_peek_at(W0, 1)            // r
    rs_push(W0)
    rs_peek_at(W0, 1)            // p
    rs_push(W0)
    jsr int_mul                  // RV = r*p
    ldy #2                       // overwrite r slot (depth 1 from RSP)
    lda RV
    sta (RSP),y
    iny
    lda RV+1
    sta (RSP),y
_ipow_skip:
    // p = p * p
    rs_peek(W0)
    rs_push(W0)
    rs_push(W0)
    jsr int_mul                  // RV = p*p
    ldy #0                       // overwrite p slot (top)
    lda RV
    sta (RSP),y
    iny
    lda RV+1
    sta (RSP),y
    // exp >>= 1
    lsr B3
    ror B2
    ror B1
    ror B0
    lda B0
    ora B1
    ora B2
    ora B3
    beq !done+
    jmp _ipow_loop
!done:
    rs_drop(1)                   // drop p
    jmp postamble_pop_rv         // pop r → RV
