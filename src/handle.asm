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
// deref_W0_to_W2 — resolve handle in W0 to its payload pointer in W2.
//   in:  W0 = handle address
//   out: W2 = address of first payload byte (past the length header)
//        A  = length low byte (high byte unused for now; < 256-byte objects)
//   clobbers: A, X, Y. W2 written (intentional output).
// -----------------------------------------------------------------------------
deref_W0_to_W2:
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    tax                    // stash length while advancing W2
    lda W2
    clc
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:
    txa                    // return length in A
    rts

// -----------------------------------------------------------------------------
// deref_W1_to_W3 — same but for second-operand handles.
// -----------------------------------------------------------------------------
deref_W1_to_W3:
    ldy #H_PTR
    lda (W1),y
    sta W3
    iny
    lda (W1),y
    sta W3+1
    ldy #O_LEN
    lda (W3),y
    tax
    lda W3
    clc
    adc #O_HEADER
    sta W3
    bcc !+
    inc W3+1
!:
    txa
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
// deref_RV_to_W2 — resolve the handle in RV to its payload pointer in W2.
// Companion to deref_W0_to_W2 for the common "just got handle from alloc_int
// returned in RV" pattern.
//   in:  RV = handle address
//   out: W2 = first payload byte (past the length header)
//        A  = length low byte
//   clobbers: A, X, Y. W2 written (intentional output). RV preserved.
// -----------------------------------------------------------------------------
deref_RV_to_W2:
    ldy #H_PTR
    lda (RV),y
    sta W2
    iny
    lda (RV),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    tax
    lda W2
    clc
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:
    txa
    rts
