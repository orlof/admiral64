// -----------------------------------------------------------------------------
// String primitives.
//
// A string is a TYPE_STR heap object. Payload is raw bytes; O_LEN is the
// in-use byte count. No terminator — length is always explicit. Encoding is
// the caller's concern (PETSCII, screen codes, raw bytes — all supported by
// the same allocator). str_alloc is the sole public entry for now.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "preamble.asm"
#import "stacks.asm"
#import "handle.asm"

// -----------------------------------------------------------------------------
// str_alloc — convenience wrapper: alloc() with type = TYPE_STR.
//   in:  ALLOC_SIZE (word) preset by caller
//   out: RV = new string handle. OOM is a fatal panic, not a return value.
//
// Payload bytes are unspecified on entry — the caller must fill them before
// the string is handed off as a logical value. O_LEN is preset to ALLOC_SIZE
// by alloc (fully-used by default). If the caller over-allocates, it must
// overwrite O_LEN to reflect the actual used count.
// -----------------------------------------------------------------------------
str_alloc:
    lda #TYPE_STR
    sta ALLOC_TYPE
    jmp alloc

// -----------------------------------------------------------------------------
// str_alloc_1_b0 — allocate a 1-byte TYPE_STR with payload[0] = B0.
//   in:  B0 = byte value to write into the string
//   out: RV = new TYPE_STR handle.
//   clobbers: A, X, Y, W2. (B0 preserved.)
// -----------------------------------------------------------------------------
str_alloc_1_b0:
    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr str_alloc
    jsr deref_RV_to_W2
    lda B0
    ldy #0
    sta (W2),y
    rts

// -----------------------------------------------------------------------------
// str_find_pos — substring search returning a position. Both operands must
// be TYPE_STR; the caller is expected to type-check and panic otherwise.
//
// in:  RS — needle (deeper), haystack (top).
//      B5 = inclusive start offset (0 for full-range search).
//      B6 = exclusive end offset; sentinel $FF means "to end of haystack"
//           (clamped to haystack_len internally).
// out: A = position (0..254) of the first occurrence of `needle` in
//      `haystack[B5..B6]`, or $FF (= -1 signed) if not found. Args consumed.
//
// An empty needle is "found" at the (clamped) start position — matches
// Python `"abc".find("", 1)` = 1. Limits: 8-bit positions, so haystack ≤
// 254 bytes for any non-empty match (255 stays reserved for "not found").
// V4'.
// -----------------------------------------------------------------------------
str_find_pos:
    preamble_args(2, 0)

    // Haystack length first so we can clamp B6 ($FF sentinel → len).
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    sta B1                            // B1 = haystack len, W2 = haystack payload

    lda B6
    cmp #$FF
    beq _sfp_clamp_end
    cmp B1
    bcc _sfp_end_ok
_sfp_clamp_end:
    lda B1
    sta B6
_sfp_end_ok:
    // Clamp B5 (start) to B6.
    lda B5
    cmp B6
    bcc _sfp_start_ok
    lda B6
    sta B5
_sfp_start_ok:

    // Needle: B0 = len, W3 = payload base.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    sta B0
    lda W2
    sta W3
    lda W2+1
    sta W3+1

    // Empty needle → return clamped start.
    lda B0
    bne _sfp_have_needle
    lda B5
    jmp postamble
_sfp_have_needle:

    // Re-deref haystack — needle deref clobbered W2.
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2

    // max start offset (inclusive) = B6 - B0. If underflow, not found.
    sec
    lda B6
    sbc B0
    bcc _sfp_not_found
    sta B2

    // Initial outer offset = B5; if B5 > B2 the match can't fit in window.
    lda B5
    cmp B2
    beq _sfp_outer_init
    bcs _sfp_not_found
_sfp_outer_init:
    sta B3                            // B3 = current outer offset

_sfp_outer:
    ldy #0                            // Y = inner index into needle
_sfp_inner:
    cpy B0
    beq _sfp_match
    lda (W3),y                        // needle[Y]
    sta B4
    tya
    clc
    adc B3
    tay                               // Y = haystack offset
    lda (W2),y
    cmp B4
    bne _sfp_advance
    // Match — recover original Y (= Y - B3) and continue.
    tya
    sec
    sbc B3
    tay
    iny
    bne _sfp_inner
_sfp_advance:
    inc B3
    lda B3
    cmp B2
    beq _sfp_outer
    bcc _sfp_outer
    // fallthrough: exhausted, not found
_sfp_not_found:
    lda #$FF
    jmp postamble

_sfp_match:
    lda B3                            // matched position
    jmp postamble
