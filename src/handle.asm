// -----------------------------------------------------------------------------
// Handle manipulation primitives — shared by routines that operate on
// heap-allocated objects. Called from inside preamble-wrapped routines.
//
// NOTE: these helpers INTENTIONALLY write specific W registers (documented in
// each name) as their output. They do not use preamble/postamble — they are
// "controlled clobbers" used by routines that have already saved caller state
// via preamble and are using the W/B file as scratch.
//
// All heap objects share the layout [len_lo, len_hi, payload ...], so the
// "resolve handle → payload pointer + length" operation is universal.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"

// -----------------------------------------------------------------------------
// deref_{W0,W1,RV}_to_{W2,W3} — resolve a handle to its payload pointer.
//   in:  source ZP register (W0/W1/RV) = handle address
//   out: destination ZP register (W2/W3) = first payload byte
//        A = O_LEN low byte
//        X = O_LEN high byte
//   clobbers: A, X, Y. Destination ZP is the only ZP written.
//
// O_LEN is a 16-bit field: STR/LIST/TUPLE/DICT can exceed 255 elements.
// Callers iterating or comparing must use the (A,X) pair as a word, not just A.
// Old byte-only callers that just `sta B0` still work for objects < 256.
// INT lengths are byte-bounded by design, so byte-only is fine for those.
//
// The two destinations share a tail (`_deref_finish_W{2,3}`) that does the
// O_LEN read + O_HEADER advance. Each entry thunk loads the handle into the
// destination ZP and then jmp's (or falls through) to the matching tail.
// Same idiom as fs_push_w0/w2/w3 just below.
// -----------------------------------------------------------------------------
deref_RV_to_W2:
    ldy #H_PTR
    lda (RV),y
    sta W2
    iny
    lda (RV),y
    sta W2+1
    jmp _deref_finish_W2
deref_W0_to_W2:
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
_deref_finish_W2:
    ldy #O_LEN+1
    lda (W2),y
    tax                              // X = O_LEN high byte
    dey                              // y = O_LEN
    lda (W2),y
    pha                              // stash low byte across W2 += O_HEADER
    lda W2
    clc
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:
    pla                              // A = O_LEN low byte
    rts

deref_W1_to_W3:
    ldy #H_PTR
    lda (W1),y
    sta W3
    iny
    lda (W1),y
    sta W3+1
    jmp _deref_finish_W3
deref_RV_to_W3:
    ldy #H_PTR
    lda (RV),y
    sta W3
    iny
    lda (RV),y
    sta W3+1
    jmp _deref_finish_W3
deref_W0_to_W3:
    ldy #H_PTR
    lda (W0),y
    sta W3
    iny
    lda (W0),y
    sta W3+1
_deref_finish_W3:
    ldy #O_LEN+1
    lda (W3),y
    tax
    dey
    lda (W3),y
    pha
    lda W3
    clc
    adc #O_HEADER
    sta W3
    bcc !+
    inc W3+1
!:
    pla
    rts

// -----------------------------------------------------------------------------
// sign_byte_W2 — extract sign-extension byte for a signed int at W2.
//   in:  A = length of int in bytes, W2 = payload pointer
//   out: A = $00 if MSB bit 7 clear (non-negative), $FF if set (negative)
//   clobbers: A, Y. W2 preserved.
// -----------------------------------------------------------------------------
sign_byte_W2:
    tay
    dey
    lda (W2),y
    and #$80
    beq !+
    lda #$FF
!:  rts

// -----------------------------------------------------------------------------
// sign_byte_W3 — same but for W3.
// -----------------------------------------------------------------------------
sign_byte_W3:
    tay
    dey
    lda (W3),y
    and #$80
    beq !+
    lda #$FF
!:  rts

// -----------------------------------------------------------------------------
// int_to_unsigned_byte_W0 — read a TYPE_INT/TYPE_BOOL handle as an unsigned
// 0..255 byte. Used by builtins that take small bounded ints (screen
// coordinates, char codes, ...) and want to reject negatives + values >= 256
// uniformly without each writing the same length-walk.
//
//   in:  W0 = handle
//   out: C = 1, A = value (0..255)        — non-negative int that fits in a byte
//        C = 0                            — wrong type / negative / value > 255
//   clobbers: A, X, Y, W2.
// -----------------------------------------------------------------------------
int_to_unsigned_byte_W0:
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq _itub_int
    cmp #TYPE_BOOL
    bne _itub_fail
    // BOOL is still a boxed singleton (payload byte 0/1) — deref + read it.
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    sec
    rts
_itub_int:
    // Inline int: bytes 1..3 (high 24 bits) must all be zero, else the value
    // is negative or > 255. Byte 0 is the result.
    ldy #1
    lda (W0),y
    iny
    ora (W0),y
    iny
    ora (W0),y
    bne _itub_fail
    ldy #0
    lda (W0),y
    sec
    rts
_itub_fail:
    clc
    rts

