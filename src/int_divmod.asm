// -----------------------------------------------------------------------------
// int_divmod — signed integer long division returning BOTH quotient and
// remainder. Truncating (C/Java) semantics:
//
//     sign(q) = sign(a) XOR sign(b)
//     sign(r) = sign(a)
//     (a / b) * b + (a % b) == a
//
//   in:  2 handles on RS — a (dividend, deeper), b (divisor, top)
//   out: RV  = signed quotient handle (normalized)
//        RV2 = signed remainder handle (normalized)
//
// Division by zero panics via error_handler with ERR_DIV_ZERO.
//
// Algorithm: restoring long division, bit-by-bit from the MSB of |a|. At each
// step, shift the running remainder R left by one, OR in the next bit of |a|,
// compare to |b|, and if R >= |b| subtract and set the corresponding bit of Q.
// After AL'·8 iterations, Q = |q|, R = |r|. Then apply signs.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

int_divmod:
    preamble_args(2, 0)

    // --- Check divisor for zero ---
    rs_peek(W1)                  // b handle (top)
    jsr deref_W1_to_W3           // W3 = b payload, A = BL
    cmp #1
    bne div_b_nonzero
    ldy #0
    lda (W3),y
    bne div_b_nonzero
    jmp panic_div_zero
div_b_nonzero:

    // --- Signs of a and b ---
    rs_peek_at(W0, 1)            // a handle
    jsr deref_W0_to_W2
    jsr sign_byte_W2
    sta B4                       // sign_a

    rs_peek(W1)                  // b handle
    jsr deref_W1_to_W3
    jsr sign_byte_W3
    sta B5                       // sign_b (used only to compute sign_q)

    lda B4
    eor B5
    sta B6                       // sign_q = sign_a XOR sign_b

    // --- Push |a| onto RS (stays rooted across subsequent allocs) ---
    rs_peek_at(W0, 1)
    lda B4
    bpl div_ma_pos
    rs_push(W0)
    jsr int_negate               // consumes top; RV = -a
    rs_push(RV)
    jmp div_ma_done
div_ma_pos:
    rs_push(W0)
div_ma_done:

    // --- Push |b| onto RS ---
    rs_peek_at(W1, 1)            // b now at depth 1 (ma at top)
    lda B5
    bpl div_mb_pos
    rs_push(W1)
    jsr int_negate
    rs_push(RV)
    jmp div_mb_done
div_mb_pos:
    rs_push(W1)
div_mb_done:

    // RS: [a, b, ma, mb]

    // --- Fetch magnitude lengths ---
    rs_peek_at(W0, 1)            // ma
    jsr deref_W0_to_W2
    sta B2                       // AL'

    rs_peek(W1)                  // mb (top)
    jsr deref_W1_to_W3
    sta B3                       // BL'

    // --- Allocate Q buffer (AL' + 1 bytes, zeroed via inline fill) ---
    lda B2
    clc
    adc #1
    sta ALLOC_SIZE
    lda #0
    adc #0
    sta ALLOC_SIZE+1
    jsr alloc_int
    rs_push(RV)                  // root Q

    // --- Allocate R buffer (BL' + 1 bytes) ---
    lda B3
    clc
    adc #1
    sta ALLOC_SIZE
    lda #0
    adc #0
    sta ALLOC_SIZE+1
    jsr alloc_int
    rs_push(RV)                  // root R

    // RS: [a, b, ma, mb, Q, R]

    // --- Re-deref all four payloads (compact may have moved data) ---
    // Target: W0 = Q payload, W1 = R payload, W2 = ma payload, W3 = mb payload.
    rs_peek_at(W0, 3)            // ma
    jsr deref_W0_to_W2           // W2 = ma payload
    rs_peek_at(W1, 2)            // mb
    jsr deref_W1_to_W3           // W3 = mb payload

    // Deref Q to W0 (inline — the W0->W2 helper would clobber ma payload).
    rs_peek_at(W0, 1)            // W0 = Q handle
    ldy #H_PTR
    lda (W0),y
    pha
    iny
    lda (W0),y
    sta W0+1
    pla
    sta W0
    clc
    lda W0
    adc #O_HEADER
    sta W0
    bcc !+
    inc W0+1
!:

    // Deref R to W1 (inline).
    rs_peek(W1)                  // W1 = R handle
    ldy #H_PTR
    lda (W1),y
    pha
    iny
    lda (W1),y
    sta W1+1
    pla
    sta W1
    clc
    lda W1
    adc #O_HEADER
    sta W1
    bcc !+
    inc W1+1
!:

    // --- Zero Q (AL' + 1 bytes) ---
    lda B2
    clc
    adc #1
    sta B5                       // Q length (temp)
    ldy #0
    lda #0
zero_q:
    sta (W0),y
    iny
    cpy B5
    bne zero_q

    // --- Zero R (BL' + 1 bytes), remember length in B7 ---
    lda B3
    clc
    adc #1
    sta B7                       // R working length (used during shift/compare)
    ldy #0
    lda #0
zero_r:
    sta (W1),y
    iny
    cpy B7
    bne zero_r

    // --- Long-division main loop ---
    // X   = outer byte index (AL'-1 down to 0)
    // B0  = current a-byte (ma[X])
    // B1  = bit mask ($80 → $40 → ... → $01)
    // B5  = inner bit counter (8 → 1)
    //
    // ma=W2, mb=W3, Q=W0, R=W1, BL'=B3, R_len=B7.
    //
    // Per bit:
    //   R <<= 1 (with OR-in of current bit of a)
    //   if R >= mb: R -= mb; Q[X] |= B1
    ldx B2
    dex                          // X = AL' - 1
    bmi div_done                 // AL'=0 means zero dividend; already zeroed buffers
div_outer:
    txa
    tay
    lda (W2),y
    sta B0                       // B0 = ma[X]

    lda #$80
    sta B1
    lda #8
    sta B5

div_inner:
    // Shift R left by 1 via R += R — carry chains across bytes, so the inner
    // loop terminator must not touch C. X serves as the byte counter (dex
    // preserves C); the outer byte-index X is stashed on HW stack.
    clc
    ldy #0
    txa
    pha
    ldx B7
shift_loop:
    lda (W1),y
    adc (W1),y
    sta (W1),y
    iny
    dex
    bne shift_loop
    pla
    tax

    // OR in current bit of a (if set).
    lda B0
    and B1
    beq no_bit
    ldy #0
    lda (W1),y
    ora #$01
    sta (W1),y
no_bit:

    // Compare R vs mb (unsigned, BL'+1 bytes vs BL' bytes).
    //   If R[BL'] != 0 → R > mb (top byte is beyond mb's range).
    //   Else compare bytes BL'-1 down to 0.
    ldy B3                       // Y = BL'
    lda (W1),y
    bne ge_branch
    dey
    bmi ge_branch                // BL'=0 degenerate → treat as GE
cmp_loop:
    lda (W1),y
    cmp (W3),y
    bne cmp_settled
    dey
    bpl cmp_loop
    // All bytes equal → GE.
    jmp ge_branch
cmp_settled:
    bcc next_bit                 // R[y] < mb[y] → LT, skip subtract

ge_branch:
    // R -= mb — borrow chains, so same pattern as the shift loop: X counts
    // bytes (dex preserves C), outer byte-index X is stashed on HW stack.
    sec
    ldy #0
    txa
    pha
    ldx B3
sub_loop:
    lda (W1),y
    sbc (W3),y
    sta (W1),y
    iny
    dex
    bne sub_loop
    // Top byte of R: subtract borrow.
    lda (W1),y
    sbc #0
    sta (W1),y
    pla
    tax

    // Set bit in Q[X].
    txa
    tay
    lda (W0),y
    ora B1
    sta (W0),y

next_bit:
    lsr B1                       // mask >>= 1
    dec B5
    bne div_inner

    dex
    bpl div_outer

div_done:
    // RS: [a, b, ma, mb, Q, R]
    // Q and R are raw unsigned magnitudes.

    // --- Apply sign to R (top of stack) ---
    // sign(r) = sign(a), which is B4.
    lda B4
    bpl r_sign_done
    jsr int_negate               // consumes R on top; RV = -R
    rs_push(RV)                  // re-root
r_sign_done:

    // --- Normalize R ---
    jsr int_normalize            // consumes top; RV = normalized
    rs_push(RV)                  // RS: [..., Q, R_final]

    // --- Apply sign to Q ---
    // Q is at depth 1 (R_final on top). Duplicate Q onto top, negate or keep,
    // normalize, leaving [..., Q_raw, R_final, Q_final].
    rs_peek_at(W0, 1)            // W0 = Q handle
    rs_push(W0)                  // duplicate Q to top

    lda B6                       // sign_q
    bpl q_sign_done
    jsr int_negate               // consumes top dup; RV = -Q
    rs_push(RV)
q_sign_done:

    // --- Normalize Q ---
    jsr int_normalize            // consumes top; RV = Q_final
    rs_push(RV)                  // RS: [..., Q_raw, R_final, Q_final]

    // --- Harvest both handles into RV / RV2 ---
    // No allocating sub-calls follow, so the brief window where both are only
    // referenced via W0 / W1 is safe.
    rs_pop(W0)                   // Q_final
    rs_pop(W1)                   // R_final

    lda W0
    sta RV
    lda W0+1
    sta RV+1
    lda W1
    sta RV2
    lda W1+1
    sta RV2+1

    jmp postamble
