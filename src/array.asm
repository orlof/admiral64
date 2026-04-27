// -----------------------------------------------------------------------------
// array.asm — generic resizable handle-array container.
//
// Three types share this substrate:
//   TYPE_TUPLE — immutable, no growth, no public mutators
//   TYPE_LIST  — mutable, grows on overflow
//   TYPE_DICT  — sorted array of (key, value) 2-tuples; binary-searched
//
// All three have the same payload layout:
//   - O_LEN        = element count (NOT byte count)
//   - payload      = N consecutive 16-bit handle pointers
//   - capacity     = (H_SIZE - O_HEADER) / 2 elements ≥ O_LEN
//
// For mutable types, capacity ≥ O_LEN provides slack so append doesn't
// reallocate every call. Growth strategy: double, with a floor of 4 elements
// (8 bytes of payload).
//
// Co-located labels alias each operation under per-type names so callers can
// use whichever name reads best, with zero indirection cost:
//
//     array_get:
//     tuple_get:
//     list_get:
//         ... one body ...
//
// Type-specific allocators (`tuple_alloc`, `list_alloc`, `dict_alloc`) all
// call `_array_alloc_init` for the shared "alloc + zero + fix O_LEN" path.
//
// GC tracing of children lives in `_gc_trace_array` in gc.asm — also generic.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

// -----------------------------------------------------------------------------
// _array_alloc_init — internal: allocate a container handle with N null slots.
//
// Must be called from a V4'-wrapped body — caller's preamble has saved W/B.
//
//   in:  A = N (element count, 0..127), X = type tag
//   out: RV = new handle. Object's O_LEN = N. Payload zeroed.
//   clobbers: A, X, Y, W2, B0
//
// Caller MUST rs_push(RV) before any further allocating jsr.
// -----------------------------------------------------------------------------
_array_alloc_init:
    sta B0                       // B0 = N
    stx ALLOC_TYPE

    asl                          // 2*N = payload bytes
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc                    // → handle in RV

    // alloc wrote O_LEN = ALLOC_SIZE (byte count). Containers want O_LEN as
    // element count — overwrite via H_PTR.
    ldy #H_PTR
    lda (RV),y
    sta W2
    iny
    lda (RV),y
    sta W2+1                     // W2 = object header address

    ldy #O_LEN
    lda B0
    sta (W2),y
    iny
    lda #0
    sta (W2),y

    // Advance W2 past header and zero the payload.
    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:
    lda B0
    asl                          // bytes to zero = 2*N
    tay
    beq _aai_done
    lda #0
_aai_zero_loop:
    dey
    sta (W2),y
    cpy #0
    bne _aai_zero_loop
_aai_done:
    rts

// -----------------------------------------------------------------------------
// array_get / tuple_get / list_get — fetch handle at slot i.
//   in:  RS top: container handle. FS top: index (word; low byte used).
//   out: RV = child handle (0 if slot unset). Args consumed.
// -----------------------------------------------------------------------------
array_get:
tuple_get:
list_get:
    preamble_args(1, 1)

    rs_peek_at(W0, 0)
    fs_peek_arg(W1, 0)
    jsr deref_W0_to_W2           // W2 = payload (post-header)

    lda W1
    asl                          // byte offset = 2*index
    tay
    lda (W2),y
    sta RV
    iny
    lda (W2),y
    sta RV+1

    jmp postamble

// -----------------------------------------------------------------------------
// array_len / tuple_len / list_len / dict_len — element count.
//   in:  RS top: container handle.
//   out: A = O_LEN low byte. Args consumed.
// -----------------------------------------------------------------------------
array_len:
tuple_len:
list_len:
dict_len:
    preamble_args(1, 0)

    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2           // A = O_LEN low byte

    jmp postamble

// -----------------------------------------------------------------------------
// array_set / list_set — replace child handle at slot i.
//   in:  RS: container (deeper), child (top). FS: index (word; low byte used).
//   out: container[index] = child. Args consumed.
//
// Bounds checking is the caller's responsibility for now.
// -----------------------------------------------------------------------------
array_set:
list_set:
    preamble_args(2, 1)

    rs_peek_at(W0, 1)
    rs_peek_at(W1, 0)
    fs_peek_arg(W2, 0)

    lda W2
    jsr array_set_leaf

    jmp postamble

// -----------------------------------------------------------------------------
// array_set_leaf / tuple_set_leaf — write a child handle into a slot.
//
// Leaf-helper contract — caller's V4' body owns its W regs as scratch.
//   in:  W0 = container, W1 = child, A = slot index (0..127)
//   out: container payload at index A holds W1
//   clobbers: A, X, Y, W2 (W0 / W1 preserved)
// -----------------------------------------------------------------------------
array_set_leaf:
tuple_set_leaf:
    pha
    jsr deref_W0_to_W2
    pla
    asl
    tay
    lda W1
    sta (W2),y
    iny
    lda W1+1
    sta (W2),y
    rts

// -----------------------------------------------------------------------------
// array_append / list_append — add child at slot O_LEN; grow if needed.
//   in:  RS: container (deeper), child (top).
//   out: O_LEN += 1; payload[O_LEN-1] = child. Args consumed.
// -----------------------------------------------------------------------------
array_append:
list_append:
    preamble_args(2, 0)

aap_retry:
    rs_peek_at(W0, 1)            // W0 = container

    // Read O_LEN.
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    sta B0                       // B0 = O_LEN

    // need = 2*(O_LEN + 1) + O_HEADER (16-bit).
    clc
    lda B0
    adc #1
    sta B1
    lda #0
    adc #0
    sta B2
    asl B1
    rol B2
    clc
    lda B1
    adc #O_HEADER
    sta B1
    lda B2
    adc #0
    sta B2

    // If H_SIZE >= need, we have room.
    ldy #H_SIZE
    sec
    lda (W0),y
    sbc B1
    iny
    lda (W0),y
    sbc B2
    bcs aap_have_room

    jsr _array_grow
    jmp aap_retry

aap_have_room:
    // Write child at slot B0 (= old O_LEN).
    rs_peek_at(W0, 1)
    rs_peek_at(W1, 0)
    lda B0
    jsr array_set_leaf

    jsr _array_inc_o_len_at_rs1

    jmp postamble

// -----------------------------------------------------------------------------
// array_insert / list_insert — insert child at slot `index`, shifting
// elements [index..O_LEN-1] up by one. Grows if needed.
//   in:  RS: container (deeper), child (top). FS: index (word; low byte used).
//   out: payload[index] = child; subsequent elements shifted up; O_LEN += 1.
//        Args consumed.
//
// If `index > O_LEN`, behavior is clipped to O_LEN (i.e., append).
// -----------------------------------------------------------------------------
array_insert:
list_insert:
    preamble_args(2, 1)

ains_retry:
    rs_peek_at(W0, 1)

    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    sta B0                       // B0 = O_LEN

    clc
    lda B0
    adc #1
    sta B1
    lda #0
    adc #0
    sta B2
    asl B1
    rol B2
    clc
    lda B1
    adc #O_HEADER
    sta B1
    lda B2
    adc #0
    sta B2

    ldy #H_SIZE
    sec
    lda (W0),y
    sbc B1
    iny
    lda (W0),y
    sbc B2
    bcs ains_have_room

    jsr _array_grow
    jmp ains_retry

ains_have_room:
    // Compute clipped index. B0 still holds O_LEN.
    fs_peek_arg(W1, 0)
    lda W1
    cmp B0
    bcc ains_idx_ok
    lda B0                       // index > O_LEN → clip to O_LEN
ains_idx_ok:
    sta B1                       // B1 = effective index

    // If index < O_LEN, shift elements [index..O_LEN-1] up by 1.
    lda B1
    cmp B0
    bcs ains_no_shift            // idx == O_LEN → no shift

    rs_peek_at(W0, 1)
    lda B1
    jsr _array_shift_up_leaf

ains_no_shift:
    // Write child at slot B1.
    rs_peek_at(W0, 1)
    rs_peek_at(W1, 0)
    lda B1
    jsr array_set_leaf

    jsr _array_inc_o_len_at_rs1

    jmp postamble

// -----------------------------------------------------------------------------
// array_del / list_del — remove element at slot `index`, shifting subsequent
// elements down. O_LEN -= 1. If index ≥ O_LEN, no-op.
//   in:  RS: container. FS: index (word; low byte used).
// -----------------------------------------------------------------------------
array_del:
list_del:
    preamble_args(1, 1)

    rs_peek_at(W0, 0)
    fs_peek_arg(W1, 0)

    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    sta B0                       // B0 = O_LEN

    lda W1
    cmp B0
    bcs adel_done                // index >= O_LEN: no-op

    sta B1                       // B1 = index

    lda B1
    jsr _array_shift_down_leaf

    rs_peek_at(W0, 0)
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    sec
    lda (W2),y
    sbc #1
    sta (W2),y
    iny
    lda (W2),y
    sbc #0
    sta (W2),y

adel_done:
    jmp postamble

// -----------------------------------------------------------------------------
// _array_inc_o_len_at_rs1 — leaf: ++O_LEN of the container at RS offset 1.
//   in: container at RS[1]
//   clobbers: A, Y, W0, W2
// -----------------------------------------------------------------------------
_array_inc_o_len_at_rs1:
    rs_peek_at(W0, 1)
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    clc
    adc #1
    sta (W2),y
    iny
    lda (W2),y
    adc #0
    sta (W2),y
    rts

// -----------------------------------------------------------------------------
// _array_shift_up_leaf — make room at slot `index` by sliding elements
// [index..O_LEN-1] to [index+1..O_LEN]. Backward byte copy so we don't
// overwrite source bytes before reading them.
//
//   in:  W0 = container, A = index. Slot at O_LEN must be reserved
//        (capacity ≥ O_LEN+1 — caller verified).
//   clobbers: A, X, Y, W2, B0, B1 (W0, W1 preserved)
// -----------------------------------------------------------------------------
_array_shift_up_leaf:
    pha                          // save index
    jsr deref_W0_to_W2           // W2 = payload, A = O_LEN
    sta B0
    pla
    sta B1                       // B1 = index

    // count_bytes = 2 * (O_LEN - index)
    lda B0
    sec
    sbc B1
    beq _asu_done
    asl
    tax                          // X = byte counter

    // Y = 2*O_LEN + 1 (last new byte, = high of new slot O_LEN)
    lda B0
    asl
    clc
    adc #1
    tay

_asu_loop:
    dey
    dey
    lda (W2),y                   // src at Y-2
    iny
    iny
    sta (W2),y                   // dst at Y
    dey
    dex
    bne _asu_loop
_asu_done:
    rts

// -----------------------------------------------------------------------------
// _array_shift_down_leaf — close the gap left by deleting slot `index` by
// sliding elements [index+1..O_LEN-1] down to [index..O_LEN-2]. Forward
// byte copy.
//
//   in:  W0 = container, A = index (in range).
//   clobbers: A, X, Y, W2, B0, B1 (W0, W1 preserved)
// -----------------------------------------------------------------------------
_array_shift_down_leaf:
    pha
    jsr deref_W0_to_W2           // W2 = payload, A = O_LEN
    sta B0
    pla
    sta B1                       // B1 = index

    // count_bytes = 2 * (O_LEN - 1 - index). If ≤0, nothing to shift.
    lda B0
    sec
    sbc B1
    sec
    sbc #1
    bcc _asd_done
    beq _asd_done
    asl
    tax

    // Y = 2 * index (first dst byte offset)
    lda B1
    asl
    tay

_asd_loop:
    iny
    iny
    lda (W2),y                   // src at Y+2
    dey
    dey
    sta (W2),y                   // dst at Y
    iny
    dex
    bne _asd_loop
_asd_done:
    rts

// -----------------------------------------------------------------------------
// _array_grow — double the container's payload capacity (min 8 bytes
// = 4 elements). Preserves O_LEN and existing element values.
//
//   pre: container rooted on RS at offset 1.
//   post: container.H_PTR points at fresh, larger payload area;
//         H_SIZE updated. Old payload becomes orphan (next gc_compact
//         reclaims).
//
// Reuses `heap_carve_payload` (data-only allocation) so we don't strand a
// throwaway handle for the dead old area.
// -----------------------------------------------------------------------------
_array_grow:
    preamble_args(0, 0)

    rs_peek_at(W0, 1)            // container

    // new_payload_bytes = max(2 * old_payload_bytes, 8)
    ldy #H_SIZE
    sec
    lda (W0),y
    sbc #O_HEADER
    sta B0
    iny
    lda (W0),y
    sbc #0
    sta B1
    asl B0
    rol B1
    lda B1
    bne _ag_size_ok
    lda B0
    cmp #8
    bcs _ag_size_ok
    lda #8
    sta B0
    lda #0
    sta B1
_ag_size_ok:

    // Save current O_LEN (heap_carve_payload writes a fresh O_LEN that we
    // overwrite back to the live element count).
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    sta B2

    lda B0
    sta ALLOC_SIZE
    lda B1
    sta ALLOC_SIZE+1

    jsr heap_carve_payload       // RV = new object base. May trigger GC.

    // GC during retry may have moved old data — re-read.
    rs_peek_at(W0, 1)
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1

    ldy #H_PTR
    lda RV
    sta (W0),y
    iny
    lda RV+1
    sta (W0),y

    ldy #H_SIZE
    lda ALLOC_SIZE
    clc
    adc #O_HEADER
    sta (W0),y
    iny
    lda ALLOC_SIZE+1
    adc #0
    sta (W0),y

    ldy #O_LEN
    lda B2
    sta (RV),y
    iny
    lda #0
    sta (RV),y

    // Copy old elements: src = old + O_HEADER, dst = RV + O_HEADER,
    // count = 2 * O_LEN. Forward copy is safe — regions disjoint.
    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:
    clc
    lda RV
    adc #O_HEADER
    sta GC_DEST
    lda RV+1
    adc #0
    sta GC_DEST+1
    lda B2
    asl
    sta W3
    lda #0
    sta W3+1
    jsr mem_copy_down

    // The handle's new H_PTR is the highest in the heap (heap_carve_payload
    // always carves at NEXT_DATA). Move it to the tail of RESERVED so the
    // list stays in H_PTR-ascending order — gc_compact requires this.
    rs_peek_at(W0, 1)
    jsr _relink_to_tail

    jmp postamble

// -----------------------------------------------------------------------------
// array_merge — concatenate two same-type containers (STR / LIST / TUPLE)
// into a fresh container of the same type.
//
//   in:  RS [a, b] — a is deeper, b is top.
//   out: RV = new container with payload = a.payload ++ b.payload.
//        Args consumed.
//
// Type rules:
//   - Both operands MUST have the same H_TYPE; mismatched types panic
//     ERR_TYPE. (Admiral matches Python here — no implicit list↔tuple
//     promotion across `+`.)
//   - For LIST/TUPLE the new element count must fit in 7 bits (≤127),
//     else ERR_OOM. Strings can be up to 255 bytes total.
// V4'.
// -----------------------------------------------------------------------------
array_merge:
    preamble_args(2, 0)               // RS: [a, b]

    // Validate types and stash the (output) type in B6.
    rs_peek_at(W0, 1)
    ldy #H_TYPE
    lda (W0),y
    sta B6                            // B6 = a.type (also output type)
    rs_peek_at(W1, 0)
    ldy #H_TYPE                       // rs_peek_at clobbered Y — restore.
    lda (W1),y
    cmp B6
    beq !ok+
    jmp _amrg_type_err
!ok:

    lda B6
    cmp #TYPE_STR
    beq _amrg_type_ok
    cmp #TYPE_LIST
    beq _amrg_type_ok
    cmp #TYPE_TUPLE
    beq _amrg_type_ok
    jmp _amrg_type_err
_amrg_type_ok:

    // Read both element counts (low byte of O_LEN).
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2                // A = a.O_LEN low
    sta B4                            // B4 = a_count
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2                // A = b.O_LEN low
    sta B5                            // B5 = b_count

    // Dispatch on type for the alloc.
    lda B6
    cmp #TYPE_STR
    beq _amrg_alloc_str

    // LIST/TUPLE: total elements = B4+B5 (must fit in 7 bits).
    clc
    lda B4
    adc B5
    cmp #128
    bcc !ok+
    jmp _amrg_overflow
!ok:
    ldx #TYPE_LIST
    jsr _array_alloc_init             // RV = new list, O_LEN = a+b, payload zeroed.

    // If a was a TUPLE, mutate H_TYPE of the new handle to TYPE_TUPLE.
    lda B6
    cmp #TYPE_TUPLE
    bne _amrg_to_bytes
    ldy #H_TYPE
    sta (RV),y
_amrg_to_bytes:
    // Convert element counts to byte counts (×2 for handle slots).
    asl B4
    asl B5
    jmp _amrg_do_copy

_amrg_alloc_str:
    // STR: ALLOC_SIZE = a.len + b.len (16-bit add).
    clc
    lda B4
    adc B5
    sta ALLOC_SIZE
    lda #0
    adc #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                          // RV = new TYPE_STR; O_LEN already = total.

_amrg_do_copy:
    // dst = RV.H_PTR + O_HEADER, in W2.
    ldy #H_PTR
    lda (RV),y
    sta W2
    iny
    lda (RV),y
    sta W2+1
    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:

    // Phase 1: copy B4 bytes from a's payload to W2.
    rs_peek_at(W0, 1)
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
    bcc !+
    inc W3+1
!:
    ldy #0
_amrg_loop_a:
    cpy B4
    beq _amrg_a_done
    lda (W3),y
    sta (W2),y
    iny
    bne _amrg_loop_a
_amrg_a_done:
    // Advance dst (W2) by B4.
    tya
    clc
    adc W2
    sta W2
    bcc !+
    inc W2+1
!:

    // Phase 2: copy B5 bytes from b's payload.
    rs_peek_at(W0, 0)
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
    bcc !+
    inc W3+1
!:
    ldy #0
_amrg_loop_b:
    cpy B5
    beq _amrg_b_done
    lda (W3),y
    sta (W2),y
    iny
    bne _amrg_loop_b
_amrg_b_done:
    jmp postamble

_amrg_overflow:
    lda #ERR_OOM
    sta ERROR_CODE
    jmp error_handler
_amrg_type_err:
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

// -----------------------------------------------------------------------------
// array_repeat — repeat a container's payload N times.
//
//   in:  RS [container, n_int] — container is deeper, INT count is top.
//   out: RV = new container; payload = container.payload concatenated N times.
//        Args consumed.
//
// Negative N (or zero) yields an empty container of the same type. N's
// payload high byte and sign are honored: any negative magnitude → empty.
// LIST/TUPLE total elements must still fit in 7 bits.
// V4'.
// -----------------------------------------------------------------------------
array_repeat:
    preamble_args(2, 0)               // RS: [container, n]

    // Validate n is INT or BOOL. Anything else panics ERR_TYPE — repeat by
    // a non-integral count is meaningless.
    rs_peek_at(W0, 0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq _arep_n_type_ok
    cmp #TYPE_BOOL
    beq _arep_n_type_ok
    jmp _arep_type_err
_arep_n_type_ok:

    // Read N. Negative or zero → empty result.
    jsr deref_W0_to_W2                // A = O_LEN, W2 = payload
    sta B7                            // B7 = O_LEN of the int (used for sign byte)
    beq _arep_n_zero
    jsr sign_byte_W2                  // A = $FF if negative
    bmi _arep_n_zero
    // Positive non-empty int: low byte = N.
    ldy #0
    lda (W2),y
    sta B5
    bne _arep_have_n                  // N > 0
_arep_n_zero:
    lda #0
    sta B5
_arep_have_n:

    // Read container type (B6) and validate.
    rs_peek_at(W0, 1)
    ldy #H_TYPE
    lda (W0),y
    sta B6
    cmp #TYPE_STR
    beq _arep_type_ok
    cmp #TYPE_LIST
    beq _arep_type_ok
    cmp #TYPE_TUPLE
    beq _arep_type_ok
    jmp _arep_type_err
_arep_type_ok:

    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2                // A = container.O_LEN low
    sta B4                            // B4 = per-iter element count

    // total_count = B4 * B5 → 16-bit B0:B1.
    lda #0
    sta B0
    sta B1
    ldx B5
    beq _arep_alloc                   // N=0 → empty
_arep_mul_loop:
    clc
    lda B0
    adc B4
    sta B0
    bcc !+
    inc B1
!:
    dex
    bne _arep_mul_loop

_arep_alloc:
    lda B6
    cmp #TYPE_STR
    beq _arep_alloc_str

    // LIST/TUPLE: B0 ≤ 127 and B1 == 0 required.
    lda B1
    beq !ok+
    jmp _arep_overflow
!ok:
    lda B0
    cmp #128
    bcc !ok+
    jmp _arep_overflow
!ok:
    ldx #TYPE_LIST
    jsr _array_alloc_init             // RV = new list

    lda B6
    cmp #TYPE_TUPLE
    bne _arep_to_bytes
    ldy #H_TYPE
    sta (RV),y
_arep_to_bytes:
    // Element counts → byte counts.
    asl B4                            // per-iter bytes (8-bit)
    asl B0                            // total bytes lo
    rol B1                            // total bytes hi (carry from B0's asl)
    jmp _arep_do_copy

_arep_alloc_str:
    lda B0
    sta ALLOC_SIZE
    lda B1
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc

_arep_do_copy:
    // dst = RV.H_PTR + O_HEADER (in W2).
    ldy #H_PTR
    lda (RV),y
    sta W2
    iny
    lda (RV),y
    sta W2+1
    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:

    // If N == 0, nothing to copy.
    lda B5
    beq _arep_done

_arep_outer:
    // src = container.H_PTR + O_HEADER (re-read each iter; container doesn't
    // move during this loop, but cheap to re-read).
    rs_peek_at(W0, 1)
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
    bcc !+
    inc W3+1
!:
    ldy #0
_arep_inner:
    cpy B4
    beq _arep_inner_done
    lda (W3),y
    sta (W2),y
    iny
    bne _arep_inner
_arep_inner_done:
    // Advance dst by per-iter byte count (B4).
    tya
    clc
    adc W2
    sta W2
    bcc !+
    inc W2+1
!:
    dec B5
    bne _arep_outer
_arep_done:
    jmp postamble

_arep_overflow:
    lda #ERR_OOM
    sta ERROR_CODE
    jmp error_handler
_arep_type_err:
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

// -----------------------------------------------------------------------------
// array_find — linear scan for an element by value (`needle in container`).
// Caller supplies a TYPE_LIST or TYPE_TUPLE on top of RS and the candidate
// element below it. Element comparison goes through `val_eq`, so it works
// across the value-equality groups (int↔bool, str↔str, container↔container).
//
// in:  RS — needle (deeper), container (top).
// out: A = 1 if any container[i] is val_eq-equal to needle, else 0.
//      Args consumed.
// V4'.
// -----------------------------------------------------------------------------
array_find:
    preamble_args(2, 0)

    rs_peek_at(W0, 0)                 // W0 = container
    jsr deref_W0_to_W2                // A = O_LEN, W2 = payload base
    sta B0                            // B0 = element count

    lda #0
    sta B1                            // B1 = current index

_afind_loop:
    lda B1
    cmp B0
    bcs _afind_not_found              // B1 >= B0

    // W3 = container.payload[B1] (a handle word at offset 2*B1).
    lda B1
    asl
    tay
    lda (W2),y
    sta W3
    iny
    lda (W2),y
    sta W3+1

    // val_eq(needle, element). Push both; val_eq consumes them.
    rs_peek_at(W0, 1)                 // needle
    rs_push(W0)
    rs_push(W3)
    jsr val_eq                        // A = 1 if equal, else 0
    cmp #0
    bne _afind_found

    // val_eq's V4' frame restored W2 (its caller's value), but did GC happen?
    // No — val_eq doesn't allocate. W2 still points at our container payload.
    inc B1
    jmp _afind_loop

_afind_found:
    lda #1
    jmp postamble
_afind_not_found:
    lda #0
    jmp postamble
