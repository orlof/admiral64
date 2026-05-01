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
//      B4:B5 = inclusive start offset (word; 0 for full-range search).
//      B6:B7 = exclusive end offset (word); $FFFF sentinel means
//              "to end of haystack" (clamped to haystack_len internally).
// out: RV = position (0..0xFFFE, word) of the first occurrence of `needle`
//      in `haystack[start..end_excl]`, or $FFFF if not found. Args consumed.
//
// An empty needle is "found" at the (clamped) start position — matches
// Python `"abc".find("", 1)` = 1. Needle byte length must be < 256
// (practical search patterns are tiny); haystack length is fully 16-bit.
// V4'.
// -----------------------------------------------------------------------------
str_find_pos:
    preamble_args(2, 0)

    // Haystack length word → B2:B3, then clamp B6:B7 ($FFFF sentinel → len).
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2                // A:X = O_LEN word, W2 = haystack payload
    sta B2
    stx B3

    // If end_excl > haystack_len, clamp to haystack_len. ($FFFF sentinel
    // is the canonical "way too big" — same path.)
    lda B2
    cmp B6
    lda B3
    sbc B7
    bcs _sfp_end_ok                   // haystack_len >= end_excl
    lda B2
    sta B6
    lda B3
    sta B7
_sfp_end_ok:
    // Clamp start (B4:B5) to end_excl (B6:B7).
    lda B6
    cmp B4
    lda B7
    sbc B5
    bcs _sfp_start_ok                 // end_excl >= start
    lda B6
    sta B4
    lda B7
    sta B5
_sfp_start_ok:

    // Needle: B0:B1 = len word, W3 = payload base.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    sta B0
    stx B1
    lda W2
    sta W3
    lda W2+1
    sta W3+1

    // Empty needle → return clamped start.
    lda B0
    ora B1
    bne _sfp_have_needle
    lda B4
    sta RV
    lda B5
    sta RV+1
    jmp postamble
_sfp_have_needle:
    // Cap needle at < 256 bytes. (Search patterns are short — Y is an 8-bit
    // index in the inner loop. A pathological case panics with not-found
    // rather than misbehaving.)
    lda B1
    bne _sfp_not_found

    // Re-deref haystack — needle deref clobbered W2.
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2

    // max_start (inclusive) = end_excl - needle_len → B2:B3. If underflow
    // (needle_len > end_excl), not found.
    sec
    lda B6
    sbc B0
    sta B2
    lda B7
    sbc B1
    sta B3
    bcc _sfp_not_found

    // If start (B4:B5) > max_start (B2:B3), can't fit any match.
    lda B2
    cmp B4
    lda B3
    sbc B5
    bcs _sfp_outer                    // max_start >= start → ok
    jmp _sfp_not_found

_sfp_outer:
    // hp_at_outer = W2 + B4:B5 → W0.
    clc
    lda W2
    adc B4
    sta W0
    lda W2+1
    adc B5
    sta W0+1

    ldy #0
_sfp_inner:
    cpy B0                            // Y == needle_len? (B0 < 256 guaranteed)
    beq _sfp_match
    lda (W3),y                        // needle[Y]
    sta B6                            // scratch
    lda (W0),y                        // haystack[outer + Y]
    cmp B6
    bne _sfp_advance
    iny
    bne _sfp_inner                    // unconditional: Y < 256

_sfp_advance:
    // outer++ (16-bit).
    inc B4
    bne !+
    inc B5
!:
    // While outer <= max_start, continue.
    lda B2
    cmp B4
    lda B3
    sbc B5
    bcs _sfp_outer                    // max_start >= outer → continue
    // fallthrough: exhausted, not found
_sfp_not_found:
    lda #$FF
    sta RV
    sta RV+1
    jmp postamble

_sfp_match:
    lda B4
    sta RV
    lda B5
    sta RV+1
    jmp postamble
