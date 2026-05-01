// -----------------------------------------------------------------------------
// int_parse_* — parse a span of digit bytes (decimal / hex / binary) into a
// fresh TYPE_INT handle. Used by Stage 8's TK_INT / TK_HEX / TK_BIN NUDs.
//
// All entry points take:
//   in:  W0 = absolute pointer to first digit byte
//        A  = byte length of the digit span (1..255)
//   out: RV = TYPE_INT handle
//
// Algorithm: iterate the span left-to-right. Maintain a running result on
// RS. For each digit:
//   - multiply running result by the base (10/16/2)
//   - add the digit value
// `int_mul` and `int_add` allocate fresh handles per step, leaving the
// previous result as garbage. The next gc_collect reclaims it.
//
// Cost: O(N) handles allocated for an N-digit input. Acceptable until we
// see real hot paths through here.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

// -----------------------------------------------------------------------------
// int_parse_dec — parse a decimal digit span. Caller must guarantee every
// byte in the span is in '0'..'9'.
// -----------------------------------------------------------------------------
int_parse_dec:
    preamble_args(0, 0)
    sta B0                       // B0 = length

    // Initial running result = INT_0 (static).
    rs_push_const(INT_0)

    lda #0
    sta B1                       // B1 = digit index

_ipd_loop:
    lda B1
    cmp B0
    bne !go+
    jmp _ipd_done
!go:

    // running *= 10
    rs_push_const(INT_10)
    jsr int_mul                  // consumes 2 args, RV = product
    rs_push(RV)

    // Read digit char at offset B1.
    ldy B1
    lda (W0),y
    sec
    sbc #'0'                     // 0..9
    sta B2

    // Allocate a 1-byte int and write the digit value to its payload.
    lda #1
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2
    lda B2
    ldy #0
    sta (W2),y

    // running += digit
    rs_push(RV)
    jsr int_add
    rs_push(RV)

    inc B1
    jmp _ipd_loop

_ipd_done:
    jmp postamble_pop_rv

// -----------------------------------------------------------------------------
// int_parse_hex — parse "0xNN" or "0XNN". Span must include the "0x" prefix
// (matches the lexer's TK_HEX span). Body chars must be 0-9, a-f, A-F.
// -----------------------------------------------------------------------------
int_parse_hex:
    preamble_args(0, 0)
    sta B0                       // B0 = full span length (incl. "0x")

    rs_push_const(INT_0)

    lda #2
    sta B1                       // start past the "0x" / "0X" prefix

_iph_loop:
    lda B1
    cmp B0
    bne !go+
    jmp _iph_done
!go:

    // running *= 16
    rs_push_const(INT_16_STATIC)
    jsr int_mul
    rs_push(RV)

    // Decode hex digit at (W0)+B1.
    ldy B1
    lda (W0),y
    // 0..9 → digit. A-F → digit + 10. a-f → digit + 10.
    cmp #'9'+1
    bcs _iph_alpha
    sec
    sbc #'0'
    jmp _iph_have
_iph_alpha:
    cmp #$61                     // 'a'
    bcs _iph_lower
    // uppercase A-F
    sec
    sbc #$41                     // 'A'
    clc
    adc #10
    jmp _iph_have
_iph_lower:
    sec
    sbc #$61                     // 'a'
    clc
    adc #10
_iph_have:
    sta B2

    lda #1
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2
    lda B2
    ldy #0
    sta (W2),y

    rs_push(RV)
    jsr int_add
    rs_push(RV)

    inc B1
    jmp _iph_loop

_iph_done:
    jmp postamble_pop_rv

// -----------------------------------------------------------------------------
// int_parse_bin — parse "0bNN" or "0BNN". Body chars must be '0' or '1'.
// -----------------------------------------------------------------------------
int_parse_bin:
    preamble_args(0, 0)
    sta B0

    rs_push_const(INT_0)

    lda #2
    sta B1

_ipb_loop:
    lda B1
    cmp B0
    bne !go+
    jmp _ipb_done
!go:

    // running *= 2
    rs_push_const(INT_2_STATIC)
    jsr int_mul
    rs_push(RV)

    ldy B1
    lda (W0),y
    sec
    sbc #'0'                     // 0 or 1
    sta B2

    lda #1
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2
    lda B2
    ldy #0
    sta (W2),y

    rs_push(RV)
    jsr int_add
    rs_push(RV)

    inc B1
    jmp _ipb_loop

_ipb_done:
    jmp postamble_pop_rv

// -----------------------------------------------------------------------------
// Static int singletons used by the parsers above. Kept here (close to the
// only callers) rather than in statics.asm — they're parser-internal.
// -----------------------------------------------------------------------------
INT_2_STATIC:
    .word INT_2_STATIC_OBJ
    .word 3
    .word 0
    .byte TYPE_INT
    .byte 0
INT_2_STATIC_OBJ:
    .word 1
    .byte 2

INT_16_STATIC:
    .word INT_16_STATIC_OBJ
    .word 3
    .word 0
    .byte TYPE_INT
    .byte 0
INT_16_STATIC_OBJ:
    .word 1
    .byte 16
