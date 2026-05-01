// -----------------------------------------------------------------------------
// int_mul — variable-length signed integer multiplication.
//
// Schoolbook long multiplication, base-256, with an inlined 8×8→16 kernel
// (The Fridge's mult9 — 9-iteration rotate-and-add). Inputs reduced to
// magnitudes via int_negate iff negative, unsigned product computed in
// place, result conditionally negated, finally normalized.
//
//   in:  2 handles on RS — a (deeper), b (top)
//   out: RV = (a * b), fully normalized.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

int_mul:
    preamble_args(2, 0)

    // === Compute a_sign, b_sign, result_sign ===
    rs_peek_at(W0, 1)         // a handle
    jsr deref_W0_to_W2        // W2 = a_payload, A = AL
    jsr sign_byte_W2
    sta B4                    // B4 = a_sign (temp)

    rs_peek_at(W1, 0)         // b handle
    jsr deref_W1_to_W3        // W3 = b_payload, A = BL
    jsr sign_byte_W3
    sta B5                    // B5 = b_sign (temp)

    lda B4
    eor B5
    sta B6                    // B6 = result_sign (only bit 7 matters)

    // === Push ma = |a| onto RS ===
    rs_peek_at(W0, 1)
    lda B4
    bpl ma_pos
    // Negative: a is at RS depth 1; push a copy to top for int_negate, call,
    // then push -a back. int_negate auto-consumes its arg.
    rs_push(W0)
    jsr int_negate
    rs_push(RV)
    jmp ma_done
ma_pos:
    rs_push(W0)               // ma = a (same handle, just repositioned)
ma_done:

    // === Push mb = |b| onto RS ===
    rs_peek_at(W1, 1)         // b now at depth 1 (ma at top)
    lda B5
    bpl mb_pos
    rs_push(W1)
    jsr int_negate
    rs_push(RV)
    jmp mb_done
mb_pos:
    rs_push(W1)
mb_done:

    // RS: [a, b, ma, mb]

    // === Get magnitude lengths & payloads ===
    rs_peek_at(W0, 1)         // ma handle
    jsr deref_W0_to_W2        // W2 = ma_payload, A = AL'
    sta B2                    // B2 = AL'

    rs_peek_at(W1, 0)         // mb handle
    jsr deref_W1_to_W3        // W3 = mb_payload, A = BL'
    sta B3                    // B3 = BL'

    // === Allocate result buffer, size AL' + BL' ===
    // AL'/BL' are each <= 255, so the sum is a 9-bit value — must propagate
    // the carry into ALLOC_SIZE+1 or we'd silently truncate. B5 keeps the low
    // byte only (inner loops still bound-check against a byte counter, which is
    // fine while AL'+BL' < 256; larger results need wider inner-loop counters).
    clc
    lda B2
    adc B3
    sta ALLOC_SIZE
    sta B5                    // B5 = result_len low byte (inner-loop bound)
    lda #0
    adc #0
    sta ALLOC_SIZE+1
    jsr alloc_int             // RV = new handle (NOT rooted yet)
    rs_push(RV)               // root the result buffer

    // Deref RV → W0 (payload write pointer). W2/W3 still hold magnitudes.
    ldy #H_PTR
    lda (RV),y
    sta W0
    iny
    lda (RV),y
    sta W0+1
    clc
    lda W0
    adc #O_HEADER
    sta W0
    bcc !+
    inc W0+1
!:

    // === Zero the result payload ===
    ldy #0
    lda #0
mul_zero:
    sta (W0),y
    iny
    cpy B5
    bne mul_zero

    // Set up pointers for main loop.
    // W2 was ma_payload — save it into W1's slot so we can use W2 as c_ptr+i.
    // Actually: use W0 for c_ptr+i (advances each outer), W1 for mb_payload,
    // and need somewhere for ma_payload. Shuffle:
    //   ma_payload: currently in W2 → move to W1.
    //   mb_payload: currently in W3 → move to W2? No, W3 is fine.
    //   c_payload (write ptr): currently W0 → keep.
    //
    // Roles in main loop:
    //   a[i]     — advance pointer each outer
    //   b[j]     — stable pointer, indexed by Y
    //   c[i+j]   — advance pointer each outer, indexed by Y
    //
    // Plan: W0 = c + i (advances), W2 = ma + i (advances), W3 = mb (stable).
    // Current state: W0 = c_ptr, W2 = ma_payload, W3 = mb_payload. Good — use
    // as-is.

    // === Outer loop: i = 0..AL'-1 ===
    ldx B2                    // X = AL' countdown
    beq mul_done              // AL' = 0 → leave buffer as zeros

mul_outer:
    // Load a[i] (W2 always points at a[i] since advanced each outer).
    ldy #0
    lda (W2),y
    sta B1                    // B1 = multiplier (preserved across mul8x8)

    lda #0
    sta B4                    // B4 = k = 0

    ldy B3
    sty B7                    // B7 = inner countdown (BL')
    beq mul_outer_done        // BL' = 0 guard

    ldy #0                    // j = 0

mul_inner:
    // Load b[j] → B0 (multiplicand, consumed by the inlined mul kernel).
    lda (W3),y
    sta B0

    // Save j across the inlined mul kernel (which uses Y as its counter).
    tya
    pha

    // --- inlined mul8x8 (The Fridge's mult9, 9-iteration rotate-and-add) ---
    // In:  B0 = multiplicand (bit-serially shifted into the result), B1 = multiplier.
    // Out: B0 = product lo, A = product hi. B1 preserved.
    lda #0
    ldy #9
    clc
!loop:
    ror
    ror B0
    bcc !skip+
    clc
    adc B1
!skip:
    dey
    bne !loop-
    // --- end inlined mul8x8 ---
    sta B5                    // B5 = hi (accumulates into new k)

    pla
    tay                       // restore j

    // c[i+j] += lo; carry → B5.
    lda B0
    clc
    adc (W0),y
    sta (W0),y
    bcc !+
    inc B5
!:
    // c[i+j] += k (prev iter carry); carry → B5.
    lda (W0),y
    clc
    adc B4
    sta (W0),y
    bcc !+
    inc B5
!:
    // New k.
    lda B5
    sta B4

    iny
    dec B7
    bne mul_inner

    // Inner done: Y = BL'. Store final k into c[i+BL'].
    lda B4
    sta (W0),y

mul_outer_done:
    // Advance W2 (ma+i) and W0 (c+i) by 1.
    jsr inc_w2_w
    inc W0
    bne !+
    inc W0+1
!:
    dex
    bne mul_outer

mul_done:
    // === Apply result sign ===
    lda B6
    bpl mul_result_positive
    jsr int_negate            // consumes RS top (c), RV = -c (new handle)
    rs_push(RV)               // push -c onto RS for int_normalize
mul_result_positive:

    // === Normalize (consumes RS top) ===
    jsr int_normalize         // RV = final normalized handle

    jmp postamble             // postamble auto-cleans all intermediates
