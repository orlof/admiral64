// -----------------------------------------------------------------------------
// int_pow — integer exponentiation: result = base ^ exp.  Square-and-multiply.
//
//   in:   RS bottom→top: base, exp. Both TYPE_INT handles.
//   out:  RV = TYPE_INT handle holding base ^ exp.
//
// Algorithm (mirrors Admiral src/integer.dasm16:860):
//   if exp <  0 → return INT_0  (truncating integer division of 1/x**|n|)
//   if exp == 0 → return INT_1
//   p = base, r = 1
//   while exp != 0:
//     if (exp & 1): r = r * p
//     p = p * p
//     exp >>= 1
//   return r
//
// O(log N) multiplications — for `x ** 100` we do ~14 muls vs naive's 100.
//
// Exponent is read as a 16-bit value (low 2 payload bytes). Negative
// exponents are detected via the sign bit of the highest payload byte.
// Exponents > 65535 are truncated to their low 16 bits — real workloads
// don't hit this; documented limitation.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

int_pow:
    preamble_args(2, 0)

    // --- Read exp's sign + low 16 bits. ---
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2          // W2 = exp payload, A = O_LEN
    sta B0                       // B0 = exp byte length

    // Sign byte = MSB of last payload byte. If bit 7 set → exp negative.
    ldy B0
    dey
    lda (W2),y
    bmi _ipow_to_int0

    // Magnitude: B1 = exp[0] (low), B2 = exp[1] (high) or 0 if 1-byte.
    ldy #0
    lda (W2),y
    sta B1
    lda B0
    cmp #2
    bcc _ipow_one_byte
    iny
    lda (W2),y
    sta B2
    jmp _ipow_have_mag
_ipow_one_byte:
    lda #0
    sta B2
_ipow_have_mag:

    // exp == 0 → INT_1.
    lda B1
    ora B2
    bne _ipow_init
    lda #<INT_1
    ldx #>INT_1
    jmp postamble_set_rv_ax

_ipow_to_int0:
    lda #<INT_0
    ldx #>INT_0
    jmp postamble_set_rv_ax

_ipow_init:
    // RS layout we maintain through the loop: [base, exp, r, p].
    // r starts as INT_1 (static); p starts as base.
    rs_push_const(INT_1)         // RS: [base, exp, r]
    rs_peek_at(W0, 2)            // W0 = base
    rs_push(W0)                  // RS: [base, exp, r, p=base]

_ipow_loop:
    // If exp's low bit set → r = r * p.
    lda B1
    and #1
    beq _ipow_skip

    // Push (r, p) as args for int_mul. RS now: [base, exp, r, p].
    rs_peek_at(W0, 1)            // W0 = r
    rs_push(W0)                  // RS: [..., r, p, r_copy]
    rs_peek_at(W0, 1)            // W0 = p (slot 1 from top after the push)
    rs_push(W0)                  // RS: [..., r, p, r_copy, p_copy]
    jsr int_mul                  // consumes 2 → RV = r*p. RS: [..., r, p].

    // Overwrite r (slot 1) with the new product. RSP currently points at p.
    ldy #2
    lda RV
    sta (RSP),y
    iny
    lda RV+1
    sta (RSP),y

_ipow_skip:
    // p = p * p. Top of RS is p; push two copies for int_mul.
    rs_peek(W0)
    rs_push(W0)
    rs_push(W0)
    jsr int_mul                  // RV = p*p. RS: [base, exp, r, p].

    // Overwrite p (slot 0).
    ldy #0
    lda RV
    sta (RSP),y
    iny
    lda RV+1
    sta (RSP),y

    // exp >>= 1
    lsr B2
    ror B1

    // exp == 0?
    lda B1
    ora B2
    beq !done+
    jmp _ipow_loop
!done:

    // Done. Pop p (discard), pop r into RV.
    rs_drop(1)
    jmp postamble_pop_rv
