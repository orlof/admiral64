// -----------------------------------------------------------------------------
// int_add — variable-length signed integer addition.
//
//   in:  2 handles on RS — a (deeper), b (top)
//   out: RV = normalized result handle.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

int_add:
    preamble_args(2, 0)

    // --- Resolve a handle → W2 (payload), B0 (length) ---
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    sta B0                   // B0 = AL

    // --- Resolve b handle → W3 (payload), B1 (length) ---
    rs_peek_at(W1, 0)
    jsr deref_W1_to_W3
    sta B1                   // B1 = BL

    // --- Ensure AL <= BL (swap if needed) ---
    lda B0
    cmp B1
    bcc lengths_ok
    beq lengths_ok
    // Swap W2 <-> W3 (payload pointers), 2 bytes each
    ldx #0
swap_loop:
    lda W2,x
    pha
    lda W3,x
    sta W2,x
    pla
    sta W3,x
    inx
    cpx #2
    bne swap_loop
    // Swap B0 <-> B1 (lengths)
    lda B0
    ldx B1
    sta B1
    stx B0
lengths_ok:

    // --- Precompute sign-extension bytes ---
    lda B0
    jsr sign_byte_W2
    sta B2                   // B2 = AS

    lda B1
    jsr sign_byte_W3
    sta B3                   // B3 = BS

    // --- Precompute phase counters ---
    lda B0
    sta B4                   // B4 = PH1 = AL
    lda B1
    sec
    sbc B0
    sta B5                   // B5 = PH2 = BL - AL

    // --- Allocate result (length = BL + 1) ---
    // alloc_int returns handle in RV, does NOT root on RS. We root immediately.
    lda B1
    clc
    adc #1
    sta ALLOC_SIZE
    lda #0
    adc #0                   // propagate carry from (BL + 1)
    sta ALLOC_SIZE+1
    jsr alloc_int
    rs_push(RV)              // root the new handle

    // Deref the new handle into W0 as payload write pointer. (W2 and W3 are
    // already the source payload pointers.)
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

    // --- Main ADC chain: three phases, carry preserved throughout ---
    ldy #0
    clc

    // Phase 1: both operands real (PH1 iterations).
    ldx B4
    beq skip1
ph1_loop:
    lda (W2),y
    adc (W3),y
    sta (W0),y
    iny
    dex
    bne ph1_loop
skip1:

    // Phase 2: A exhausted, B real (PH2 iterations).
    ldx B5
    beq skip2
ph2_loop:
    lda B2
    adc (W3),y
    sta (W0),y
    iny
    dex
    bne ph2_loop
skip2:

    // Phase 3: both exhausted, 1 iteration.
    lda B2
    adc B3
    sta (W0),y

    // --- Normalize result (consumes RS top; RV ← normalized handle) ---
    jsr int_normalize
    jmp postamble
