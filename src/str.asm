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
// str_search — substring search (`needle in haystack`). Both operands must
// be TYPE_STR; the caller is expected to type-check and panic otherwise.
//
// in:  RS — needle (deeper), haystack (top).
// out: A = 1 if `needle` appears as a contiguous substring of `haystack`,
//      else 0. Args consumed.
//
// An empty needle is "found" at position 0 (matches Python `"" in "abc"`).
// Limits: indices are 8-bit, so haystack ≤ 255 bytes.
// V4'.
// -----------------------------------------------------------------------------
str_search:
    preamble_args(2, 0)

    // Needle: B0 = len, W3 = payload base.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    sta B0
    lda W2
    sta W3
    lda W2+1
    sta W3+1

    // Empty needle → found.
    lda B0
    bne _ssrch_have_needle
    lda #1
    jmp postamble
_ssrch_have_needle:

    // Haystack: B1 = len, W2 = payload base.
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    sta B1

    // Needle longer than haystack → not found.
    lda B0
    cmp B1
    beq _ssrch_compute_max
    bcc _ssrch_compute_max
    lda #0
    jmp postamble
_ssrch_compute_max:
    sec
    lda B1
    sbc B0
    sta B2                            // B2 = max start offset (inclusive)

    lda #0
    sta B3                            // B3 = current outer offset

_ssrch_outer:
    ldy #0                            // Y = inner index into needle
_ssrch_inner:
    cpy B0
    beq _ssrch_match
    lda (W3),y                        // needle[Y]
    sta B4
    tya
    clc
    adc B3
    tay                               // Y = haystack offset
    lda (W2),y
    cmp B4
    bne _ssrch_advance
    // Match — recover original Y (= Y - B3) and continue.
    tya
    sec
    sbc B3
    tay
    iny
    bne _ssrch_inner
_ssrch_advance:
    inc B3
    lda B3
    cmp B2
    beq _ssrch_outer
    bcc _ssrch_outer
    lda #0
    jmp postamble

_ssrch_match:
    lda #1
    jmp postamble
