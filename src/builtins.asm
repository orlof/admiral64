// -----------------------------------------------------------------------------
// Built-in functions, Stage 10 starter.
//
// Each built-in is:
//   1. A V4'-wrapped implementation routine (e.g., `builtin_len`).
//   2. A static TYPE_BUILTIN handle whose 2-byte payload IS the impl
//      address (read by `led_lparen` and JSR'd via SMC).
//   3. A static TYPE_STR holding the name; `parser_eval` binds the
//      builtin into `global_scope` at start so `range` / `len` resolve
//      via normal scope lookup.
//
// To add a new built-in:
//   a) Write the impl: V4', preamble_args(N, 0), body, postamble.
//   b) Add `BUILTIN_<NAME>:` static + `STR_NAME_<NAME>:` static.
//   c) Add a binding line in parser_eval's init.
//
// Note on `range`: returns a Python-2-style list, not an iterator. Works
// directly with our existing for-loop indexed iteration. Caps at N=255 for
// now (B-register is 8-bit; bigger N truncates silently).
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

// =============================================================================
// builtin_len(x) — element count for STR / LIST / TUPLE / DICT.
//   in:   1 RS arg = container.
//   out:  RV = TYPE_INT handle holding len.
// =============================================================================
builtin_len:
    preamble_args(1, 0)

    rs_peek(W0)
    jsr deref_W0_to_W2          // W2 = payload base, A = O_LEN low byte
    sta B0                       // length (low byte)

    // Allocate a 1-byte int for the length.
    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int                // RV = handle

    jsr deref_RV_to_W2           // W2 = result payload
    lda B0
    ldy #0
    sta (W2),y

    jmp postamble

// =============================================================================
// builtin_range(n) — list of integers 0..n-1.
//   in:   1 RS arg = n (TYPE_INT, low byte used; cap 255).
//   out:  RV = TYPE_LIST.
// =============================================================================
builtin_range:
    preamble_args(1, 0)

    rs_peek(W0)
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    sta B0                       // B0 = n

    // Empty list as the accumulator.
    lda #0
    jsr list_alloc               // RV = empty list
    rs_push(RV)                  // RS: [n_arg, list]

    lda #0
    sta B1                       // B1 = i

_brange_loop:
    lda B1
    cmp B0
    beq _brange_done

    // Allocate int(i) — 1 byte payload.
    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int                // RV = handle
    jsr deref_RV_to_W2           // W2 = payload
    lda B1
    ldy #0
    sta (W2),y

    // Append: rs_peek(list); rs_push(list); rs_push(int); jsr list_append.
    rs_peek(W0)                  // W0 = list (top)
    rs_push(W0)                  // RS: [..., list, list_copy]
    rs_push(RV)                  // RS: [..., list, list_copy, int]
    jsr list_append              // consumes 2 → RS: [..., list]

    inc B1
    jmp _brange_loop

_brange_done:
    rs_pop(RV)                   // RV = the assembled list
    jmp postamble

// =============================================================================
// builtin_bool(x) — coerce any value to TRUE/FALSE via val_truthy.
// =============================================================================
builtin_bool:
    preamble_args(1, 0)
    rs_peek(W0)
    jsr val_truthy               // A = 0 (falsy) or non-zero (truthy)
    cmp #0
    beq _bbool_false
    lda #<TRUE
    sta RV
    lda #>TRUE
    sta RV+1
    jmp postamble
_bbool_false:
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
    jmp postamble

// =============================================================================
// builtin_abs(x) — magnitude. INT/BOOL → INT (negate if negative).
// FLOAT → FLOAT (clear sign bit). Other types panic ERR_TYPE.
// =============================================================================
builtin_abs:
    preamble_args(1, 0)
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq _babs_int
    cmp #TYPE_BOOL
    beq _babs_passthrough        // bool is non-negative by construction
    cmp #TYPE_FLOAT
    beq _babs_float
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_babs_int:
    rs_peek(W0)
    jsr deref_W0_to_W2
    jsr sign_byte_W2             // A = $00 if non-neg, $FF if neg
    cmp #$00
    beq _babs_passthrough
    jsr int_negate               // consumes RS top, RV = magnitude
    jmp postamble

_babs_passthrough:
    rs_peek(RV)
    jmp postamble

_babs_float:
    // Packed MS-Basic float: byte 1 of payload holds (sign|mantissa-msb).
    // Bit 7 = sign. If clear, already non-negative.
    rs_peek(W0)
    jsr deref_W0_to_W2
    ldy #1
    lda (W2),y
    bpl _babs_passthrough
    jsr float_neg                // RV = -x (positive)
    jmp postamble

// =============================================================================
// builtin_chr(n) — INT/BOOL n → 1-byte TYPE_STR with payload = n & $FF.
// =============================================================================
builtin_chr:
    preamble_args(1, 0)
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq _bchr_ok
    cmp #TYPE_BOOL
    beq _bchr_ok
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler
_bchr_ok:
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    sta B0                       // B0 = char byte

    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                    // RV = new 1-byte STR

    jsr deref_RV_to_W2
    lda B0
    ldy #0
    sta (W2),y
    jmp postamble

// =============================================================================
// builtin_ord(s) — TYPE_STR of length 1 → INT of payload[0].
// Lengths other than 1 panic. High bytes get a 2-byte int so values 128-255
// stay non-negative.
// =============================================================================
builtin_ord:
    preamble_args(1, 0)
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq _bord_ok
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler
_bord_ok:
    jsr deref_W0_to_W2           // W2 = payload, A = O_LEN low
    cmp #1
    beq _bord_have
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler
_bord_have:
    ldy #0
    lda (W2),y
    sta B0
    bmi _bord_2byte

    // 0..127: 1-byte int (fits as positive).
    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int
    jsr deref_RV_to_W2
    lda B0
    ldy #0
    sta (W2),y
    jmp postamble

_bord_2byte:
    // 128..255: 2-byte int with high byte 0 keeps it positive.
    lda #2
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int
    jsr deref_RV_to_W2
    lda B0
    ldy #0
    sta (W2),y
    iny
    lda #0
    sta (W2),y
    jmp postamble

// =============================================================================
// builtin_int(x) — coerce STR / BOOL / FLOAT / INT to TYPE_INT.
//   STR   → parse leading optional `-` then decimal digits.
//   BOOL  → fresh 1-byte int with payload 0 or 1.
//   FLOAT → float_to_int (truncate toward zero — existing semantics).
//   INT   → return same handle (cheap).
// Empty / `-` only / non-numeric STRs are not validated; bad input gives bad
// output (mirrors int_parse_dec). Negative path uses int_negate.
// =============================================================================
builtin_int:
    preamble_args(1, 0)
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq _bint_passthrough
    cmp #TYPE_BOOL
    beq _bint_from_bool
    cmp #TYPE_FLOAT
    beq _bint_from_float
    cmp #TYPE_STR
    beq _bint_from_str
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_bint_passthrough:
    rs_peek(RV)
    jmp postamble

_bint_from_bool:
    rs_peek(W0)
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    sta B0

    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int
    jsr deref_RV_to_W2
    lda B0
    ldy #0
    sta (W2),y
    jmp postamble

_bint_from_float:
    jsr float_to_int                 // consumes RS top, RV = INT
    jmp postamble

_bint_from_str:
    rs_peek(W0)
    jsr deref_W0_to_W2               // W2 = payload, A = len
    sta B1                           // B1 = len
    beq _bint_value_error            // empty string

    lda #0
    sta B2                           // B2 = sign flag

    ldy #0
    lda (W2),y
    cmp #'-'
    bne _bint_str_no_sign
    inc B2
    inc W2
    bne !+
    inc W2+1
!:
    dec B1
    beq _bint_value_error            // string was just "-"
_bint_str_no_sign:
    lda W2
    sta W0
    lda W2+1
    sta W0+1
    lda B1
    jsr int_parse_dec                // RV = positive int

    lda B2
    beq _bint_str_done
    rs_push(RV)
    jsr int_negate                   // RV = negated
_bint_str_done:
    jmp postamble

_bint_value_error:
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

// =============================================================================
// builtin_float(x) — coerce INT / BOOL / FLOAT / STR to TYPE_FLOAT.
//   FLOAT → return same handle.
//   INT/BOOL → int_to_float.
//   STR → str_to_float (BASIC FIN).
// =============================================================================
builtin_float:
    preamble_args(1, 0)
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_FLOAT
    beq _bflt_passthrough
    cmp #TYPE_INT
    beq _bflt_from_int
    cmp #TYPE_BOOL
    beq _bflt_from_int                // bool's 1-byte payload reads correctly as int
    cmp #TYPE_STR
    beq _bflt_from_str
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_bflt_passthrough:
    rs_peek(RV)
    jmp postamble

_bflt_from_int:
    jsr int_to_float
    jmp postamble

_bflt_from_str:
    jsr str_to_float
    jmp postamble

// =============================================================================
// builtin_str(x) — render any value as a TYPE_STR.
//   STR   → same handle.
//   INT   → int_to_str.
//   FLOAT → float_to_str.
//   BOOL  → static STR_TRUE / STR_FALSE.
//   NONE  → static STR_NONE.
//   LIST  → "[e0, e1, ...]" — recursive str() per element.
//   TUPLE → "(e0, e1, ...)".
//   DICT  → "{k0: v0, ...}".
// =============================================================================
builtin_str:
    preamble_args(1, 0)
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y

    cmp #TYPE_STR
    beq _bstr_passthrough
    cmp #TYPE_INT
    beq _bstr_int
    cmp #TYPE_BOOL
    beq _bstr_bool
    cmp #TYPE_NONE
    beq _bstr_none
    cmp #TYPE_FLOAT
    beq _bstr_float
    cmp #TYPE_LIST
    beq !cont+
    cmp #TYPE_TUPLE
    beq !cont+
    cmp #TYPE_DICT
    beq !cont+
    jmp _bstr_type_err
!cont:
    cmp #TYPE_LIST
    bne !next+
    jmp _bstr_list
!next:
    cmp #TYPE_TUPLE
    bne !next+
    jmp _bstr_tuple
!next:
    jmp _bstr_dict
_bstr_type_err:
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_bstr_passthrough:
    rs_peek(RV)
    jmp postamble
_bstr_int:
    jsr int_to_str                   // consumes RS top, RV = STR
    jmp postamble
_bstr_float:
    jsr float_to_str
    jmp postamble
_bstr_bool:
    rs_peek(W0)
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    bne _bstr_bool_true
    lda #<STR_FALSE
    sta RV
    lda #>STR_FALSE
    sta RV+1
    jmp postamble
_bstr_bool_true:
    lda #<STR_TRUE
    sta RV
    lda #>STR_TRUE
    sta RV+1
    jmp postamble
_bstr_none:
    lda #<STR_NONE
    sta RV
    lda #>STR_NONE
    sta RV+1
    jmp postamble

_bstr_list:
    rs_push_const(STR_LBRACK)
    rs_push_const(STR_RBRACK)
    jsr _bstr_render_seq
    jmp postamble

_bstr_tuple:
    rs_push_const(STR_LPAREN)
    rs_push_const(STR_RPAREN)
    jsr _bstr_render_seq
    jmp postamble

_bstr_dict:
    jsr _bstr_render_dict
    jmp postamble

// -----------------------------------------------------------------------------
// _bstr_render_seq — render a LIST or TUPLE as "OPEN e0, e1, ... CLOSE".
//
// Caller arranges RS as: [container, open_str, close_str]. Container is
// builtin_str's V4' arg (already there); open/close are pushed by caller.
// On return: RV = rendered string. RS is left in an inconsistent state and
// is reclaimed by builtin_str's postamble (target_RSP based on its 1-arg
// preamble).
// -----------------------------------------------------------------------------
_bstr_render_seq:
    // Stash close in B6:B7 — pop it; open stays as the initial accum.
    rs_pop(W3)                        // close
    lda W3
    sta B6
    lda W3+1
    sta B7
    // RS now: [container, open]. The "open" handle becomes our accumulator.

    // Container length → B4 (low byte; assumes < 256 elements).
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    sta B4

    lda #0
    sta B5                            // index

_brs_loop:
    lda B5
    cmp B4
    bcc !go+
    jmp _brs_close
!go:

    // Fetch container[B5] handle → W3.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    lda B5
    asl
    tay
    lda (W2),y
    sta W3
    iny
    lda (W2),y
    sta W3+1

    // Recursive: builtin_str(element). Consumes 1 RS arg; RV = element_str.
    rs_push(W3)
    jsr builtin_str

    // accum ++= element_str. RS is [container, accum] (builtin_str consumed
    // its arg). We need [a, b] for array_merge: dup accum, push element_str.
    rs_peek(W3)
    rs_push(W3)                       // RS: [container, accum, accum_dup]
    rs_push(RV)                       // RS: [container, accum, accum_dup, elem]
    jsr array_merge                   // consumes top 2; RV = merged
    rs_pop(W3)                        // discard old accum
    rs_push(RV)                       // new accum

    // If not last, append ", ".
    lda B5
    clc
    adc #1
    cmp B4
    bcs _brs_no_sep
    rs_peek(W3)
    rs_push(W3)
    rs_push_const(STR_COMMA_SPACE)
    jsr array_merge
    rs_pop(W3)
    rs_push(RV)
_brs_no_sep:
    inc B5
    jmp _brs_loop

_brs_close:
    // Final: accum ++ close.
    rs_peek(W3)
    rs_push(W3)
    lda B6
    sta W3
    lda B7
    sta W3+1
    rs_push(W3)
    jsr array_merge                   // RV = final string
    rts

// -----------------------------------------------------------------------------
// _bstr_render_dict — render a TYPE_DICT as "{k0: v0, k1: v1, ...}".
//
// Each dict entry is a 2-tuple [key, value] in the payload. We render
// "key_str: value_str" per entry, separated by ", " — same outer pattern as
// _bstr_render_seq.
//
// Caller: builtin_str's body. RS slot 0 = dict (the V4' arg). On return RV
// = rendered string. RS is inconsistent; postamble cleans up.
// -----------------------------------------------------------------------------
_bstr_render_dict:
    rs_push_const(STR_LCURLY)         // RS: [dict, accum=`{`]

    // Length → B4.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    sta B4

    lda #0
    sta B5

_brd_loop:
    lda B5
    cmp B4
    bcc !go+
    jmp _brd_close
!go:

    // Fetch dict.payload[B5] = entry tuple handle → W3.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    lda B5
    asl
    tay
    lda (W2),y
    sta W3
    iny
    lda (W2),y
    sta W3+1

    // Get entry.payload[0] = key, entry.payload[1] = value.
    // Save W3 (entry) on RS as a GC root, then deref to read its payload.
    rs_push(W3)                       // RS: [dict, accum, entry]
    lda W3
    sta W0
    lda W3+1
    sta W0+1
    jsr deref_W0_to_W2                // W2 = entry payload
    ldy #0
    lda (W2),y
    sta B0
    iny
    lda (W2),y
    sta B1                             // B0:B1 = key handle
    iny
    lda (W2),y
    sta B2
    iny
    lda (W2),y
    sta B3                             // B2:B3 = value handle

    rs_pop(W3)                         // drop entry. RS: [dict, accum]

    // accum ++= str(key). builtin_str(key):
    lda B0
    sta W3
    lda B1
    sta W3+1
    rs_push(W3)
    jsr builtin_str                    // RV = key_str
    rs_peek(W3)
    rs_push(W3)
    rs_push(RV)
    jsr array_merge                    // RV = accum ++ key_str
    rs_pop(W3)
    rs_push(RV)

    // accum ++= ": ".
    rs_peek(W3)
    rs_push(W3)
    rs_push_const(STR_COLON_SPACE)
    jsr array_merge
    rs_pop(W3)
    rs_push(RV)

    // accum ++= str(value).
    lda B2
    sta W3
    lda B3
    sta W3+1
    rs_push(W3)
    jsr builtin_str                    // RV = value_str
    rs_peek(W3)
    rs_push(W3)
    rs_push(RV)
    jsr array_merge
    rs_pop(W3)
    rs_push(RV)

    // If not last, append ", ".
    lda B5
    clc
    adc #1
    cmp B4
    bcs _brd_no_sep
    rs_peek(W3)
    rs_push(W3)
    rs_push_const(STR_COMMA_SPACE)
    jsr array_merge
    rs_pop(W3)
    rs_push(RV)
_brd_no_sep:
    inc B5
    jmp _brd_loop

_brd_close:
    rs_peek(W3)
    rs_push(W3)
    rs_push_const(STR_RCURLY)
    jsr array_merge
    rts

// =============================================================================
// builtin_type(x) — return INT holding the H_TYPE tag byte.
// =============================================================================
builtin_type:
    preamble_args(1, 0)
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    sta B0

    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int
    jsr deref_RV_to_W2
    lda B0
    ldy #0
    sta (W2),y
    jmp postamble

// =============================================================================
// Method-style builtins. Each impl reads the receiver from the deepest RS
// slot — the slot below the args, populated by led_lparen pushing
// METHOD_RECEIVER (set by led_dot). For an N-arg method, RS is
// [..., me, arg1, ..., argN] and the impl uses preamble_args(N+1, 0) to
// consume both `me` and the args.
// =============================================================================

// --- str.upper() — return a new TYPE_STR with ASCII letters folded UP -------
//   in:  RS slot 0 = me (TYPE_STR)
// =============================================================================
builtin_str_upper:
    preamble_args(1, 0)
    rs_peek(W0)
    jsr deref_W0_to_W2                // W2 = me payload, A = O_LEN
    sta B0                            // B0 = len

    lda B0
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                         // RV = new STR

    // src = me.payload (re-deref post-GC).
    rs_peek(W0)
    jsr deref_W0_to_W2
    lda W2
    sta W3
    lda W2+1
    sta W3+1

    // dst = RV.payload.
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

    ldy B0
    beq _bsu_done
_bsu_loop:
    dey
    lda (W3),y
    cmp #$61                          // 'a'
    bcc _bsu_store
    cmp #$7B                          // 'z'+1
    bcs _bsu_store
    sec
    sbc #$20                          // → uppercase
_bsu_store:
    sta (W2),y
    cpy #0
    bne _bsu_loop
_bsu_done:
    jmp postamble

// --- list.append(item) — push item; returns NONE -----------------------------
//   in:  RS slot 1 = me (TYPE_LIST), slot 0 = item
// =============================================================================
builtin_list_append:
    preamble_args(2, 0)
    jsr list_append                   // mutates me in place; consumes 2 RS args
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

// --- dict.has(key) — TRUE if key in me; FALSE otherwise ----------------------
//   in:  RS slot 1 = me (TYPE_DICT), slot 0 = key
// =============================================================================
builtin_dict_has:
    preamble_args(2, 0)
    rs_peek_at(W0, 1)                 // me
    rs_peek_at(W1, 0)                 // key
    jsr _dict_bin_search              // A = 1 hit / 0 miss
    cmp #0
    beq _bdh_false
    lda #<TRUE
    sta RV
    lda #>TRUE
    sta RV+1
    jmp postamble
_bdh_false:
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
    jmp postamble

// =============================================================================
// _method_lookup — find a method handle by name in a per-type table.
//
// Tables are 0-terminated arrays of (name_handle, builtin_handle) pairs:
//   .word STR_NAME_FOO, BUILTIN_FOO
//   .word 0   ; sentinel
// Comparison goes through `val_eq` so name-string identity isn't required.
//
//   in:  W0 = table base, W1 = name handle (TYPE_STR)
//   out: A = 1 if found, 0 if not. RV = builtin handle when A=1.
//        Args remain on RS untouched.
// V4'.
// =============================================================================
_method_lookup:
    preamble_args(0, 0)
_mlu_loop:
    ldy #0
    lda (W0),y
    sta B0
    iny
    lda (W0),y
    sta B1                            // B0:B1 = candidate name handle
    lda B0
    ora B1
    bne _mlu_have_entry
    lda #0                            // not found
    jmp postamble

_mlu_have_entry:
    rs_push(W1)
    lda B0
    sta W2
    lda B1
    sta W2+1
    rs_push(W2)
    jsr val_eq                        // A = 1 if equal else 0
    cmp #0
    bne _mlu_match
    clc
    lda W0
    adc #4
    sta W0
    bcc _mlu_loop
    inc W0+1
    jmp _mlu_loop

_mlu_match:
    ldy #2
    lda (W0),y
    sta RV
    iny
    lda (W0),y
    sta RV+1
    lda #1
    jmp postamble

// --- Per-type method tables -------------------------------------------------
str_methods:
    .word STR_NAME_M_UPPER, BUILTIN_STR_UPPER
    .word 0

list_methods:
    .word STR_NAME_M_APPEND, BUILTIN_LIST_APPEND
    .word 0

dict_methods:
    .word STR_NAME_M_HAS, BUILTIN_DICT_HAS
    .word 0
