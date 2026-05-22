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
// _array_alloc_init_w — word-N variant. Same job as _array_alloc_init but takes
// element count from B0:B1 (16-bit). Used by callers that need >127 elements.
//
//   in:  B0:B1 = N (0..32767), X = type tag
//   out: RV = new handle. Object's O_LEN = N. Payload zeroed.
//   clobbers: A, X, Y, W2, W3, B0:B1, B2:B3
// -----------------------------------------------------------------------------
_array_alloc_init_w:
    stx ALLOC_TYPE
    lda B0
    asl
    sta ALLOC_SIZE
    lda B1
    rol
    sta ALLOC_SIZE+1
    jsr alloc

    ldy #H_PTR
    lda (RV),y
    sta W2
    iny
    lda (RV),y
    sta W2+1
    ldy #O_LEN
    lda B0
    sta (W2),y
    iny
    lda B1
    sta (W2),y

    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:
    lda B0
    asl
    sta B2
    lda B1
    rol
    sta B3
_aaiw_zero_loop:
    lda B2
    ora B3
    beq _aaiw_done
    lda #0
    ldy #0
    sta (W2),y
    jsr inc_w2_w
    lda B2
    bne !+
    dec B3
!:
    dec B2
    jmp _aaiw_zero_loop
_aaiw_done:
    rts

// -----------------------------------------------------------------------------
// array_get / tuple_get / list_get — fetch handle at slot i.
//   in:  RS top: container handle. FS top: index (word).
//   out: RV = child handle (0 if slot unset). Args consumed.
// -----------------------------------------------------------------------------
array_get:
tuple_get:
list_get:
    preamble_args(1, 1)

    rs_peek_at(W0, 0)
    fs_peek_arg(W1, 0)           // W1 = index word
    jsr deref_W0_to_W2           // W2 = payload (post-header)

    // W3 = W2 + 2*W1 (16-bit pointer to slot).
    lda W1
    asl
    sta W3
    lda W1+1
    rol
    sta W3+1
    clc
    lda W3
    adc W2
    sta W3
    lda W3+1
    adc W2+1
    sta W3+1
    ldy #0
    lda (W3),y
    sta RV
    iny
    lda (W3),y
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
//   array_set_leaf / tuple_set_leaf:    W0=container, W1=child, A=index (0..127)
//   array_set_leaf_w / tuple_set_leaf_w: W0=container, W1=child, A:X = index word
//
//   out: container payload at the given index holds W1
//   clobbers: A, X, Y, W2, W3 (W0 / W1 preserved)
// -----------------------------------------------------------------------------
array_set_leaf:
tuple_set_leaf:
    ldx #0                       // X = high byte of index = 0 for byte caller
    // fall through
array_set_leaf_w:
tuple_set_leaf_w:
    sta W3                       // W3 = 2 * index (byte offset into payload)
    stx W3+1
    asl W3
    rol W3+1
    jsr deref_W0_to_W2           // W2 = payload base; A:X clobbered (length)
    clc
    lda W2
    adc W3
    sta W3
    lda W2+1
    adc W3+1
    sta W3+1                     // W3 = payload + 2*index
    ldy #0
    lda W1
    sta (W3),y
    iny
    lda W1+1
    sta (W3),y
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

    // Read O_LEN word into B0:B1.
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    sta B0
    iny
    lda (W2),y
    sta B1                       // B0:B1 = O_LEN word

    // need = 2*(O_LEN + 1) + O_HEADER (16-bit).
    clc
    lda B0
    adc #1
    sta B2
    lda B1
    adc #0
    sta B3
    asl B2
    rol B3
    clc
    lda B2
    adc #O_HEADER
    sta B2
    lda B3
    adc #0
    sta B3

    // If H_SIZE >= need, we have room.
    ldy #H_SIZE
    sec
    lda (W0),y
    sbc B2
    iny
    lda (W0),y
    sbc B3
    bcs aap_have_room

    jsr _array_grow
    jmp aap_retry

aap_have_room:
    // Write child at slot index = old O_LEN (B0:B1, word).
    rs_peek_at(W0, 1)
    rs_peek_at(W1, 0)
    lda B0
    ldx B1
    jsr array_set_leaf_w

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
    sta B0
    iny
    lda (W2),y
    sta B1                       // B0:B1 = O_LEN word

    // need = 2*(O_LEN+1) + O_HEADER (16-bit) into B2:B3.
    clc
    lda B0
    adc #1
    sta B2
    lda B1
    adc #0
    sta B3
    asl B2
    rol B3
    clc
    lda B2
    adc #O_HEADER
    sta B2
    lda B3
    adc #0
    sta B3

    ldy #H_SIZE
    sec
    lda (W0),y
    sbc B2
    iny
    lda (W0),y
    sbc B3
    bcs ains_have_room

    jsr _array_grow
    jmp ains_retry

ains_have_room:
    // Read raw index from FS (word).
    fs_peek_arg(W1, 0)

    // Clip: if W1 > O_LEN, set W1 = O_LEN. Compare W1 vs B0:B1.
    sec
    lda B0
    sbc W1
    lda B1
    sbc W1+1
    bcs ains_idx_ok              // O_LEN >= W1 → no clip
    lda B0
    sta W1
    lda B1
    sta W1+1
ains_idx_ok:

    // Stash clipped index in B6:B7 (survives across the shift call which
    // clobbers B0..B5).
    lda W1
    sta B6
    lda W1+1
    sta B7

    // Shift only if W1 < O_LEN. (W1 already clipped to ≤ O_LEN.)
    lda W1
    cmp B0
    bne ains_do_shift
    lda W1+1
    cmp B1
    beq ains_no_shift

ains_do_shift:
    rs_peek_at(W0, 1)
    lda B6
    ldx B7
    jsr _array_shift_up_leaf_w

ains_no_shift:
    rs_peek_at(W0, 1)
    rs_peek_at(W1, 0)
    lda B6
    ldx B7
    jsr array_set_leaf_w

    jsr _array_inc_o_len_at_rs1

    jmp postamble

// -----------------------------------------------------------------------------
// array_del / list_del — remove element at slot `index`, shifting subsequent
// elements down. O_LEN -= 1. If index ≥ O_LEN, no-op.
//   in:  RS: container. FS: index (word).
// -----------------------------------------------------------------------------
array_del:
list_del:
    preamble_args(1, 1)

    rs_peek_at(W0, 0)
    fs_peek_arg(W1, 0)           // W1 = index word (already 16-bit)

    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    sta B0
    iny
    lda (W2),y
    sta B1                       // B0:B1 = O_LEN word

    // 16-bit unsigned compare: index >= O_LEN → no-op.
    lda W1+1
    cmp B1
    bcc _adel_in_range
    bne adel_done
    lda W1
    cmp B0
    bcs adel_done
_adel_in_range:
    lda W1
    sta B6
    lda W1+1
    sta B7                       // B6:B7 = index word (survives shift call)

    rs_peek_at(W0, 0)
    lda B6
    ldx B7
    jsr _array_shift_down_leaf_w

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
// [index..O_LEN-1] to [index+1..O_LEN]. Backward byte copy.
//
//   _array_shift_up_leaf:    W0=container, A=index (byte legacy entry).
//   _array_shift_up_leaf_w:  W0=container, A:X=index word.
//   Slot at O_LEN must be reserved (capacity ≥ O_LEN+1 — caller verified).
//   clobbers: A, X, Y, W2, W3, B0:B5 (W0, W1, B6, B7 preserved)
// -----------------------------------------------------------------------------
_array_shift_up_leaf:
    ldx #0
    // fall through
_array_shift_up_leaf_w:
    sta B0
    stx B1                       // B0:B1 = index word
    jsr deref_W0_to_W2           // W2 = payload base, A:X = O_LEN word
    sta B2
    stx B3                       // B2:B3 = O_LEN word

    // count_elements = O_LEN - index. If 0 → done.
    sec
    lda B2
    sbc B0
    sta B4
    lda B3
    sbc B1
    sta B5
    lda B4
    ora B5
    beq _asu_done

    // count_bytes = 2 * count_elements (16-bit shift left).
    asl B4
    rol B5

    // W2 = src_end = payload + 2*O_LEN. Use W3 as scratch for 2*O_LEN.
    lda B2
    asl
    sta W3
    lda B3
    rol
    sta W3+1
    clc
    lda W2
    adc W3
    sta W2
    lda W2+1
    adc W3+1
    sta W2+1                     // W2 = payload + 2*O_LEN

    // W3 = dst_end = W2 + 2.
    clc
    lda W2
    adc #2
    sta W3
    lda W2+1
    adc #0
    sta W3+1

_asu_loop:
    lda B4
    ora B5
    beq _asu_done
    // dec W2 (src), then dec W3 (dst), then copy.
    lda W2
    bne !+
    dec W2+1
!:
    dec W2
    lda W3
    bne !+
    dec W3+1
!:
    dec W3
    ldy #0
    lda (W2),y
    sta (W3),y
    lda B4
    bne !+
    dec B5
!:
    dec B4
    jmp _asu_loop
_asu_done:
    rts

// -----------------------------------------------------------------------------
// _array_shift_down_leaf — close the gap left by deleting slot `index` by
// sliding elements [index+1..O_LEN-1] down to [index..O_LEN-2]. Forward
// byte copy.
//
//   _array_shift_down_leaf:    W0=container, A=index (byte legacy entry).
//   _array_shift_down_leaf_w:  W0=container, A:X=index word.
//   clobbers: A, X, Y, W2, W3, B0:B5 (W0, W1, B6, B7 preserved)
// -----------------------------------------------------------------------------
_array_shift_down_leaf:
    ldx #0
    // fall through
_array_shift_down_leaf_w:
    sta B0
    stx B1                       // B0:B1 = index word
    jsr deref_W0_to_W2           // W2 = payload, A:X = O_LEN word
    sta B2
    stx B3                       // B2:B3 = O_LEN word

    // count_elements = O_LEN - 1 - index. If ≤0 → done.
    sec
    lda B2
    sbc #1
    sta B4
    lda B3
    sbc #0
    sta B5                       // B4:B5 = O_LEN - 1
    sec
    lda B4
    sbc B0
    sta B4
    lda B5
    sbc B1
    sta B5
    bcc _asd_done                // (O_LEN-1) - index < 0
    lda B4
    ora B5
    beq _asd_done                // count == 0

    // count_bytes = 2 * count_elements.
    asl B4
    rol B5

    // W3 = dst_ptr = payload + 2*index.
    lda B0
    asl
    sta W3
    lda B1
    rol
    sta W3+1
    clc
    lda W3
    adc W2
    sta W3
    lda W3+1
    adc W2+1
    sta W3+1                     // W3 = payload + 2*index

    // W2 = src_ptr = W3 + 2.
    clc
    lda W3
    adc #2
    sta W2
    lda W3+1
    adc #0
    sta W2+1

_asd_loop:
    lda B4
    ora B5
    beq _asd_done
    ldy #0
    lda (W2),y
    sta (W3),y
    jsr inc_w2_w
    jsr inc_w3_w
    lda B4
    bne !+
    dec B5
!:
    dec B4
    jmp _asd_loop
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
    // overwrite back to the live element count). 16-bit.
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    sta B2
    iny
    lda (W2),y
    sta B3                       // B2:B3 = saved O_LEN word

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
    lda B3
    sta (RV),y

    // Copy old elements: src = old + O_HEADER, dst = RV + O_HEADER,
    // count = 2 * (B2:B3) word. Forward copy is safe — regions disjoint.
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
    lda B3
    rol
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

    // Validate types and stash the (output) type in B6. TYPE_NAME and
    // TYPE_STR share their payload layout, so we normalize NAME→STR for
    // the type-equality check; the resulting handle is always TYPE_STR
    // when either input is string-shaped.
    rs_peek_at(W0, 1)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_NAME
    bne !s+
    lda #TYPE_STR
!s:
    sta B6                            // B6 = a.type (normalized; output type)
    rs_peek_at(W1, 0)
    ldy #H_TYPE                       // rs_peek_at clobbered Y — restore.
    lda (W1),y
    cmp #TYPE_NAME
    bne !s+
    lda #TYPE_STR
!s:
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

    // Read both element counts as 16-bit words.
    //   B4:B7 = a count
    //   B5:B3 = b count
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2                // A:X = a.O_LEN word
    sta B4
    stx B7
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2                // A:X = b.O_LEN word
    sta B5
    stx B3

    // Dispatch on type for the alloc.
    lda B6
    cmp #TYPE_STR
    beq _amrg_alloc_str

    // LIST/TUPLE: total = a + b. Each element is a 2-byte handle, so payload
    // bytes = 2 * total. Total must fit in 15 bits so 2*total fits a word.
    clc
    lda B4
    adc B5
    sta B0                            // B0:B1 = total elements (16-bit)
    lda B7
    adc B3
    sta B1
    bcc !ok+
    jmp _amrg_overflow                // 17-bit sum
!ok:
    lda B1
    bpl !ok+
    jmp _amrg_overflow                // high bit set → 2*total overflows
!ok:
    ldx #TYPE_LIST
    jsr _array_alloc_init_w           // B0:B1=N word, X=type. RV = new list.

    // If a was a TUPLE, mutate H_TYPE of the new handle to TYPE_TUPLE.
    lda B6
    cmp #TYPE_TUPLE
    bne _amrg_to_bytes
    ldy #H_TYPE
    sta (RV),y
_amrg_to_bytes:
    // Convert per-input element counts to byte counts (×2) — 16-bit shift.
    asl B4
    rol B7
    asl B5
    rol B3
    jmp _amrg_do_copy

_amrg_alloc_str:
    // STR: ALLOC_SIZE = a.len + b.len (16-bit add).
    clc
    lda B4
    adc B5
    sta ALLOC_SIZE
    lda B7
    adc B3
    sta ALLOC_SIZE+1
    bcc !ok+
    jmp _amrg_overflow
!ok:
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                          // RV = new TYPE_STR; O_LEN already = total.

_amrg_do_copy:
    jsr deref_RV_to_W2                // dst = RV's payload base

    // Phase 1: copy B4:B7 bytes from a's payload to W2 (16-bit count).
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W3                // src = a's payload base
_amrg_loop_a:
    lda B4
    ora B7
    beq _amrg_a_done
    ldy #0
    lda (W3),y
    sta (W2),y
    jsr inc_w2_w
    jsr inc_w3_w
    lda B4
    bne !+
    dec B7
!:
    dec B4
    jmp _amrg_loop_a
_amrg_a_done:

    // Phase 2: copy B5:B3 bytes from b's payload.
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W3                // src = b's payload base
_amrg_loop_b:
    lda B5
    ora B3
    beq _amrg_b_done
    ldy #0
    lda (W3),y
    sta (W2),y
    jsr inc_w2_w
    jsr inc_w3_w
    lda B5
    bne !+
    dec B3
!:
    dec B5
    jmp _amrg_loop_b
_amrg_b_done:
    jmp postamble

_amrg_overflow:
    jmp panic_oom
_amrg_type_err:
    jmp panic_type

// -----------------------------------------------------------------------------
// array_repeat — repeat a container's payload N times.
//
//   in:  RS [container, n_int] — container is deeper, INT count is top.
//   out: RV = new container; payload = container.payload concatenated N times.
//        Args consumed.
//
// Negative N yields an empty container of the same type. N is read as a
// 16-bit unsigned magnitude (0..32767); larger or negative ints panic
// ERR_OOM. LIST/TUPLE total bytes (2*elements) must fit a word; STR total
// must too.
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

    // Read N as a 16-bit unsigned multiplier in B5:B3 from the inline int in
    // W0. Negative → empty. Value >= 65536 (bytes 2/3 set) or >= 32768 (bit 15)
    // → overflow.
    ldy #3
    lda (W0),y
    bpl !pos+
    jmp _arep_n_zero                  // bit 31 set → negative → empty
!pos:
    ldy #2                            // bytes 2 and 3 must be zero (< 65536)
    lda (W0),y
    ldy #3
    ora (W0),y
    beq !lo+
    jmp _arep_overflow
!lo:
    ldy #1
    lda (W0),y
    bpl !ok+
    jmp _arep_overflow                // bit 15 set → ambiguous sign
!ok:
    sta B3                            // N high
    ldy #0
    lda (W0),y
    sta B5                            // N low
_arep_check_n:
    lda B5
    ora B3
    bne _arep_have_n
    jmp _arep_n_zero

_arep_n_zero:
    lda #0
    sta B5
    sta B3
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
    jsr deref_W0_to_W2                // A:X = container.O_LEN word
    sta B4                            // B4:B7 = per-iter element count
    stx B7

    // total_count = (B4:B7) * (B5:B3) → 16-bit B0:B1, repeated-add.
    // 16-bit multiplier: walk a copy in W3 down to zero (B5:B3 must survive
    // intact — outer copy loop iterates N times).
    lda #0
    sta B0
    sta B1
    lda B5
    sta W3
    lda B3
    sta W3+1
    ora W3
    beq _arep_alloc                   // N=0 → empty
_arep_mul_loop:
    clc
    lda B0
    adc B4
    sta B0
    lda B1
    adc B7
    sta B1
    bcc !+
    jmp _arep_overflow                // 17th-bit set
!:
    lda W3
    bne !+
    dec W3+1
!:
    dec W3
    lda W3
    ora W3+1
    bne _arep_mul_loop

_arep_alloc:
    lda B6
    cmp #TYPE_STR
    beq _arep_alloc_str

    // LIST/TUPLE: total fits 15 bits so 2*total fits a word.
    lda B1
    bpl !ok+
    jmp _arep_overflow
!ok:
    ldx #TYPE_LIST
    jsr _array_alloc_init_w           // B0:B1 = N, X = type. RV = new list.

    lda B6
    cmp #TYPE_TUPLE
    bne _arep_to_bytes
    ldy #H_TYPE
    sta (RV),y
_arep_to_bytes:
    // Element counts → byte counts (×2) — 16-bit shifts on per-iter and total.
    asl B4
    rol B7
    asl B0
    rol B1
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
    jsr deref_RV_to_W2                // dst = RV's payload base

    // If N == 0, nothing to copy.
    lda B5
    ora B3
    beq _arep_done

_arep_outer:
    // src = container's payload (re-read each iter to handle GC relocation
    // during the str_alloc / _array_alloc_init_w above).
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W3
    // Per-iter remaining count B2:B6 = copy of B4:B7 (decremented in inner).
    lda B4
    sta B2
    lda B7
    sta B6
_arep_inner:
    lda B2
    ora B6
    beq _arep_inner_done
    ldy #0
    lda (W3),y
    sta (W2),y
    jsr inc_w2_w
    jsr inc_w3_w
    lda B2
    bne !+
    dec B6
!:
    dec B2
    jmp _arep_inner
_arep_inner_done:
    lda B5
    bne !+
    dec B3
!:
    dec B5
    lda B5
    ora B3
    bne _arep_outer
_arep_done:
    jmp postamble

_arep_overflow:
    jmp panic_oom
_arep_type_err:
    jmp panic_type

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
    jsr deref_W0_to_W2                // A:X = O_LEN word, W2 = payload base
    sta B0                            // B0:B1 = remaining element count
    stx B1

_afind_loop:
    lda B0
    ora B1
    beq _afind_not_found

    // W3 = next container element (handle word at W2[0..1]).
    ldy #0
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

    // val_eq doesn't allocate (no GC), so W2 is still valid. Step W2 by 2
    // and decrement the 16-bit counter.
    clc
    lda W2
    adc #2
    sta W2
    bcc !+
    inc W2+1
!:
    jsr dec_b01_w
    jmp _afind_loop

_afind_found:
    jmp postamble_a_one
_afind_not_found:
    jmp postamble_a_zero
