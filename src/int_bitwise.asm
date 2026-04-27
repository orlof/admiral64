// -----------------------------------------------------------------------------
// int_bitwise_not — variable-length signed integer bitwise complement.
//   `~x` = `-x - 1`. We compute it directly by byte-wise EOR with $FF, which
//   gives the same result for two's-complement representation and avoids the
//   double-allocation of the `int_negate(x); int_sub(_, INT_1)` route.
//
//   in:   1 handle on RS = TYPE_INT
//   out:  RV = TYPE_INT handle holding ~x
//
// Length: result has the same byte length as input. EOR-with-$FF preserves
// canonical normalization (every payload byte flips, including the sign
// byte), so int_normalize isn't needed.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

int_bitwise_not:
    preamble_args(1, 0)

    // Step 1: read source length so we know how big to allocate.
    rs_peek(W0)
    jsr deref_W0_to_W2          // W2 = src payload, A = O_LEN low byte
    sta B0                       // B0 = byte length

    // Step 2: allocate result of same size.
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int               // RV = result handle (gc may have run)

    // Step 3: re-deref source AND result. alloc_int may have triggered
    // gc_compact, moving heap payloads.
    rs_peek(W0)
    jsr deref_W0_to_W2          // W2 = src payload (current)

    // W3 = result payload base.
    lda RV
    sta W1
    lda RV+1
    sta W1+1
    ldy #H_PTR
    lda (W1),y
    sta W3
    iny
    lda (W1),y
    sta W3+1
    clc
    lda W3
    adc #O_HEADER
    sta W3
    bcc !+
    inc W3+1
!:

    // Step 4: byte-wise invert.
    ldy B0
!loop:
    dey
    bmi !done+
    lda (W2),y
    eor #$FF
    sta (W3),y
    jmp !loop-
!done:
    jmp postamble

// =============================================================================
// int_bitwise_and / _or / _xor — variable-length signed bitwise binary ops.
//
//   in:  RS bottom→top: a, b. Both TYPE_INT handles.
//   out: RV = TYPE_INT handle holding (a OP b).
//
// Algorithm:
//   result_len = max(len_a, len_b)
//   for i in 0..result_len-1:
//     byte_a = a[i] if i < len_a else sign_a   (sign-extend shorter operand)
//     byte_b = b[i] if i < len_b else sign_b
//     result[i] = byte_a OP byte_b
//   normalize
//
// Code-share via self-modifying code: the entry stubs patch the opcode of
// a single `OP B5` instruction inside the shared body. ORA zp = $05;
// AND zp = $25; EOR zp = $45 — same instruction shape, different first
// byte. SMC is safe here: the body has no callbacks that could re-enter
// these routines, and our parser-evaluator's recursion goes through the
// LED layer (preamble/postamble) before any sibling bitwise call.
// =============================================================================

.const OPC_ORA_ZP = $05
.const OPC_AND_ZP = $25
.const OPC_EOR_ZP = $45

int_bitwise_and:
    lda #OPC_AND_ZP
    bne _ibw_set
int_bitwise_or:
    lda #OPC_ORA_ZP
    bne _ibw_set
int_bitwise_xor:
    lda #OPC_EOR_ZP
_ibw_set:
    sta _ibw_op_inst
    jmp _ibw_body

_ibw_body:
    preamble_args(2, 0)

    // --- Read both operands' lengths and sign bytes. ---
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2          // W2 = a payload, A = len_a
    sta B0
    jsr sign_byte_W2
    sta B1                       // B1 = sign_a

    rs_peek_at(W1, 0)
    jsr deref_W1_to_W3          // W3 = b payload, A = len_b
    sta B2
    jsr sign_byte_W3
    sta B3                       // B3 = sign_b

    // --- result_len = max(len_a, len_b). ---
    lda B0
    cmp B2
    bcs _ibw_use_a_len
    lda B2
_ibw_use_a_len:
    sta B4                       // B4 = result_len
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int                // RV = result handle (gc may have run)

    // --- Pass 1: result[i] = (i < len_a) ? a[i] : sign_a. ---
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2          // W2 = a payload (post-alloc)

    lda RV
    sta W0
    lda RV+1
    sta W0+1
    ldy #H_PTR
    lda (W0),y
    sta W3
    iny
    lda (W0),y
    sta W3+1
    clc
    lda W3
    adc #O_HEADER
    sta W3
    bcc !skip_carry+
    inc W3+1
!skip_carry:

    ldy #0
_ibw_p1_loop:
    cpy B4
    beq _ibw_pass2_init
    cpy B0
    bcc _ibw_p1_use_a
    lda B1                       // sign-extended
    jmp _ibw_p1_store
_ibw_p1_use_a:
    lda (W2),y
_ibw_p1_store:
    sta (W3),y
    iny
    jmp _ibw_p1_loop

_ibw_pass2_init:
    // --- Pass 2: result[i] = result[i] OP byte_b. ---
    rs_peek_at(W1, 0)
    jsr deref_W1_to_W3          // W3 = b payload (post-alloc)

    // Re-derive result payload into W2 (W2 was a's payload; we're done with it).
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !skip_carry+
    inc W2+1
!skip_carry:

    ldy #0
_ibw_p2_loop:
    cpy B4
    beq _ibw_done
    cpy B2
    bcc _ibw_p2_use_b
    lda B3                       // sign-extended
    jmp _ibw_p2_have_b
_ibw_p2_use_b:
    lda (W3),y
_ibw_p2_have_b:
    sta B5                       // B5 = byte_b (zero-page operand of the patched op)
    lda (W2),y                   // A = byte_a (= current result byte)
_ibw_op_inst:
    and B5                       // SMC: opcode byte patched to ORA / AND / EOR
    sta (W2),y
    iny
    jmp _ibw_p2_loop

_ibw_done:
    // Normalize: bitwise op on equal-length sign-extended operands may
    // produce a redundant leading sign byte (e.g. `0xFF & 0xFF = 0xFF`,
    // 1-byte = -1). val_eq compares lengths, so we must canonicalize.
    rs_push(RV)
    jsr int_normalize            // consumes 1 RS arg; RV unchanged
    jmp postamble
