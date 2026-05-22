// -----------------------------------------------------------------------------
// int_to_str — render a fixed 32-bit signed int as a decimal byte string.
//
//   in:  1 handle on RS (top)
//   out: RV = TYPE_STR handle with the ASCII decimal representation.
//
// Magnitude held in B0..B3. Digits extracted LSB-first by repeated 32-bit
// divide-by-10 (_div10), pushed onto the FS byte-stack; then drained back
// (LIFO → MSB-first) into an exact-size string. Sign in B5, count in B4.
// No per-digit heap allocation. Zero falls out naturally (one '0').
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"
#import "handle.asm"

int_to_str:
    preamble_args(1, 0)
    rs_peek(W0)
    jsr int_load_a               // B0..B3 = value

    // Sign → B5; negate to magnitude if negative.
    lda B3
    bpl _i2s_pos
    lda #$FF
    sta B5
    sec
    lda #0
    sbc B0
    sta B0
    lda #0
    sbc B1
    sta B1
    lda #0
    sbc B2
    sta B2
    lda #0
    sbc B3
    sta B3
    jmp _i2s_digits
_i2s_pos:
    lda #0
    sta B5

_i2s_digits:
    lda #0
    sta B4                       // digit count
_i2s_dloop:
    jsr _div10                   // A = digit (0..9), B0..B3 = quotient
    clc
    adc #'0'
    fs_push_byte()
    inc B4
    lda B0
    ora B1
    ora B2
    ora B3
    bne _i2s_dloop

    // Leading '-' for negatives.
    lda B5
    beq _i2s_nosign
    lda #'-'
    fs_push_byte()
    inc B4
_i2s_nosign:

    // Allocate an exact-size TYPE_STR.
    lda B4
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                    // RV = string handle
    jsr deref_RV_to_W2           // W2 = payload pointer

    // Drain B4 bytes off the FS byte-stack (top→bottom) into the payload.
_i2s_drain:
    lda B4
    beq _i2s_done
    jsr fs_pop_byte_call         // A = byte, Y clobbered
    ldy #0
    sta (W2),y
    inc W2
    bne !+
    inc W2+1
!:
    dec B4
    jmp _i2s_drain
_i2s_done:
    // RV still holds the string handle (untouched since alloc).
    jmp postamble

// -----------------------------------------------------------------------------
// _div10 — divide the unsigned 32-bit value in B0..B3 by 10 in place.
//   out: B0..B3 = quotient, A = remainder (0..9). Clobbers X.
// -----------------------------------------------------------------------------
_div10:
    ldx #32
    lda #0                       // running remainder
_d10_loop:
    asl B0
    rol B1
    rol B2
    rol B3
    rol                          // remainder = (remainder<<1) | carry-out
    cmp #10
    bcc _d10_skip
    sbc #10                      // C already set
    inc B0                       // set quotient bit 0
_d10_skip:
    dex
    bne _d10_loop
    rts
