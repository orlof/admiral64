// -----------------------------------------------------------------------------
// int_negate — variable-length signed integer negation (two's complement).
// Computes 0 - input via SBC chain. Result length = input + 1 so -INT_MIN fits.
//
//   in:  handle on RS (top)
//   out: RV = normalized result handle.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

int_negate:
    preamble_args(1, 0)

    // --- Resolve input handle → W2 (payload), B0 (length) ---
    rs_peek(W0)
    jsr deref_W0_to_W2
    sta B0                    // B0 = AL

    // --- Sign-extension byte into B1 ---
    lda B0
    jsr sign_byte_W2
    sta B1                    // B1 = AS

    // --- Allocate result (length = AL + 1) ---
    lda B0
    clc
    adc #1
    sta ALLOC_SIZE
    lda #0
    adc #0                    // propagate carry from (AL + 1)
    sta ALLOC_SIZE+1
    jsr alloc_int             // RV = new handle (NOT rooted)
    rs_push(RV)               // root it — int_normalize (called later) doesn't
                              // alloc, but keep the discipline uniform.

    // --- Deref new handle to get payload pointer in W3 ---
    // (W2 holds the source payload; deref RV→W3 leaves W2 untouched.)
    jsr deref_RV_to_W3

    // --- Compute 0 - input into (W3),y via SBC chain ---
    sec                       // initial C=1 (no borrow)
    ldy #0
    ldx B0
    beq negate_final
negate_loop:
    lda #0
    sbc (W2),y
    sta (W3),y
    iny
    dex
    bne negate_loop
negate_final:
    // Final byte: 0 - AS - borrow.
    lda #0
    sbc B1
    sta (W3),y

    // --- Normalize the new handle (currently on RS top) ---
    jsr int_normalize         // consumes top, RV = normalized handle
    jmp postamble
