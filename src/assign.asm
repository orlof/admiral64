// -----------------------------------------------------------------------------
// assign.asm — runtime support for admiral-style deferred-eval evaluation.
//
// Lazy handle types (defs.asm):
//   TYPE_NAME   — a bare name reference. eval → scope_get(name).
//   TYPE_REF    — `obj.attr`. Payload = (receiver, name_str). 2-handle array.
//                  eval → dict_get_proto(receiver, name).
//                  assign → dict_set(receiver, name, value).
//   TYPE_SUB    — `obj[i]`. Payload = (container, index). 2-handle array.
//                  eval → list/dict_get(container, index).
//                  assign → list/dict_set(container, index, value).
//   TYPE_TUPLE  — used both as a value and as an LHS pattern. assign on a
//                  tuple recursively unpacks the corresponding RHS sequence.
//
// GC: TYPE_REF / TYPE_SUB use the same 2-handle payload shape as a 2-tuple,
// so gc_mark walks them via the existing tuple tracer.
//
// `eval` is the universal "give me a value" call — it's idempotent on
// already-evaluated handles (TYPE_INT, TYPE_LIST, ...) so call sites can
// be sprinkled defensively without worrying about double-eval.
//
// `assign` consumes a target handle (TYPE_NAME / TYPE_REF / TYPE_SUB /
// TYPE_TUPLE) and a value handle. For TYPE_TUPLE targets, it arity-checks
// against the value's payload and recursively assigns each pair, so
// `a, (b, c) = (1, (2, 3))` works in a single call.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"
#import "array.asm"
#import "scope.asm"
#import "dict.asm"

// =============================================================================
// alloc_ref — allocate a TYPE_REF for `receiver.name`.
//   in:  RS depth 1 = receiver, depth 0 = name.
//   out: RV = new TYPE_REF handle. Args consumed.
// V4'.
// =============================================================================
alloc_ref:
    preamble_args(2, 0)
    lda #2
    ldx #TYPE_REF
    jsr _array_alloc_init
    jmp _altgt_finish

// =============================================================================
// alloc_sub — allocate a TYPE_SUB for `container[index]`.
//   in:  RS depth 1 = container, depth 0 = index.
//   out: RV = new TYPE_SUB handle. Args consumed.
// V4'.
// =============================================================================
alloc_sub:
    preamble_args(2, 0)
    lda #2
    ldx #TYPE_SUB
    jsr _array_alloc_init

_altgt_finish:
    rs_push(RV)
    lda RV
    sta W0
    lda RV+1
    sta W0+1

    rs_peek_at(W1, 2)
    lda #0
    jsr tuple_set_leaf

    rs_peek_at(W1, 1)
    lda #1
    jsr tuple_set_leaf

    jmp postamble

// =============================================================================
// eval — universal "force this handle into a concrete value". Idempotent on
// already-evaluated types so call sites can be sprinkled freely.
//   in:  RS top: handle.
//   out: RV = value handle. Arg consumed.
//
// Dispatch:
//   TYPE_NAME   → scope_get(name)
//   TYPE_REF    → dict_get_proto(receiver, name)
//   TYPE_SUB    → list_get / dict_get on (container, index)
//   anything else → return as-is (no-op).
//
// Negative integer indices on list/tuple containers normalize to len+i,
// matching Python semantics (`a[-1]`).
// V4'.
// =============================================================================
eval:
    preamble_args(1, 0)
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y

    cmp #TYPE_NAME
    bne !next+
    jmp _ev_name
!next:
    cmp #TYPE_REF
    bne !next+
    jmp _ev_ref
!next:
    cmp #TYPE_SUB
    bne !next+
    jmp _ev_sub
!next:
    cmp #TYPE_TUPLE
    bne !next+
    jmp _ev_tuple
!next:
    // Already a value — return it unchanged.
    jmp postamble_pop_rv

_ev_name:
    // RS top = name (TYPE_NAME, raw byte payload). scope_get takes RS
    // top = name and returns RV = value.
    jsr scope_get                    // consumes 1
    jmp postamble

_ev_ref:
    rs_pop(W0)                       // W0 = REF handle
    jsr deref_W0_to_W2               // W2 = (receiver, name)

    ldy #0
    lda (W2),y
    sta W0
    iny
    lda (W2),y
    sta W0+1
    iny
    lda (W2),y
    sta W1
    iny
    lda (W2),y
    sta W1+1

    rs_push(W0)
    rs_push(W1)
    jsr dict_get_proto               // consumes 2; RV = value or NONE
    jmp postamble

_ev_sub:
    rs_pop(W0)                       // W0 = SUB handle
    jsr deref_W0_to_W2               // W2 = (container, index)

    ldy #0
    lda (W2),y
    sta W0
    iny
    lda (W2),y
    sta W0+1
    iny
    lda (W2),y
    sta W1
    iny
    lda (W2),y
    sta W1+1

    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_DICT
    beq _ev_sub_dict
    cmp #TYPE_LIST
    beq _ev_sub_arr
    cmp #TYPE_TUPLE
    beq _ev_sub_arr
    cmp #TYPE_STR
    beq _ev_sub_str
    jmp panic_type

_ev_sub_dict:
    rs_push(W0)
    rs_push(W1)
    jsr dict_get_proto
    jmp postamble

_ev_sub_arr:
    // Extract int index as a 16-bit signed value, normalize negatives.
    // Read int's first byte into B5 (low) and second byte (or sign-ext) into
    // B6 (high). Then if MSB of B6 is set, idx += container length.
    ldy #H_PTR
    lda (W1),y
    sta W2
    iny
    lda (W1),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    pha                              // save int length across ptr advance
    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:
    ldy #0
    lda (W2),y
    sta B5                           // B5 = idx low byte
    pla                              // A = int length
    cmp #1
    beq _ev_sub_idx_1byte
    iny
    lda (W2),y
    sta B6                           // B6 = idx high byte (from int payload)
    jmp _ev_sub_idx_check
_ev_sub_idx_1byte:
    // 1-byte int: sign-extend low byte to fill high.
    lda B5
    bmi !neg+
    lda #0
    bpl !done+
!neg:
    lda #$FF
!done:
    sta B6
_ev_sub_idx_check:
    // B5:B6 = signed 16-bit index. Negative → add container length.
    lda B6
    bpl _ev_sub_idx_pos
    jsr deref_W0_to_W2               // A:X = container O_LEN word
    clc
    adc B5
    sta B5
    txa
    adc B6
    sta B6
_ev_sub_idx_pos:
    lda B5
    sta W2
    lda B6
    sta W2+1
    fs_push(W2)

    rs_push(W0)
    jsr array_get
    jmp postamble

_ev_sub_str:
    // STR subscript: read 1 byte at the (possibly-negative) 16-bit index and
    // alloc a fresh 1-char TYPE_STR. The container handle is rooted on RS so
    // it survives the alloc's potential GC.
    rs_push(W0)                      // RS: [..., container]

    // Read int subscript (W1) into signed 16-bit (B5:B6).
    ldy #H_PTR
    lda (W1),y
    sta W2
    iny
    lda (W1),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    pha                              // save int O_LEN low across ptr advance
    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:
    ldy #0
    lda (W2),y
    sta B5                           // B5 = idx low
    pla
    cmp #1
    beq _ev_sub_str_1byte
    iny
    lda (W2),y
    sta B6                           // B6 = idx high (2-byte int)
    jmp _ev_sub_str_idx_check
_ev_sub_str_1byte:
    lda B5
    bmi !neg+
    lda #0
    bpl !done+
!neg:
    lda #$FF
!done:
    sta B6
_ev_sub_str_idx_check:
    lda B6
    bpl _ev_sub_str_idx_pos
    jsr deref_W0_to_W2               // A:X = container O_LEN word
    clc
    adc B5
    sta B5
    txa
    adc B6
    sta B6
_ev_sub_str_idx_pos:

    // Alloc 1-byte TYPE_STR.
    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                        // RV = new 1-byte STR

    // Re-deref container after alloc (GC may have moved it).
    rs_peek(W0)
    jsr deref_W0_to_W2               // W2 = container payload
    // W2 += B5:B6 to point at the indexed byte.
    clc
    lda W2
    adc B5
    sta W2
    lda W2+1
    adc B6
    sta W2+1
    ldy #0
    lda (W2),y
    sta B5                           // stash byte (W2 about to be overwritten)

    // Write to RV.payload[0].
    ldy #H_PTR
    lda (RV),y
    sta W3
    iny
    lda (RV),y
    sta W3+1
    ldy #O_HEADER
    lda B5
    sta (W3),y
    jmp postamble

// _ev_tuple — force every element in-place. After this, the tuple holds value
// handles instead of lazy ones. Idempotent (TYPE_INT etc. eval to themselves).
//
// Mirrors admiral's :eval_tuple at parser.dasm16's eval dispatch — see
// stdlib.dasm16:259 in the DCPU port.
_ev_tuple:
    rs_peek(W0)                       // W0 = tuple handle
    jsr deref_W0_to_W2                // A:X = O_LEN word, W2 = payload
    sta B0
    stx B1                            // B0:B1 = N (word)

    lda #0
    sta B2
    sta B3                            // B2:B3 = i (word)

_ev_tup_loop:
    // Loop while i < N (16-bit unsigned compare).
    lda B2
    cmp B0
    lda B3
    sbc B1
    bcs _ev_tup_done

    // W3 = payload + 2*i.
    lda B2
    asl
    sta W3
    lda B3
    rol
    sta W3+1
    clc
    lda W3
    adc W2
    sta W3
    lda W3+1
    adc W2+1
    sta W3+1

    // Load tuple[i] → W1.
    ldy #0
    lda (W3),y
    sta W1
    iny
    lda (W3),y
    sta W1+1

    rs_push(W1)
    jsr eval                          // RV = forced value (consumes 1)

    // Re-deref tuple (eval may alloc).
    rs_peek(W0)
    jsr deref_W0_to_W2

    // W3 = payload + 2*i (recompute — W2 just refreshed).
    lda B2
    asl
    sta W3
    lda B3
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
    lda RV
    sta (W3),y
    iny
    lda RV+1
    sta (W3),y

    // i++ (16-bit).
    inc B2
    bne !+
    inc B3
!:
    jmp _ev_tup_loop

_ev_tup_done:
    jmp postamble_pop_rv               // RV = the tuple itself

// =============================================================================
// assign — generic lvalue write. Dispatches on target's H_TYPE.
//   in:  RS depth 1 = target, depth 0 = value.
//   out: side effect; both args consumed.
//
//   TYPE_NAME / TYPE_STR → scope_set(name, value)
//   TYPE_REF             → dict_set(receiver, name, value)
//   TYPE_SUB             → list_set or dict_set
//   TYPE_TUPLE           → arity-check & recurse pairwise
//   else                 → ERR_TYPE.
// V4'.
// =============================================================================
assign:
    preamble_args(2, 0)

    rs_peek_at(W0, 1)
    ldy #H_TYPE
    lda (W0),y

    cmp #TYPE_NAME
    bne !next+
    jmp _as_str
!next:
    cmp #TYPE_STR
    bne !next+
    jmp _as_str
!next:
    cmp #TYPE_REF
    bne !next+
    jmp _as_ref
!next:
    cmp #TYPE_SUB
    bne !next+
    jmp _as_sub
!next:
    cmp #TYPE_TUPLE
    bne !err+
    jmp _as_tuple
!err:
    jmp panic_type

_as_str:
    // RS already in scope_set order: [name, value].
    jsr scope_set
    jmp postamble

_as_ref:
    rs_pop(W3)                       // W3 = value
    rs_pop(W0)                       // W0 = REF target
    jsr deref_W0_to_W2

    ldy #0
    lda (W2),y
    sta W0
    iny
    lda (W2),y
    sta W0+1
    iny
    lda (W2),y
    sta W1
    iny
    lda (W2),y
    sta W1+1

    rs_push(W0)
    rs_push(W1)
    rs_push(W3)
    jsr dict_set
    jmp postamble

_as_sub:
    rs_pop(W3)                       // W3 = value
    rs_pop(W0)                       // W0 = SUB target
    jsr deref_W0_to_W2

    ldy #0
    lda (W2),y
    sta W0
    iny
    lda (W2),y
    sta W0+1
    iny
    lda (W2),y
    sta W1
    iny
    lda (W2),y
    sta W1+1

    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_LIST
    beq _as_sub_list
    cmp #TYPE_DICT
    beq _as_sub_dict
    jmp panic_type

_as_sub_list:
    // Read int subscript (W1) into signed 16-bit (B5:B6); negative → add
    // container O_LEN.
    ldy #H_PTR
    lda (W1),y
    sta W2
    iny
    lda (W1),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    pha                              // int O_LEN low
    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:
    ldy #0
    lda (W2),y
    sta B5
    pla
    cmp #1
    beq _as_sub_list_1byte
    iny
    lda (W2),y
    sta B6
    jmp _as_sub_list_idx_check
_as_sub_list_1byte:
    lda B5
    bmi !neg+
    lda #0
    bpl !done+
!neg:
    lda #$FF
!done:
    sta B6
_as_sub_list_idx_check:
    lda B6
    bpl _as_sub_idx_pos
    jsr deref_W0_to_W2
    clc
    adc B5
    sta B5
    txa
    adc B6
    sta B6
_as_sub_idx_pos:
    lda B5
    sta W2
    lda B6
    sta W2+1
    fs_push(W2)

    rs_push(W0)
    rs_push(W3)
    jsr list_set
    jmp postamble

_as_sub_dict:
    rs_push(W0)
    rs_push(W1)
    rs_push(W3)
    jsr dict_set
    jmp postamble

_as_tuple:
    rs_peek_at(W0, 0)                // value
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_TUPLE
    beq _as_tup_lens
    cmp #TYPE_LIST
    beq _as_tup_lens
    jmp panic_type

_as_tup_lens:
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    sta B0
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    cmp B0
    beq _as_tup_loop_init
    jmp panic_arity

_as_tup_loop_init:
    lda #0
    sta B1

_as_tup_loop:
    lda B1
    cmp B0
    beq _as_tup_done

    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    lda B1
    asl
    tay
    lda (W2),y
    sta W3
    iny
    lda (W2),y
    sta W3+1

    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    lda B1
    asl
    tay
    lda (W2),y
    sta W1
    iny
    lda (W2),y
    sta W1+1

    rs_push(W3)
    rs_push(W1)
    jsr assign

    inc B1
    jmp _as_tup_loop

_as_tup_done:
    jmp postamble
