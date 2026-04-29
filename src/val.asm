// -----------------------------------------------------------------------------
// val.asm — generic equality (val_eq) and 3-way comparison (val_cmp).
//
// Both routines share the same dispatch shape:
//   1. Same handle? → trivially equal.
//   2. Cross-type? → val_eq returns 0; val_cmp orders by type-tag.
//   3. Same type → per-type body.
//
// Type-specific bodies:
//   TYPE_INT  → int_cmp (signed two's-complement, variable-length)
//   TYPE_STR  → byte-wise lexicographic (unsigned)
//   TYPE_BOOL → byte compare (TRUE=1, FALSE=0)
//   TYPE_NONE → always equal (only one NONE; reaches here only via two
//               distinct NONE-typed handles, which are still semantically equal)
//   TYPE_TUPLE / TYPE_LIST / TYPE_DICT → element-wise recursion. Dict's
//               elements are 2-tuples, so the recursion bottoms out via
//               tuple → key/value, naturally.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

// =============================================================================
// val_truthy — Python-style truthiness test. Leaf helper, no preamble.
//   in:  W0 = handle
//   out: A = 1 if truthy, 0 if falsy
//   clobbers: A, X, Y, W2.
//
// Rules:
//   NONE                                → False
//   BOOL / INT / FLOAT                  → any payload byte non-zero → True
//   STR / LIST / TUPLE / DICT           → O_LEN != 0 → True
// =============================================================================
val_truthy:
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_NONE
    beq _vt_false
    cmp #TYPE_INT
    beq _vt_byte_scan
    cmp #TYPE_BOOL
    beq _vt_byte_scan
    cmp #TYPE_FLOAT
    beq _vt_byte_scan
    // STR / LIST / TUPLE / DICT — check O_LEN.
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    iny
    ora (W2),y
    beq _vt_false
    bne _vt_true

_vt_byte_scan:
    // Scan all payload bytes; truthy iff any byte is non-zero. Works for
    // BOOL (1 byte) / INT (variable) / FLOAT (5 bytes — first byte is exp,
    // which is 0 iff value is 0).
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    sta B0                       // length (low byte; high ignored for len < 256)
    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:
    ldy #0
    lda #0
!loop:
    cpy B0
    beq _vt_byte_done
    ora (W2),y
    iny
    jmp !loop-
_vt_byte_done:
    // Loop exits via the CPY-against-B0 branch, which left Z reflecting
    // (Y == length), not the OR result. Re-test A explicitly.
    cmp #0
    bne _vt_true
_vt_false:
    lda #0
    rts
_vt_true:
    lda #1
    rts

// =============================================================================
// val_eq — boolean equality. Returns A = 1 if equal, 0 otherwise.
//   in: RS — a (deeper), b (top).
// =============================================================================
val_eq:
    preamble_args(2, 0)

    rs_peek_at(W0, 1)
    rs_peek_at(W1, 0)

    lda W0
    cmp W1
    bne _veq_not_same_handle
    lda W0+1
    cmp W1+1
    bne _veq_not_same_handle
    lda #1
    jmp postamble

_veq_not_same_handle:
    // Read H_TYPE from each side, normalizing TYPE_NAME → TYPE_STR so a lazy
    // name compares equal to a materialized string with matching bytes.
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_NAME
    bne !s+
    lda #TYPE_STR
!s:
    sta B0
    lda (W1),y
    cmp #TYPE_NAME
    bne !s+
    lda #TYPE_STR
!s:
    cmp B0
    beq _veq_types_match
    lda #0
    jmp postamble

_veq_types_match:
    jsr deref_W0_to_W2
    sta B0
    jsr deref_W1_to_W3
    cmp B0
    beq _veq_lengths_match
    lda #0
    jmp postamble

_veq_lengths_match:
    sta B0
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_TUPLE
    beq _veq_array
    cmp #TYPE_LIST
    beq _veq_array
    cmp #TYPE_DICT
    beq _veq_array

    // Leaf: byte-by-byte payload compare.
    ldy B0
    dey
    bmi _veq_equal
_veq_loop:
    lda (W2),y
    cmp (W3),y
    bne _veq_not_equal
    dey
    bpl _veq_loop

_veq_equal:
    lda #1
    jmp postamble

_veq_not_equal:
    lda #0
    jmp postamble

    // Sequence/dict recursion: element-wise val_eq.
_veq_array:
_veq_array_loop:
    lda B0
    beq _veq_equal

    ldy #0
    lda (W2),y
    sta W0
    iny
    lda (W2),y
    sta W0+1
    ldy #0
    lda (W3),y
    sta W1
    iny
    lda (W3),y
    sta W1+1

    rs_push(W0)
    rs_push(W1)
    jsr val_eq
    cmp #1
    bne _veq_not_equal

    clc
    lda W2
    adc #2
    sta W2
    bcc !+
    inc W2+1
!:
    clc
    lda W3
    adc #2
    sta W3
    bcc !+
    inc W3+1
!:
    dec B0
    jmp _veq_array_loop


// =============================================================================
// val_cmp — 3-way compare. Returns A = $FF if a<b, $00 if a==b, $01 if a>b.
//   in: RS — a (deeper), b (top). Both args consumed.
//
// Mirrors Admiral's val_cmp dispatch order (stdlib.dasm16:158). When the two
// arguments share a type, the type-specific comparator runs. When they don't,
// the type-tag bytes are compared numerically.
// =============================================================================
val_cmp:
    preamble_args(2, 0)

    rs_peek_at(W0, 1)
    rs_peek_at(W1, 0)

    // 1. Same handle → 0.
    lda W0
    cmp W1
    bne _vc_diff_handles
    lda W0+1
    cmp W1+1
    bne _vc_diff_handles
    lda #0
    jmp postamble

_vc_diff_handles:
    // 2. Different types → compare type tags numerically. Normalize TYPE_NAME
    // → TYPE_STR so a lazy name compares like a string with matching bytes.
    // Load b's type first into B0, then a's type into A, so `cmp B0` computes
    // a - b (carry set when a >= b).
    ldy #H_TYPE
    lda (W1),y
    cmp #TYPE_NAME
    bne !s+
    lda #TYPE_STR
!s:
    sta B0
    lda (W0),y
    cmp #TYPE_NAME
    bne !s+
    lda #TYPE_STR
!s:
    cmp B0
    beq _vc_same_type
    bcs _vc_pos
    lda #$FF
    jmp postamble

_vc_same_type:
    // 3. Same type. Dispatch to per-type comparator. A still holds the type tag.
    cmp #TYPE_INT
    beq _vc_int
    cmp #TYPE_BOOL
    beq _vc_int                  // bool stored same as 1-byte int; int_cmp works
    cmp #TYPE_STR
    beq _vc_str
    cmp #TYPE_NAME
    beq _vc_str                  // names compare bytewise like strings
    cmp #TYPE_FLOAT
    beq _vc_float
    cmp #TYPE_TUPLE
    beq _vc_array
    cmp #TYPE_LIST
    beq _vc_array
    cmp #TYPE_DICT
    beq _vc_array
    // TYPE_NONE or unknown: equal-by-default.
    lda #0
    jmp postamble

_vc_pos:
    lda #1
    jmp postamble

// --- TYPE_INT / TYPE_BOOL ---------------------------------------------------
// int_cmp's preamble pops two handles from RS — exactly our args. Both
// routines have the same target_RSP, so int_cmp's postamble lands RSP at
// the right place for our postamble too.
_vc_int:
    jsr int_cmp                  // result in A: $FF / $00 / $01
    jmp postamble

// --- TYPE_FLOAT --------------------------------------------------------------
// float_cmp pops two handles from RS — exactly the args still rooted at our
// frame. Same target_RSP as our preamble, so its postamble lands us where
// ours expects.
_vc_float:
    jsr float_cmp
    jmp postamble

// --- TYPE_STR — byte-wise lexicographic, unsigned ---------------------------
_vc_str:
    jsr deref_W0_to_W2           // W2 = a payload, A = a length
    sta B0
    jsr deref_W1_to_W3           // W3 = b payload, A = b length
    sta B1

    ldy #0
_vc_str_loop:
    cpy B0
    beq _vc_str_a_end
    cpy B1
    beq _vc_str_b_end
    lda (W2),y
    cmp (W3),y
    bne _vc_str_byte_diff
    iny
    jmp _vc_str_loop

_vc_str_byte_diff:
    bcs _vc_pos
    lda #$FF
    jmp postamble

_vc_str_a_end:
    cpy B1
    beq _vc_zero
    lda #$FF                     // a shorter — a < b
    jmp postamble

_vc_str_b_end:
    lda #1                       // b shorter — a > b
    jmp postamble

_vc_zero:
    lda #0
    jmp postamble

// --- Sequence (tuple/list/dict) — element-wise recursive val_cmp ------------
// First mismatching element decides; if all common-prefix elements match,
// the shorter sequence is "less than" the longer.
_vc_array:
    jsr deref_W0_to_W2           // W2 = a payload, A = a O_LEN
    sta B0
    jsr deref_W1_to_W3           // W3 = b payload, A = b O_LEN
    sta B1

    lda #0
    sta B2                       // B2 = current index

_vc_array_loop:
    lda B2
    cmp B0
    beq _vc_array_a_end
    cmp B1
    beq _vc_array_b_end

    // Load a[B2] into W0, b[B2] into W1.
    asl
    tay
    lda (W2),y
    sta W0
    iny
    lda (W2),y
    sta W0+1

    lda B2
    asl
    tay
    lda (W3),y
    sta W1
    iny
    lda (W3),y
    sta W1+1

    rs_push(W0)
    rs_push(W1)
    jsr val_cmp                  // recursive
    cmp #0
    bne _vc_array_done           // first non-zero result wins

    inc B2
    jmp _vc_array_loop

_vc_array_done:
    jmp postamble

_vc_array_a_end:
    cmp B1
    beq _vc_zero                 // both ended together → equal
    lda #$FF                     // a is shorter
    jmp postamble

_vc_array_b_end:
    lda #1
    jmp postamble
