// -----------------------------------------------------------------------------
// int_util — shared helpers for fixed 32-bit inline integers.
//
// Every TYPE_INT is a handle whose 32-bit two's-complement value lives INLINE
// in the handle bytes: H_PTR (offset 0,1) = low 16 bits, H_SIZE (offset 2,3) =
// high 16 bits, little-endian. There is no heap payload. See alloc_inline_int
// in alloc.asm and PLANS/fixed-32-integers.md.
//
// Op calling convention (used across int_add/sub/mul/... ):
//   - Operand A value → B0..B3 (LE 32-bit), loaded from handle in W0.
//   - Operand B value → B4..B7 (LE 32-bit), loaded from handle in W1.
//   - Result built in B0..B3, materialized to a fresh inline int via
//     `alloc_int_b0` (→ RV). W0..W3 are free scratch after the loads.
//
// These are leaf helpers (rts, no preamble): they run inside an op's V4'
// frame and clobber the B/W cells the op intends to use anyway.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "alloc.asm"

// int_load_a — value of the handle in W0 → B0..B3 (little-endian).
//   clobbers: A, Y.
int_load_a:
    ldy #0
    lda (W0),y
    sta B0
    iny
    lda (W0),y
    sta B1
    iny
    lda (W0),y
    sta B2
    iny
    lda (W0),y
    sta B3
    rts

// int_load_b — value of the handle in W1 → B4..B7 (little-endian).
//   clobbers: A, Y.
int_load_b:
    ldy #0
    lda (W1),y
    sta B4
    iny
    lda (W1),y
    sta B5
    iny
    lda (W1),y
    sta B6
    iny
    lda (W1),y
    sta B7
    rts

// int_index_w1_b5b6 — read the inline int in W1 as a signed 16-bit subscript
// index: B5 = low byte, B6 = high byte (the low 16 bits of the 32-bit value).
// Container subscripts only ever use 16-bit indices; the high 16 bits are
// ignored. Negative indices (bit 15 set) are handled by the caller.
//   clobbers: A, Y.
int_index_w1_b5b6:
    ldy #0
    lda (W1),y
    sta B5
    iny
    lda (W1),y
    sta B6
    rts

// alloc_int_b0 — materialize B0..B3 (LE 32-bit) as a fresh inline TYPE_INT.
//   out: RV = new handle. Tail-calls alloc_inline_int (its postamble returns
//        to OUR caller; RV survives).
alloc_int_b0:
    lda B0
    sta W2
    lda B1
    sta W2+1
    lda B2
    sta W3
    lda B3
    sta W3+1
    jmp alloc_inline_int
