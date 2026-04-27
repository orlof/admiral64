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

    // Recursive: builtin_repr(element) — matches Python: containers always
    // render their elements via repr, so strings come out quoted.
    rs_push(W3)
    jsr builtin_repr

    // accum ++= element_str. RS is [container, accum] (builtin_repr consumed
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

    // accum ++= repr(key). builtin_repr(key):
    lda B0
    sta W3
    lda B1
    sta W3+1
    rs_push(W3)
    jsr builtin_repr                   // RV = key_str (quoted if str)
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

    // accum ++= repr(value).
    lda B2
    sta W3
    lda B3
    sta W3+1
    rs_push(W3)
    jsr builtin_repr                   // RV = value_str (quoted if str)
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
// builtin_sort(S) — return a sorted version of S.
//   in:  RS slot 0 = me (TYPE_STR, TYPE_TUPLE, or TYPE_LIST).
//   out: RV = sorted result. STR/TUPLE return a fresh sorted copy. LIST is
//        sorted in place (RV = same handle).
//
// Insertion sort. STR sorts bytes; TUPLE/LIST sort handles via val_cmp. The
// `reverse` arg from original Admiral is not supported here (would require
// optional positional args, which our parser doesn't model yet).
// =============================================================================
builtin_sort:
    preamble_args(1, 0)
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    bne !next+
    jmp _bsort_str
!next:
    cmp #TYPE_TUPLE
    bne !next+
    jmp _bsort_tuple
!next:
    cmp #TYPE_LIST
    bne !next+
    jmp _bsort_list
!next:
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_bsort_str:
    // Clone via `array_repeat` with n=1.
    rs_peek(W0)
    rs_push(W0)
    rs_push_const(INT_1)
    jsr array_repeat                  // RV = clone (TYPE_STR)
    rs_push(RV)                       // RS: [me, clone]

    rs_peek(W0)
    jsr deref_W0_to_W2                // W2 = clone payload, A = len
    sta B0
    lda W2
    sta W3
    lda W2+1
    sta W3+1                          // W3 = clone payload
    jsr _bsort_bytes
    rs_pop(RV)                        // RV = clone (sorted)
    jmp postamble

_bsort_tuple:
    rs_peek(W0)
    rs_push(W0)
    rs_push_const(INT_1)
    jsr array_repeat                  // RV = clone (TYPE_TUPLE preserved)
    rs_push(RV)
    rs_peek(W0)
    jsr deref_W0_to_W2                // W2 = clone payload, A = element count
    sta B0
    lda W2
    sta W3
    lda W2+1
    sta W3+1
    jsr _bsort_handles
    rs_pop(RV)
    jmp postamble

_bsort_list:
    // In-place. Set up W3 = payload, B0 = count, then sort.
    rs_peek(W0)
    jsr deref_W0_to_W2
    sta B0
    lda W2
    sta W3
    lda W2+1
    sta W3+1
    jsr _bsort_handles
    rs_peek(RV)                       // return same list handle
    jmp postamble

// Insertion sort over bytes at (W3),y for y in 0..B0-1.
// Clobbers: A, X, Y, B1..B4.
_bsort_bytes:
    lda #1
    sta B1                            // i
_bsb_o:
    lda B1
    cmp B0
    bcs _bsb_d
    sta B2                            // j = i
_bsb_in:
    lda B2
    beq _bsb_on
    ldy B2
    dey
    lda (W3),y
    sta B3                            // arr[j-1]
    iny
    lda (W3),y                        // arr[j]
    cmp B3
    bcs _bsb_on                       // arr[j] >= arr[j-1] → no swap
    sta B4                            // save arr[j]
    lda B3
    sta (W3),y                        // arr[j] = arr[j-1]
    dey
    lda B4
    sta (W3),y                        // arr[j-1] = old arr[j]
    dec B2
    jmp _bsb_in
_bsb_on:
    inc B1
    jmp _bsb_o
_bsb_d:
    rts

// Insertion sort over handles at (W3),y for slot 0..B0-1 (2 bytes/slot).
// Comparator: val_cmp. W3 must point at payload start. val_cmp preserves
// W0..W3, B0..B7 across the call (V4'), so we can re-read W0/W1 after.
_bsort_handles:
    lda #1
    sta B1
_bsh_o:
    lda B1
    cmp B0
    bcs _bsh_d
    sta B2
_bsh_in:
    lda B2
    beq _bsh_on

    // Read arr[j-1] → W0, arr[j] → W1.
    ldy B2
    dey
    tya
    asl
    tay                                // Y = 2*(j-1)
    lda (W3),y
    sta W0
    iny
    lda (W3),y
    sta W0+1
    iny
    lda (W3),y
    sta W1
    iny
    lda (W3),y
    sta W1+1

    rs_push(W0)
    rs_push(W1)
    jsr val_cmp                        // A = -1/0/+1
    cmp #1
    bne _bsh_on                        // not greater → done with this j

    // Swap. W0/W1 still hold old arr[j-1] and arr[j].
    ldy B2
    dey
    tya
    asl
    tay
    lda W1
    sta (W3),y
    iny
    lda W1+1
    sta (W3),y
    iny
    lda W0
    sta (W3),y
    iny
    lda W0+1
    sta (W3),y

    dec B2
    jmp _bsh_in
_bsh_on:
    inc B1
    jmp _bsh_o
_bsh_d:
    rts

// =============================================================================
// builtin_repr(x) — Python-style repr(): like str() but quotes top-level
// strings. Container elements are always rendered through repr (matches
// Python and Admiral's `dict_repr`/`list_repr` calling `repr` per element),
// so the container renderer below now delegates to builtin_repr too.
// =============================================================================
builtin_repr:
    preamble_args(1, 0)
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq _brepr_quote

    // Non-string: same rendering as str(). Re-push the arg so builtin_str
    // sees its own copy to consume.
    rs_push(W0)
    jsr builtin_str
    jmp postamble

_brepr_quote:
    // Build "'" ++ me ++ "'" via two array_merge calls.
    rs_push_const(STR_QUOTE)         // RS: [me, "'"]
    rs_peek_at(W0, 1)
    rs_push(W0)                      // RS: [me, "'", me]
    jsr array_merge                  // RV = "'me"; consumes top 2; RS: [me]
    rs_push(RV)                      // RS: [me, "'me"]
    rs_push_const(STR_QUOTE)         // RS: [me, "'me", "'"]
    jsr array_merge                  // RV = "'me'"; consumes top 2; RS: [me]
    jmp postamble

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
// builtin_id(x) — return the handle address of x as a non-negative INT.
// Allocated as a 3-byte int with high byte 0 so addresses with bit 15 set
// (e.g. handles around $C000+) stay positive.
// =============================================================================
builtin_id:
    preamble_args(1, 0)
    rs_peek(W0)

    lda #3
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int
    jsr deref_RV_to_W2
    ldy #0
    lda W0
    sta (W2),y
    iny
    lda W0+1
    sta (W2),y
    iny
    lda #0
    sta (W2),y
    jmp postamble

// =============================================================================
// builtin_cmp(a, b) — three-way compare via val_cmp.
//   Returns INT: -1 if a < b, 0 if a == b, 1 if a > b.
// =============================================================================
builtin_cmp:
    preamble_args(2, 0)
    jsr val_cmp                        // A = $FF / $00 / $01; consumes both args
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
// builtin_hex(x) — render INT/BOOL as a hex string. Format: "0xDDDD…" for
// non-negative values, "-0xDDDD…" for negatives. Two hex chars per
// magnitude byte (no leading-zero trim).
// =============================================================================
builtin_hex:
    preamble_args(1, 0)
    rs_peek(W0)

    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq !ok+
    cmp #TYPE_BOOL
    beq !ok+
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler
!ok:

    jsr deref_W0_to_W2                 // W2 = payload, A = O_LEN
    sta B0                              // B0 = mag len
    jsr sign_byte_W2                    // A = $FF if negative else $00
    sta B6                              // B6 = sign

    bpl _bhex_have_mag

    // Negative — negate to get magnitude, root it on RS for GC.
    rs_peek(W0)
    rs_push(W0)
    jsr int_negate
    rs_push(RV)                         // RS: [orig, magnitude]
    rs_peek(W0)
    jsr deref_W0_to_W2
    sta B0                              // B0 = magnitude len (post-negate normalization)
_bhex_have_mag:

    // ALLOC_SIZE = 2 ("0x") + (1 if negative else 0) + 2 * mag_len.
    lda B6
    bpl !p+
    lda #3
    jmp !d+
!p:
    lda #2
!d:
    sta B1                              // B1 = base length (0x or -0x)
    lda B0
    asl                                  // 2 * mag_len
    clc
    adc B1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                           // RV = new STR

    // Re-deref magnitude after alloc (GC may have moved data).
    rs_peek(W0)
    jsr deref_W0_to_W2                  // W2 = magnitude payload

    // dst = RV.payload base.
    ldy #H_PTR
    lda (RV),y
    sta W3
    iny
    lda (RV),y
    sta W3+1
    clc
    lda W3
    adc #O_HEADER
    sta W3
    bcc !+
    inc W3+1
!:

    ldy #0
    lda B6
    bpl !p+
    lda #$2D                            // '-' (ASCII / shared with screencode)
    sta (W3),y
    iny
!p:
    lda #$30                            // '0'
    sta (W3),y
    iny
    lda #$78                            // 'x' (ASCII; KickAss `'x'` literal would
                                        // be screencode and disagree with ASCII)
    sta (W3),y
    iny

    // Emit magnitude bytes from MSB to LSB.
    ldx B0
    dex
_bhex_byte_loop:
    bmi _bhex_done
    sty B5                              // save output offset
    txa
    tay
    lda (W2),y                          // mag[X]
    ldy B5                              // restore output offset
    pha                                  // save byte
    lsr
    lsr
    lsr
    lsr                                  // hi nibble
    jsr _bhex_emit_digit
    pla
    and #$0F                             // lo nibble
    jsr _bhex_emit_digit
    dex
    jmp _bhex_byte_loop
_bhex_done:
    jmp postamble

// Leaf: emit hex digit (A=0..15) at (W3),Y; bump Y. Clobbers A only.
_bhex_emit_digit:
    cmp #10
    bcc !num+
    adc #($61 - 10 - 1)                  // carry was set; +($61-10-1)+1 = +($61-10) → 'a'..'f'
    sta (W3),y
    iny
    rts
!num:
    adc #$30                             // '0'..'9' (carry was clear)
    sta (W3),y
    iny
    rts

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

// --- str.lower() — fold ASCII letters DOWN ----------------------------------
//   in:  RS slot 0 = me (TYPE_STR)
// =============================================================================
builtin_str_lower:
    preamble_args(1, 0)
    rs_peek(W0)
    jsr deref_W0_to_W2
    sta B0

    lda B0
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc

    rs_peek(W0)
    jsr deref_W0_to_W2
    lda W2
    sta W3
    lda W2+1
    sta W3+1

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
    beq _bsl_done
_bsl_loop:
    dey
    lda (W3),y
    cmp #$41                          // 'A'
    bcc _bsl_store
    cmp #$5B                          // 'Z'+1
    bcs _bsl_store
    clc
    adc #$20                          // → lowercase
_bsl_store:
    sta (W2),y
    cpy #0
    bne _bsl_loop
_bsl_done:
    jmp postamble

// --- str.find(sub) — return first position or -1 ----------------------------
//   in:  RS slot 1 = me (TYPE_STR), slot 0 = sub (TYPE_STR)
//
// str_find_pos expects RS = [needle (deeper), haystack (top)]; method-call
// layout gives [me, sub] so we swap before delegating.
// =============================================================================
builtin_str_find:
    preamble_args(2, 0)
    rs_pop(W1)                        // sub (top)
    rs_pop(W0)                        // me (was deeper)
    rs_push(W1)                       // sub becomes new deeper
    rs_push(W0)                       // me becomes new top
    jsr str_find_pos                  // A = pos or $FF
    sta B0

    // Allocate 2-byte signed INT (so positions ≥ 128 stay positive).
    lda #2
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int
    jsr deref_RV_to_W2

    ldy #0
    lda B0
    sta (W2),y                        // lo byte
    iny
    lda B0
    asl                                // bit 7 → carry
    lda #0
    bcc _bfind_store_hi
    lda #$FF
_bfind_store_hi:
    sta (W2),y
    jmp postamble

// --- str.startswith(prefix) -------------------------------------------------
//   in:  RS slot 1 = me, slot 0 = prefix
// =============================================================================
builtin_str_startswith:
    preamble_args(2, 0)
    rs_peek_at(W0, 0)                 // prefix
    jsr deref_W0_to_W2
    sta B0                            // B0 = prefix len
    lda W2
    sta W3
    lda W2+1
    sta W3+1                          // W3 = prefix payload

    rs_peek_at(W0, 1)                 // me
    jsr deref_W0_to_W2
    sta B1                            // B1 = me len; W2 = me payload

    // If prefix len > me len, not a prefix.
    lda B0
    cmp B1
    beq _bsw_check
    bcc _bsw_check
    jmp _bsw_false
_bsw_check:
    ldy B0
    beq _bsw_true                     // empty prefix → always matches
_bsw_loop:
    dey
    lda (W2),y
    cmp (W3),y
    bne _bsw_false
    cpy #0
    bne _bsw_loop
_bsw_true:
    lda #<TRUE
    sta RV
    lda #>TRUE
    sta RV+1
    jmp postamble
_bsw_false:
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
    jmp postamble

// --- str.endswith(suffix) ---------------------------------------------------
//   in:  RS slot 1 = me, slot 0 = suffix
// =============================================================================
builtin_str_endswith:
    preamble_args(2, 0)
    rs_peek_at(W0, 0)                 // suffix
    jsr deref_W0_to_W2
    sta B0                            // B0 = suffix len
    lda W2
    sta W3
    lda W2+1
    sta W3+1

    rs_peek_at(W0, 1)                 // me
    jsr deref_W0_to_W2
    sta B1                            // B1 = me len

    lda B0
    cmp B1
    beq _bew_check
    bcc _bew_check
    jmp _bew_false
_bew_check:
    // Advance W2 by (me_len - suffix_len) so it points at the tail region.
    sec
    lda B1
    sbc B0
    clc
    adc W2
    sta W2
    bcc !+
    inc W2+1
!:
    ldy B0
    beq _bew_true
_bew_loop:
    dey
    lda (W2),y
    cmp (W3),y
    bne _bew_false
    cpy #0
    bne _bew_loop
_bew_true:
    lda #<TRUE
    sta RV
    lda #>TRUE
    sta RV+1
    jmp postamble
_bew_false:
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
    jmp postamble

// --- str.split(sep) — list of substrings split on sep ----------------------
//   in:  RS slot 1 = me, slot 0 = sep
//   out: RV = TYPE_LIST of TYPE_STR. Args consumed.
//
// Sep-required form (no whitespace mode for now). Empty sep → ERR_TYPE.
// Empty me with any sep → list with one empty string. Consecutive seps
// produce empty strings (Python `"a,,b".split(",")` → ["a","","b"]).
// =============================================================================
builtin_str_split:
    preamble_args(2, 0)

    rs_peek_at(W0, 1)
    rs_peek_at(W1, 0)
    jsr deref_W0_to_W2                // W2=me payload, A=me_len
    sta B0
    jsr deref_W1_to_W3                // W3=sep payload, A=sep_len
    sta B1

    lda B1
    bne !ok+
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler
!ok:

    // Allocate empty list (capacity 0). _array_alloc_init clobbers B0,
    // so re-load me_len/sep_len after.
    lda #0
    ldx #TYPE_LIST
    jsr _array_alloc_init             // RV = list
    rs_push(RV)                       // RS: [me, sep, list]

    rs_peek_at(W0, 2)
    rs_peek_at(W1, 1)
    jsr deref_W0_to_W2                // A = me_len
    sta B0
    jsr deref_W1_to_W3                // A = sep_len
    sta B1

    lda #0
    sta B3                            // pos
    sta B4                            // segment start

_bsp_loop:
    lda B3
    cmp B0
    bcc !go+
    jmp _bsp_done
!go:

    lda B3
    clc
    adc B1
    bcc !ovr_ok+
    jmp _bsp_adv
!ovr_ok:
    cmp B0
    beq _bsp_chk
    bcc _bsp_chk
    jmp _bsp_adv

_bsp_chk:
    jsr _bsr_match_at_pos
    cmp #0
    bne !go+
    jmp _bsp_adv
!go:

    // Match — emit me[B4..B3] then bump past sep.
    jsr _bsp_emit_segment
    lda B3
    clc
    adc B1
    sta B4
    sta B3
    rs_peek_at(W0, 2)
    rs_peek_at(W1, 1)
    jsr deref_W0_to_W2
    jsr deref_W1_to_W3
    jmp _bsp_loop

_bsp_adv:
    inc B3
    jmp _bsp_loop

_bsp_done:
    // Emit final segment me[B4..me_len].
    lda B0
    sta B3
    jsr _bsp_emit_segment

    rs_peek(RV)
    jmp postamble

// Helper: alloc TYPE_STR of B3-B4 bytes, copy me[B4..B3] into it, append to
// list. Caller's RS at entry: [me, sep, list]. Helper must NOT change that.
//
// Preserves: B0, B1, B2, B4. Clobbers: A, X, Y, B5..B7, W0..W3, RV.
// Re-derefs me/sep for the caller via the helper's tail (same as caller's
// re-deref pattern), so the helper's caller doesn't need to re-deref before
// emitting; but it DOES need to re-deref for the next loop iteration.
_bsp_emit_segment:
    sec
    lda B3
    sbc B4
    sta B5                            // B5 = segment len
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                         // RV = new str
    rs_push(RV)                       // RS: [me, sep, list, seg]

    // Copy me[B4..B4+B5] into seg. seg payload first (W3), me payload after (W2).
    rs_peek(W0)                       // seg (slot 0)
    jsr deref_W0_to_W2                // W2 = seg payload
    lda W2
    sta W3
    lda W2+1
    sta W3+1                          // W3 = seg payload (saved)

    rs_peek_at(W0, 3)                 // me
    jsr deref_W0_to_W2                // W2 = me payload
    lda W2
    clc
    adc B4
    sta W2
    bcc !+
    inc W2+1
!:
    ldy #0
_bsp_cp:
    cpy B5
    beq _bsp_cpd
    lda (W2),y
    sta (W3),y
    iny
    jmp _bsp_cp
_bsp_cpd:

    // Append seg to list: stage [list, seg] on top of RS.
    rs_peek_at(W0, 1)                 // list (slot 1)
    rs_push(W0)
    rs_peek_at(W0, 1)                 // seg (now at slot 1 due to push)
    rs_push(W0)
    jsr list_append                   // consumes top 2; list grew

    rs_pop(W0)                        // drop the seg root; RS: [me, sep, list]
    rts

// --- str.replace(old, new) — replace all occurrences. ----------------------
//   in:  RS slot 2 = me, slot 1 = old, slot 0 = new (all TYPE_STR)
//   out: RV = new TYPE_STR with substitutions applied. Args consumed.
//
// Two-pass algorithm: pass 1 counts matches, pass 2 copies. Empty `old`
// panics ERR_TYPE (Python's behaviour is to insert `new` between every char,
// not worth the complexity). Total result must fit in 255 bytes else ERR_OOM.
// =============================================================================
builtin_str_replace:
    preamble_args(3, 0)

    // Lengths into B0..B2.
    rs_peek_at(W0, 2)
    rs_peek_at(W1, 1)
    jsr deref_W0_to_W2                // A = me_len, W2 = me payload
    sta B0
    jsr deref_W1_to_W3                // A = old_len, W3 = old payload
    sta B1

    lda B1
    bne !ok+
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler
!ok:
    rs_peek(W0)                       // new
    jsr deref_W0_to_W2                // A = new_len (W2 trampled)
    sta B2

    // Re-establish W2=me, W3=old after the new-deref.
    rs_peek_at(W0, 2)
    rs_peek_at(W1, 1)
    jsr deref_W0_to_W2
    jsr deref_W1_to_W3

    // ----- Pass 1: count matches into B5 -----
    lda #0
    sta B3
    sta B5
_bsr_p1:
    lda B3
    clc
    adc B1
    bcs _bsr_p1d
    cmp B0
    beq _bsr_p1c
    bcs _bsr_p1d
_bsr_p1c:
    jsr _bsr_match_at_pos
    cmp #0
    beq _bsr_p1m
    inc B5
    lda B3
    clc
    adc B1
    sta B3
    jmp _bsr_p1
_bsr_p1m:
    inc B3
    jmp _bsr_p1
_bsr_p1d:

    // Compute output_len = me_len + B5*(B2 - B1) into W0:W0+1 (16-bit).
    lda B0
    sta W0
    lda #0
    sta W0+1
    ldx B5
    beq _bsr_olok
_bsr_olax:
    lda W0
    clc
    adc B2
    sta W0
    bcc !+
    inc W0+1
!:
    lda W0
    sec
    sbc B1
    sta W0
    bcs !+
    dec W0+1
!:
    dex
    bne _bsr_olax
_bsr_olok:
    lda W0+1
    beq _bsr_alloc
    lda #ERR_OOM
    sta ERROR_CODE
    jmp error_handler
_bsr_alloc:
    lda W0
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                         // RV = new str
    rs_push(RV)                       // RS: [me, old, new, out]

    // Re-deref me, old (heap may have moved during alloc).
    rs_peek_at(W0, 3)
    rs_peek_at(W1, 2)
    jsr deref_W0_to_W2
    jsr deref_W1_to_W3

    // ----- Pass 2: build output -----
    lda #0
    sta B3                            // src pos
    sta B4                            // dst pos
_bsr_p2:
    lda B3
    cmp B0
    bcc !skip+
    jmp _bsr_p2d
!skip:

    lda B3
    clc
    adc B1
    bcc !nooverflow+
    jmp _bsr_p2byte
!nooverflow:
    cmp B0
    beq _bsr_p2chk
    bcc _bsr_p2chk
    jmp _bsr_p2byte
_bsr_p2chk:
    jsr _bsr_match_at_pos
    cmp #0
    bne !skip+
    jmp _bsr_p2byte
!skip:

    // Match — copy new bytes to out[B4..B4+B2].
    rs_peek_at(W0, 1)                 // new (slot 1)
    jsr deref_W0_to_W2                // W2 = new payload
    rs_peek(W1)                       // out (slot 0)
    jsr deref_W1_to_W3                // W3 = out payload
    lda W3
    clc
    adc B4
    sta W3
    bcc !+
    inc W3+1
!:
    ldy #0
_bsr_pcn:
    cpy B2
    beq _bsr_pcnd
    lda (W2),y
    sta (W3),y
    iny
    jmp _bsr_pcn
_bsr_pcnd:
    lda B4
    clc
    adc B2
    sta B4
    lda B3
    clc
    adc B1
    sta B3
    jmp _bsr_p2_redo

_bsr_p2byte:
    // No match: copy me[B3] to out[B4].
    ldy B3
    lda (W2),y
    sta B7
    rs_peek(W0)
    jsr deref_W0_to_W2                // W2 = out payload
    ldy B4
    lda B7
    sta (W2),y
    inc B3
    inc B4

_bsr_p2_redo:
    rs_peek_at(W0, 3)
    rs_peek_at(W1, 2)
    jsr deref_W0_to_W2
    jsr deref_W1_to_W3
    jmp _bsr_p2

_bsr_p2d:
    rs_peek(RV)
    jmp postamble

// Leaf helper: compare (W2 + B3)[0..B1-1] vs W3[0..B1-1].
// Returns A=1 if equal else 0. Clobbers A, X, Y, B7.
_bsr_match_at_pos:
    ldx #0
_bsr_mat:
    cpx B1
    beq _bsr_matok
    txa
    clc
    adc B3
    tay
    lda (W2),y
    sta B7
    txa
    tay
    lda (W3),y
    cmp B7
    bne _bsr_matno
    inx
    jmp _bsr_mat
_bsr_matok:
    lda #1
    rts
_bsr_matno:
    lda #0
    rts

// --- str.isalpha() — TRUE iff every byte is A-Z or a-z (and len > 0) -------
//   in:  RS slot 0 = me
// =============================================================================
builtin_str_isalpha:
    preamble_args(1, 0)
    rs_peek(W0)
    jsr deref_W0_to_W2                // A = O_LEN, W2 = payload
    sta B0
    beq _bia_false                    // empty → False (Python rule)
    ldy #0
_bia_loop:
    lda (W2),y
    cmp #$41                          // 'A'
    bcc _bia_false
    cmp #$5B                          // 'Z'+1
    bcc _bia_next
    cmp #$61                          // 'a'
    bcc _bia_false
    cmp #$7B                          // 'z'+1
    bcs _bia_false
_bia_next:
    iny
    cpy B0
    bcc _bia_loop
    lda #<TRUE
    sta RV
    lda #>TRUE
    sta RV+1
    jmp postamble
_bia_false:
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
    jmp postamble

// --- str.isdigit() — TRUE iff every byte is 0-9 (and len > 0) --------------
//   in:  RS slot 0 = me
// =============================================================================
builtin_str_isdigit:
    preamble_args(1, 0)
    rs_peek(W0)
    jsr deref_W0_to_W2
    sta B0
    beq _bid_false
    ldy #0
_bid_loop:
    lda (W2),y
    cmp #$30                          // '0'
    bcc _bid_false
    cmp #$3A                          // '9'+1
    bcs _bid_false
    iny
    cpy B0
    bcc _bid_loop
    lda #<TRUE
    sta RV
    lda #>TRUE
    sta RV+1
    jmp postamble
_bid_false:
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
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

// --- list.insert(idx, item) — splice in at idx; returns NONE -----------------
//   in:  RS slot 2 = me, slot 1 = idx (INT), slot 0 = item
// =============================================================================
builtin_list_insert:
    preamble_args(3, 0)
    rs_pop(W1)                        // item
    rs_pop(W0)                        // idx handle

    // Extract idx byte from int handle → fs_push as a word.
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_HEADER
    lda (W2),y                        // A = idx byte
    sta W3
    lda #0
    sta W3+1
    fs_push(W3)

    rs_push(W1)                       // RS: [me, item]
    jsr array_insert                  // consumes 2 RS + 1 FS; mutates me

    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

// --- list.pop() — remove and return last element ----------------------------
//   in:  RS slot 0 = me. Empty list → ERR_TYPE.
// =============================================================================
builtin_list_pop:
    preamble_args(1, 0)
    rs_peek(W0)

    // W2 = object base (at O_LEN), B0 = O_LEN low.
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    sta B0
    bne _bpop_have
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler
_bpop_have:
    dec B0                            // B0 = new O_LEN (= idx of element to remove)

    // W3 = payload base (W2 + O_HEADER).
    clc
    lda W2
    adc #O_HEADER
    sta W3
    lda W2+1
    adc #0
    sta W3+1

    // RV = payload[B0].
    lda B0
    asl
    tay
    lda (W3),y
    sta RV
    iny
    lda (W3),y
    sta RV+1

    // Write new O_LEN at W2.
    ldy #O_LEN
    lda B0
    sta (W2),y
    iny
    lda #0
    sta (W2),y
    jmp postamble

// --- dict.get(key, default) — value at key, else default --------------------
//   in:  RS slot 2 = me (TYPE_DICT), slot 1 = key, slot 0 = default
// =============================================================================
builtin_dict_get:
    preamble_args(3, 0)
    rs_peek_at(W0, 2)
    rs_peek_at(W1, 1)
    jsr _dict_bin_search              // A = 1 hit / 0 miss; RV = index on hit
    cmp #0
    beq _bdg_miss

    // Hit: dict.payload[RV] is the (key, value) entry tuple.
    rs_peek_at(W0, 2)
    jsr deref_W0_to_W2                // W2 = me payload
    lda RV
    asl
    tay
    lda (W2),y
    sta W3
    iny
    lda (W2),y
    sta W3+1                          // W3 = entry tuple

    // Read entry.payload[1] = value (byte offset 2 past entry's O_LEN word).
    lda W3
    sta W0
    lda W3+1
    sta W0+1
    jsr deref_W0_to_W2
    ldy #2                            // tuple slot 1 starts at offset 2
    lda (W2),y
    sta RV
    iny
    lda (W2),y
    sta RV+1
    jmp postamble

_bdg_miss:
    // Default is at RS slot 0 (top).
    rs_peek(RV)
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

// --- dict.keys() — list of keys --------------------------------------------
//   in:  RS slot 0 = me (TYPE_DICT)
// =============================================================================
builtin_dict_keys:
    preamble_args(1, 0)
    lda #0                            // entry-tuple byte offset for the key
    jsr _bd_build_list
    jmp postamble

// --- dict.values() — list of values ----------------------------------------
//   in:  RS slot 0 = me (TYPE_DICT)
// =============================================================================
builtin_dict_values:
    preamble_args(1, 0)
    lda #2                            // entry-tuple byte offset for the value
    jsr _bd_build_list
    jmp postamble

// -----------------------------------------------------------------------------
// _bd_build_list — common body for dict.keys / dict.values. Builds a list of
// either the key (offset 0) or value (offset 2) field of each (key, value)
// 2-tuple in the dict's payload.
//
// in:  A = byte offset within entry tuple (0 = key, 2 = value)
//      RS slot 0 = dict handle (caller's RS root, untouched on return)
// out: RV = new TYPE_LIST
//
// Leaf — uses caller's V4' frame for B/W scratch. Callers must be V4'.
// -----------------------------------------------------------------------------
_bd_build_list:
    sta B7                            // B7 = entry slot byte offset

    rs_peek(W0)                       // dict
    jsr deref_W0_to_W2                // A = O_LEN, W2 = dict payload
    sta B0                            // B0 = entry count

    lda B0
    jsr list_alloc                    // RV = new TYPE_LIST, O_LEN = B0
    rs_push(RV)                       // root: RS [..., dict, list]

    lda #0
    sta B1                            // B1 = current entry index
_bdb_loop:
    lda B1
    cmp B0
    bcs _bdb_done

    // me.payload[B1] → entry tuple handle in W3.
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

    // Deref entry; read field at offset B7 (key or value handle).
    lda W3
    sta W0
    lda W3+1
    sta W0+1
    jsr deref_W0_to_W2
    ldy B7
    lda (W2),y
    sta B2
    iny
    lda (W2),y
    sta B3

    // Write the field handle into list[B1].
    rs_peek(W0)                       // list
    lda B2
    sta W1
    lda B3
    sta W1+1
    lda B1
    jsr array_set_leaf

    inc B1
    jmp _bdb_loop
_bdb_done:
    rs_pop(RV)
    rts

// --- dict.create() — empty dict with me as prototype -----------------------
//   in:  RS slot 0 = me (TYPE_DICT)
//   out: RV = new dict, with new["_"] = me
//
// Mirrors Admiral's `built_in__dict_create` (builtin.dasm16:64). The new dict
// holds a single (`_`, me) entry so scope_get's prototype walk picks up the
// chain.
// =============================================================================
builtin_dict_create:
    preamble_args(1, 0)

    jsr dict_alloc                    // RV = new dict
    rs_push(RV)                       // RS: [me, new] — root new

    // Stage dict_set(new, "_", me): caller pushes (dict, key, value) on top.
    rs_push(RV)                       // RS: [me, new, new]
    rs_push_const(STR_UNDERSCORE)     // RS: [me, new, new, "_"]
    rs_peek_at(W0, 3)                 // me at slot 3
    rs_push(W0)                       // RS: [me, new, new, "_", me]
    jsr dict_set                      // consumes top 3; RS: [me, new]

    rs_peek(RV)                       // RV = new (slot 0)
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
    .word STR_NAME_M_LOWER, BUILTIN_STR_LOWER
    .word STR_NAME_M_FIND, BUILTIN_STR_FIND
    .word STR_NAME_M_STARTSWITH, BUILTIN_STR_STARTSWITH
    .word STR_NAME_M_ENDSWITH, BUILTIN_STR_ENDSWITH
    .word STR_NAME_M_ISALPHA, BUILTIN_STR_ISALPHA
    .word STR_NAME_M_ISDIGIT, BUILTIN_STR_ISDIGIT
    .word STR_NAME_M_REPLACE, BUILTIN_STR_REPLACE
    .word STR_NAME_M_SPLIT, BUILTIN_STR_SPLIT
    .word 0

list_methods:
    .word STR_NAME_M_APPEND, BUILTIN_LIST_APPEND
    .word STR_NAME_M_INSERT, BUILTIN_LIST_INSERT
    .word STR_NAME_M_POP, BUILTIN_LIST_POP
    .word 0

dict_methods:
    .word STR_NAME_M_HAS, BUILTIN_DICT_HAS
    .word STR_NAME_M_GET, BUILTIN_DICT_GET
    .word STR_NAME_M_KEYS, BUILTIN_DICT_KEYS
    .word STR_NAME_M_VALUES, BUILTIN_DICT_VALUES
    .word STR_NAME_M_CREATE, BUILTIN_DICT_CREATE
    .word 0
