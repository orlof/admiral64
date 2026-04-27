// -----------------------------------------------------------------------------
// str_to_float — parse an ASCII digit string into a TYPE_FLOAT handle.
//
//   in:   1 handle on RS = TYPE_STR (e.g. "1.5", "1e-3", ".5", "1.")
//   out:  RV = TYPE_FLOAT handle
//
// Strategy: copy the span into a small static buffer with a sentinel byte
// (`:` = $3A) appended, then call BASIC ROM's FIN at $BCF3 (preceded by
// CHRGET in ZP) to parse it into FAC1. Pack FAC1 → our 5-byte format.
//
// Why a copy buffer rather than reading the heap span directly:
// FIN walks bytes via CHRGET until a non-numeric/non-exponent char appears.
// The byte after our heap span is whatever comes next in the source — could
// be a valid digit/decimal/exponent and FIN would over-consume. The
// terminator-in-buffer approach guarantees a clean stop.
//
// CHRGET is the BASIC interpreter's character-fetch routine living in ZP
// at $0073-$008A. It's installed by KERNAL boot, so it's already there for
// us. The instruction at $0079 has TXTPTR ($7A-$7B) as its operand — when
// we write to $7A/$7B we're patching CHRGET's source pointer.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

.const STR2FLOAT_BUF_LEN = 24      // any reasonable float fits (1.79e308 = 10 chars)

str_to_float:
    preamble_args(1, 0)

    // Step 1: copy span into local buffer, append `$3A` sentinel.
    rs_peek(W0)
    jsr deref_W0_to_W2          // W2 = payload, A = O_LEN low byte
    sta B0                      // B0 = length
    cmp #STR2FLOAT_BUF_LEN
    bcc _s2f_size_ok
    // Token longer than buffer → panic. Real floats won't hit this.
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler
_s2f_size_ok:
    ldy #0
_s2f_copy:
    cpy B0
    beq _s2f_done_copy
    lda (W2),y
    // Fold lowercase 'e' to uppercase 'E' — BASIC ROM's FIN only recognizes
    // 'E' as the exponent marker. Our lexer accepts both.
    cmp #$65                    // 'e'
    bne _s2f_no_fold
    lda #$45                    // 'E'
_s2f_no_fold:
    sta str2float_buf,y
    iny
    jmp _s2f_copy
_s2f_done_copy:
    lda #$3A                    // ':' — CHRGET's "end of statement" sentinel
    sta str2float_buf,y

    // Step 2: set TXTPTR = (buf - 1) so CHRGET's pre-increment lands on
    // the first byte. CHRGET reads at $0079: `LDA (TXTPTR_OPERAND)`, where
    // the operand is $7A/$7B in ZP.
    lda #<(str2float_buf - 1)
    sta $7A
    lda #>(str2float_buf - 1)
    sta $7B

    // Step 3: save allocator state, call BASIC FIN, restore.
    //
    // BASIC FIN uses ZP $22-$2F as scratch (INDEX1/INDEX2 for the
    // multiply-by-10 accumulator, etc.). Our allocator's NEXT_DATA /
    // ALLOC_SIZE / RESERVED_HEAD / GC_DEST live in that exact range, so
    // we must save/restore around the call. (BASIC's FADDT/FMULTT/FDIVT
    // happen NOT to touch this range, which is why Stage 6 didn't catch it.)
    ldy #13
_s2f_save:
    lda $22,y
    sta _s2f_zp_save,y
    dey
    bpl _s2f_save

    inc $01
    jsr $0073                   // CHRGET: ++TXTPTR; A = first char (skips spaces)
    jsr $BCF3                   // FIN: ASCII → FAC1
    dec $01

    ldy #13
_s2f_restore:
    lda _s2f_zp_save,y
    sta $22,y
    dey
    bpl _s2f_restore

    // Step 4: allocate a TYPE_FLOAT (5-byte payload) and pack FAC1.
    lda #5
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_FLOAT
    sta ALLOC_TYPE
    jsr alloc                   // RV = handle

    jsr deref_RV_to_W2          // W2 = payload base of new float
    jsr _fp_pack_from_fac1      // packs FAC1 into 5 bytes at (W2)

    jmp postamble

// Static parse buffer. 24 bytes (any reasonable float literal). Not
// reentrant — but neither is the lexer's source pointer in ZP, and Stage 8
// doesn't recurse through str_to_float.
str2float_buf:
    .fill STR2FLOAT_BUF_LEN + 1, 0

// 14-byte scratch for save/restore of $22-$2F across the FIN call.
_s2f_zp_save:
    .fill 14, 0
