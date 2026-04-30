// -----------------------------------------------------------------------------
// Built-in functions.
//
// Calling convention (v2 — args tuple):
//   - Each builtin receives one RS arg = a TYPE_TUPLE of positional args.
//     Function call f(a, b)   → tuple = (a, b)
//     Method call obj.m(a, b) → tuple = (obj, a, b)   (receiver is slot 0)
//   - Each builtin uses `preamble_call(MIN, MAX)` from preamble.asm:
//       in:  RS top = args tuple
//       out: W3 = tuple payload pointer (callee-saved by the V4' frame),
//            B7 = arg count.
//       Panics ERR_ARITY if count not in [MIN, MAX].
//   - Args are read via `arg_get(i, dst)` (mandatory) or
//     `arg_get_or(i, fallback_const, dst)` (optional with default).
//
// Each built-in is:
//   1. A V4'-wrapped implementation (e.g., `builtin_len`).
//   2. A static TYPE_BUILTIN handle whose 2-byte payload IS the impl
//      address (read by `led_lparen` and JSR'd via SMC).
//   3. A static TYPE_STR holding the name; `parser_eval` binds the
//      builtin into `global_scope` at start so `range` / `len` resolve
//      via normal scope lookup.
//
// To add a new built-in:
//   a) Write the impl: V4', `preamble_call(MIN, MAX)`, body, `postamble`.
//   b) Add `BUILTIN_<NAME>:` static + `STR_NAME_<NAME>:` static.
//   c) Add a binding line in parser_eval's init.
//
// GC re-deref rule: any sub-call that may allocate (alloc, alloc_int, jsr to
// another builtin, etc.) can move tuple payload via gc_compact. After such a
// call, W3 is stale. To re-read further args, either: (a) cache the arg
// handles into ZP regs at the start (W0..W3 are saved/restored by all V4'
// sub-calls), or (b) re-deref the args tuple via the RS root and refresh W3.
// Many migrated builtins simply push needed arg handles onto RS as separate
// roots at entry, mirroring the old "args on RS" layout for the rest of the
// body.
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
//   in:   args tuple = (x,)
//   out:  RV = TYPE_INT handle holding len.
// =============================================================================
builtin_len:
    jsr preamble_call_1_1_w0
    jsr deref_W0_to_W2           // A = O_LEN low byte
    sta B0
    jmp postamble_set_rv_int_b0

// =============================================================================
// builtin_range(n) — list of integers 0..n-1.
//   in:   1 RS arg = n (TYPE_INT, low byte used; cap 255).
//   out:  RV = TYPE_LIST.
// =============================================================================
builtin_range:
    jsr preamble_call_1_1_w0
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
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2
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
    jsr preamble_call_1_1_w0
    jsr val_truthy               // A = 0 (falsy) or non-zero (truthy)
    cmp #0
    beq _bbool_false
    jmp postamble_return_true
_bbool_false:
    jmp postamble_return_false

// =============================================================================
// builtin_abs(x) — magnitude. INT/BOOL → INT (negate if negative).
// FLOAT → FLOAT (clear sign bit). Other types panic ERR_TYPE.
// =============================================================================
builtin_abs:
    jsr preamble_call_1_1_w0
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
    arg_get(0, W0)
    jsr deref_W0_to_W2
    jsr sign_byte_W2             // A = $00 if non-neg, $FF if neg
    cmp #$00
    beq _babs_passthrough
    arg_get(0, W0)
    rs_push(W0)
    jsr int_negate               // consumes pushed arg, RV = magnitude
    jmp postamble

_babs_passthrough:
    arg_get(0, RV)
    jmp postamble

_babs_float:
    // Packed MS-Basic float: byte 1 of payload holds (sign|mantissa-msb).
    // Bit 7 = sign. If clear, already non-negative.
    arg_get(0, W0)
    jsr deref_W0_to_W2
    ldy #1
    lda (W2),y
    bpl _babs_passthrough
    arg_get(0, W0)
    rs_push(W0)
    jsr float_neg                // RV = -x (positive)
    jmp postamble

// =============================================================================
// builtin_chr(n) — INT/BOOL n → 1-byte TYPE_STR with payload = n & $FF.
// =============================================================================
builtin_chr:
    jsr preamble_call_1_1_w0
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
    jsr preamble_call_1_1_w0
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
    jmp postamble_set_rv_int_b0

_bord_2byte:
    // 128..255: 2-byte int with high byte 0 keeps it positive.
    lda #2
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2
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
    jsr preamble_call_1_1_w0
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
    arg_get(0, RV)
    jmp postamble

_bint_from_bool:
    arg_get(0, W0)
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    sta B0
    jmp postamble_set_rv_int_b0

_bint_from_float:
    arg_get(0, W0)
    rs_push(W0)
    jsr float_to_int                 // consumes pushed arg, RV = INT
    jmp postamble

_bint_from_str:
    arg_get(0, W0)
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
    jsr preamble_call_1_1_w0
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
    arg_get(0, RV)
    jmp postamble

_bflt_from_int:
    arg_get(0, W0)
    rs_push(W0)
    jsr int_to_float
    jmp postamble

_bflt_from_str:
    arg_get(0, W0)
    rs_push(W0)
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
    jsr preamble_call_1_1_w0
    ldy #H_TYPE
    lda (W0),y

    cmp #TYPE_STR
    bne !next+
    jmp _bstr_passthrough
!next:
    cmp #TYPE_INT
    bne !next+
    jmp _bstr_int
!next:
    cmp #TYPE_BOOL
    bne !next+
    jmp _bstr_bool
!next:
    cmp #TYPE_NONE
    bne !next+
    jmp _bstr_none
!next:
    cmp #TYPE_FLOAT
    bne !next+
    jmp _bstr_float
!next:
    cmp #TYPE_LIST
    bne !next+
    jmp _bstr_list
!next:
    cmp #TYPE_TUPLE
    bne !next+
    jmp _bstr_tuple
!next:
    cmp #TYPE_DICT
    bne !next+
    jmp _bstr_dict
!next:
    jmp _bstr_type_err
_bstr_type_err:
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_bstr_passthrough:
    arg_get(0, RV)
    jmp postamble
_bstr_int:
    arg_get(0, W0)
    rs_push(W0)
    jsr int_to_str                   // consumes pushed arg, RV = STR
    jmp postamble
_bstr_float:
    arg_get(0, W0)
    rs_push(W0)
    jsr float_to_str
    jmp postamble
_bstr_bool:
    arg_get(0, W0)
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    bne _bstr_bool_true
    lda #<STR_FALSE
    ldx #>STR_FALSE
    jmp postamble_set_rv_ax
_bstr_bool_true:
    lda #<STR_TRUE
    ldx #>STR_TRUE
    jmp postamble_set_rv_ax
_bstr_none:
    lda #<STR_NONE
    ldx #>STR_NONE
    jmp postamble_set_rv_ax

// Containers: push container as a fresh root above the args tuple, then push
// open/close, then call the renderer. Rendering helpers read container at RS
// depth 1 (after their own internal pushes), as before.
_bstr_list:
    arg_get(0, W0)
    rs_push(W0)
    rs_push_const(STR_LBRACK)
    rs_push_const(STR_RBRACK)
    jsr _bstr_render_seq
    jmp postamble

_bstr_tuple:
    arg_get(0, W0)
    rs_push(W0)
    rs_push_const(STR_LPAREN)
    rs_push_const(STR_RPAREN)
    jsr _bstr_render_seq
    jmp postamble

_bstr_dict:
    arg_get(0, W0)
    rs_push(W0)
    jsr _bstr_render_dict
    jmp postamble

// -----------------------------------------------------------------------------
// _repr_w0 / _str_w0 — internal "call repr/str on a single handle" helpers.
//
// Under the v2 args-tuple convention every builtin receives one RS arg = a
// TYPE_TUPLE. When builtin code wants to recursively invoke builtin_repr or
// builtin_str on a child value (e.g., the rendering helpers below, or
// builtin_repr's non-string passthrough), it can't just `rs_push(value); jsr
// builtin_repr` — it must wrap the value in a 1-tuple first.
//
// These helpers do exactly that: they take the value handle in W0, allocate a
// 1-tuple, store the value in slot 0, push the tuple on RS, and jsr the
// target builtin. RV holds the result on return; RS is restored to its
// pre-call state (the tuple is consumed by the target builtin's postamble).
//
//   in:  W0 = value handle
//   out: RV = result string. RS unchanged net.
//   clobbers: A, X, Y, W0..W2. B0..B7 preserved (nested calls are V4').
//   GC-safe: the input is rooted on RS across tuple_alloc.
// -----------------------------------------------------------------------------
_repr_w0:
    rs_push(W0)
    lda #1
    jsr tuple_alloc                    // RV = empty 1-tuple. Preserves W/B.
    rs_pop(W1)                          // W1 = original value (was W0)
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    lda #0
    jsr tuple_set_leaf                  // tuple[0] = W1
    rs_push(RV)                         // root tuple as the args arg
    jsr builtin_repr                    // consumes tuple, RV = repr
    rts

_str_w0:
    rs_push(W0)
    lda #1
    jsr tuple_alloc
    rs_pop(W1)
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    lda #0
    jsr tuple_set_leaf
    rs_push(RV)
    jsr builtin_str
    rts

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
    lda W3
    sta W0
    lda W3+1
    sta W0+1
    jsr _repr_w0

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
// Caller: builtin_str's body, with dict pushed as RS top. On return RV =
// rendered string. RS is inconsistent; postamble cleans up.
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
    sta W0
    lda B1
    sta W0+1
    jsr _repr_w0                       // RV = key_str (quoted if str)
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
    sta W0
    lda B3
    sta W0+1
    jsr _repr_w0                       // RV = value_str (quoted if str)
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
// builtin_rnd([start[, end]]) — random number, mirroring Admiral semantics.
//
//   rnd()              → FLOAT in [0, 1)
//   rnd(end)           → INT in [0, end)              if end is INT
//                      → FLOAT in [0, end)            if end is FLOAT
//   rnd(start, end)    → INT or FLOAT in [start, end). Mixed INT+FLOAT auto-
//                        casts to FLOAT (via cast_common_number_type), like
//                        Admiral's `built_in_rnd_2`.
//
// BOOL is rejected with ERR_TYPE in any bounded form (matches Admiral's
// `ifc c, TYPE_INT + TYPE_FLOAT` check). STR / containers also panic.
//
// Distribution: INT path allocates a random integer of `(diff_size + 1)`
// bytes and computes `rand % diff`, mirroring Admiral's `int_random`. The
// `+1` byte is held at zero so the random is always non-negative; full
// `8 * diff_size` entropy bits cover the diff's range with at most ~1/256
// modulo bias for any payload size. FLOAT path uses 31-bit mantissa
// entropy via the new `float_random` (4× rand8 + FSUB by 1.0).
// =============================================================================
builtin_rnd:
    preamble_call(0, 2)
    lda B7
    bne _brnd_bounded

    // 0 args: tail into float_random.
    jsr float_random
    jmp postamble

_brnd_panic_type:
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_brnd_bounded:
    // Validate arg[0] type. INT or FLOAT only — BOOL / STR / etc. panic.
    arg_get(0, W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq _brnd_arg0_ok
    cmp #TYPE_FLOAT
    beq _brnd_arg0_ok
    jmp _brnd_panic_type
_brnd_arg0_ok:

    lda B7
    cmp #2
    beq _brnd_two_arg

    // 1-arg path. Re-read arg[0] type to dispatch.
    arg_get(0, W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_FLOAT
    beq _brnd_one_float

    // rnd(end) INT: random_of_size(end_payload_len + 1) % end.
    arg_get(0, W0)
    jsr deref_W0_to_W2
    sta B0                            // B0 = end's payload byte length
    clc
    lda B0
    adc #1
    jsr _brnd_alloc_rand              // RV = rand INT, (B0+1) bytes
    rs_push(RV)                       // RS: [args, rand]
    arg_get(0, W0)
    rs_push(W0)                       // RS: [args, rand, end]
    jsr int_mod                       // RV = rand % end
    jmp postamble

_brnd_one_float:
    // rnd(end) FLOAT: result = float_random() * end.
    jsr float_random
    rs_push(RV)                       // RS: [args, frnd]
    arg_get(0, W0)
    rs_push(W0)                       // RS: [args, frnd, end]
    jsr float_mul
    jmp postamble

_brnd_two_arg:
    // Validate arg[1] type.
    arg_get(1, W1)
    ldy #H_TYPE
    lda (W1),y
    cmp #TYPE_INT
    beq _brnd_arg1_ok
    cmp #TYPE_FLOAT
    beq _brnd_arg1_ok
    jmp _brnd_panic_type
_brnd_arg1_ok:

    // Push start, end onto RS and let cast_common_number_type promote.
    arg_get(0, W0)
    arg_get(1, W1)
    rs_push(W0)                       // RS: [args, start]
    rs_push(W1)                       // RS: [args, start, end]
    jsr cast_common_number_type       // both promoted to common numeric

    // Dispatch on the (now-common) type, peeking at the top.
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_FLOAT
    beq _brnd_two_float

    // -------- 2-arg INT path --------
    // RS: [args, start, end]. diff = end - start (int_sub: minuend deeper).
    rs_peek_at(W0, 1)                 // start
    rs_peek_at(W1, 0)                 // end
    rs_push(W1)                       // RS: [args, start, end, end]
    rs_push(W0)                       // RS: [args, start, end, end, start]
    jsr int_sub                       // RV = end - start
    rs_push(RV)                       // RS: [args, start, end, diff]

    // Allocate rand of (diff_size + 1) bytes.
    rs_peek(W0)                       // diff
    jsr deref_W0_to_W2
    sta B0
    clc
    lda B0
    adc #1
    jsr _brnd_alloc_rand              // RV = rand
    rs_push(RV)                       // RS: [args, start, end, diff, rand]

    // mod_result = rand % diff. int_mod: dividend deeper, divisor top.
    rs_peek_at(W0, 1)                 // diff
    rs_push(W0)                       // RS: [.., diff, rand, diff]
    jsr int_mod                       // RV = rand % diff. RS: [args, start, end, diff]

    // result = start + mod_result.
    rs_peek_at(W0, 2)                 // start (depth 2 above end, diff)
    rs_push(W0)                       // RS: [.., diff, start]
    rs_push(RV)                       // RS: [.., diff, start, mod_result]
    jsr int_add                       // RV = start + mod_result
    jmp postamble

_brnd_two_float:
    // -------- 2-arg FLOAT path --------
    // RS: [args, start, end]. diff = end - start.
    rs_peek_at(W0, 1)                 // start
    rs_peek_at(W1, 0)                 // end
    rs_push(W1)                       // RS: [args, start, end, end]
    rs_push(W0)                       // RS: [args, start, end, end, start]
    jsr float_sub                     // RV = end - start
    rs_push(RV)                       // RS: [args, start, end, diff]

    // frnd = float_random()
    jsr float_random
    rs_push(RV)                       // RS: [args, start, end, diff, frnd]

    // scaled = frnd * diff
    rs_peek_at(W0, 1)                 // diff
    rs_push(W0)                       // RS: [.., diff, frnd, diff]
    jsr float_mul                     // RV = frnd * diff

    // result = start + scaled
    rs_peek_at(W0, 2)                 // start
    rs_push(W0)
    rs_push(RV)
    jsr float_add                     // RV = start + scaled
    jmp postamble

// Leaf helper: allocate an INT of A bytes filled with rand8 entropy in
// bytes 0..A-2, with byte A-1 = 0 (sign byte to ensure non-negative).
//   in:  A = total byte count (A ≥ 2 expected).
//   out: RV = new INT handle. Bytes 0..A-2 = rand8(); byte A-1 = 0.
//   clobbers: A, X, Y, W2. Preserves W0/W1/B0..B7 — alloc_int is V4'.
_brnd_alloc_rand:
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2

    ldy ALLOC_SIZE
    dey
    lda #0
    sta (W2),y                        // top byte = 0 (sign-extension byte)
_brnd_fill_loop:
    dey
    bmi _brnd_fill_done
    jsr rand8
    sta (W2),y
    jmp _brnd_fill_loop
_brnd_fill_done:
    rts

// =============================================================================
// builtin_sort(S [, reverse]) — return a sorted version of S.
//   in:  args[0] = me (TYPE_STR, TYPE_TUPLE, or TYPE_LIST).
//        args[1] = optional truthy flag — non-falsy → descending order.
//   out: RV = sorted result. STR/TUPLE return a fresh sorted copy. LIST is
//        sorted in place (RV = same handle).
//
// Insertion sort. STR sorts bytes; TUPLE/LIST sort handles via val_cmp.
// `reverse` is implemented via 1-byte self-modifying code at the comparator
// branch site — `_bsb_branch` flips between BCS ($B0, asc) and BCC ($90, desc)
// for the byte sort; `_bsh_cmp_imm` flips the val_cmp threshold between #1
// (asc: swap when left>right) and #$FF (desc: swap when left<right).
// =============================================================================
builtin_sort:
    preamble_call(1, 2)

    // Stage default ASC SMC opcodes in X/Y. If a 2nd arg is supplied and is
    // truthy, swap to DESC opcodes before the single store at _bs_apply.
    ldx #$B0                          // BCS opcode  (asc: skip swap when arr[j] >= arr[j-1])
    ldy #1                            // cmp #1     (asc: swap when val_cmp == +1)
    lda B7
    cmp #2
    bne _bs_apply
    arg_get(1, W0)
    jsr val_truthy                    // A = 0 (falsy) or 1 (truthy); leaf, no GC
    beq _bs_apply
    ldx #$90                          // BCC opcode (desc: skip swap when arr[j] < arr[j-1])
    ldy #$FF                          // cmp #$FF   (desc: swap when val_cmp == -1)
_bs_apply:
    stx _bsb_branch
    sty _bsh_cmp_imm
    arg_get(0, W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq _bsort_str
    cmp #TYPE_TUPLE
    bne !try_list+
    jmp _bsort_tuple
!try_list:
    cmp #TYPE_LIST
    bne !panic+
    jmp _bsort_list
!panic:
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_bsort_str:
    // Clone via `array_repeat` with n=1.
    arg_get(0, W0)
    rs_push(W0)
    rs_push_const(INT_1)
    jsr array_repeat                  // RV = clone (TYPE_STR)
    rs_push(RV)                       // RS: [args_tuple, clone]

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
    arg_get(0, W0)
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
    arg_get(0, W0)
    jsr deref_W0_to_W2
    sta B0
    lda W2
    sta W3
    lda W2+1
    sta W3+1
    jsr _bsort_handles
    arg_get(0, RV)                    // return same list handle
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
.label _bsb_branch = *
    bcs _bsb_on                       // SMC: $B0 (BCS, asc) / $90 (BCC, desc)
                                      // asc: skip swap when arr[j] >= arr[j-1]
                                      // desc: skip swap when arr[j] < arr[j-1]
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
.label _bsh_cmp_imm = * + 1
    cmp #1                             // SMC: #1 (asc, swap when left>right)
                                       //      #$FF (desc, swap when left<right)
    bne _bsh_on                        // mismatch → done with this j

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
    jsr preamble_call_1_1_w0
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq _brepr_quote

    // Non-string: delegate to builtin_str via _str_w0 (wraps W0 in a new
    // 1-tuple under v2 calling convention).
    jsr _str_w0
    jmp postamble

_brepr_quote:
    // Build "'" ++ me ++ "'" via two array_merge calls. W0 already holds me.
    rs_push_const(STR_QUOTE)         // RS: [args_tuple, "'"]
    rs_push(W0)                      // RS: [args_tuple, "'", me]
    jsr array_merge                  // RV = "'me"; RS: [args_tuple]
    rs_push(RV)                      // RS: [args_tuple, "'me"]
    rs_push_const(STR_QUOTE)         // RS: [args_tuple, "'me", "'"]
    jsr array_merge                  // RV = "'me'"; RS: [args_tuple]
    jmp postamble

// =============================================================================
// builtin_type(x) — return INT holding the H_TYPE tag byte.
// =============================================================================
builtin_type:
    jsr preamble_call_1_1_w0
    ldy #H_TYPE
    lda (W0),y
    sta B0
    jmp postamble_set_rv_int_b0

// =============================================================================
// builtin_id(x) — return the handle address of x as a non-negative INT.
// Allocated as a 3-byte int with high byte 0 so addresses with bit 15 set
// (e.g. handles around $C000+) stay positive.
// =============================================================================
builtin_id:
    jsr preamble_call_1_1_w0

    lda #3
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2
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
// builtin_globals() / builtin_locals() — return a scope dict.
//   globals() = ROOT_SCOPE (program-level, set once at parser_eval start)
//   locals()  = GLOBAL_SCOPE (current; differs from ROOT_SCOPE only inside a
//              string-call lambda where led_lparen swaps to a per-call scope)
//
// Mirrors Admiral's `built_in_globals` / `built_in_locals`
// (builtin.dasm16:260, 251).
//
// Body shared via the classic `.byte $2C` BIT-abs trick: globals's `ldx #0`
// falls into the BIT prefix, which then eats locals's `ldx #$FE` (= -2) as
// its operand. Both entry points end up at the shared `lda ROOT_SCOPE,x`
// where the indexed ZP read targets either ROOT_SCOPE ($44) when X=0 or
// GLOBAL_SCOPE ($42) when X=$FE (lda zp,x wraps within $00-$FF). RV and
// B0..B6 are preserved across preamble_call, so we stash the result before
// the call instead of after — saving the dance through B0/B1.
//
// The dummy BIT read targets $FEA2 (KERNAL ROM with $01=$36 steady state) —
// pure read, no side effects. Flags clobber is harmless here.
// =============================================================================
builtin_globals:
    ldx #0
    .byte $2C                    // BIT abs — eats next 2 bytes
builtin_locals:
    ldx #$FE                     // -2: shifts ZP base from ROOT_SCOPE to GLOBAL_SCOPE
    lda ROOT_SCOPE,x
    sta RV
    lda ROOT_SCOPE+1,x
    sta RV+1
    preamble_call(0, 0)
    jmp postamble

// =============================================================================
// builtin_mem() — full GC cycle, then return the contiguous free heap byte
// count as INT. Free = NEXT_HANDLE - NEXT_DATA. The gap is bounded by
// HEAP_HANDLE_START - HEAP_DATA_START (~$4800 < $8000), so it always fits in
// a non-negative 2-byte signed int; int_normalize strips the high byte if
// the value happens to be < 256.
// Mirrors Admiral's `built_in_mem` (builtin.dasm16:232).
// =============================================================================
builtin_mem:
    preamble_call(0, 0)
    jsr gc_collect

    sec
    lda NEXT_HANDLE
    sbc NEXT_DATA
    sta B0
    lda NEXT_HANDLE+1
    sbc NEXT_DATA+1
    sta B1

    lda #2
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2
    lda B0
    ldy #0
    sta (W2),y
    iny
    lda B1
    sta (W2),y

    rs_push(RV)
    jsr int_normalize
    jmp postamble

// =============================================================================
// builtin_cmp(a, b) — three-way compare via val_cmp.
//   Returns INT: -1 if a < b, 0 if a == b, 1 if a > b.
// =============================================================================
builtin_cmp:
    jsr preamble_call_2_2_w0_w1
    rs_push(W0)
    rs_push(W1)
    jsr val_cmp                        // A = $FF / $00 / $01; consumes pushed args
    sta B0

    lda #1
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2
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
    jsr preamble_call_1_1_w0

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

    bmi _bhex_negative

    // Positive — magnitude IS the original. Push it for uniform re-deref below.
    arg_get(0, W0)
    rs_push(W0)                         // RS: [args_tuple, magnitude=orig]
    jmp _bhex_have_mag

_bhex_negative:
    // Negate to get magnitude, root it on RS for GC.
    arg_get(0, W0)
    rs_push(W0)
    jsr int_negate
    rs_push(RV)                         // RS: [args_tuple, magnitude]
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

    jsr deref_RV_to_W3                  // dst = RV's payload base

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
// builtin_wset(col, row, ch) — direct screen poke at (col, row).
//   col, row : INTs in [0, SCREEN_COLS) / [0, SCREEN_ROWS).
//   ch       : 1-char TYPE_STR (PETSCII).
// PETSCII is translated to a screen code via the same rule as
// screen_put_char. Color RAM at the same position is set to COLOR_FG.
// Returns None. Out-of-range / wrong types → return None silently (Admiral
// `built_in_win_set` parity, builtin.dasm16:831).
// =============================================================================
builtin_wset:
    preamble_call(3, 3)

    arg_get(0, W0)
    jsr int_to_unsigned_byte_W0
    bcc _bws_done
    cmp #SCREEN_COLS
    bcs _bws_done
    sta B0                       // B0 = col

    arg_get(1, W0)
    jsr int_to_unsigned_byte_W0
    bcc _bws_done
    cmp #SCREEN_ROWS
    bcs _bws_done
    sta B1                       // B1 = row

    arg_get(2, W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    bne _bws_done
    jsr deref_W0_to_W2
    cmp #1
    bne _bws_done
    ldy #0
    lda (W2),y                   // PETSCII byte
    jsr petscii_to_screen_code
    sta B2                       // B2 = screen code

    lda B1
    jsr scr_row_offset_to_w2_a   // W2 = SCREEN_BASE + row*40
    ldy B0
    lda B2
    sta (W2),y

    // Color cell at COLOR_BASE + row*40 + col (same low byte as W2).
    lda W2
    sta W3
    lda W2+1
    clc
    adc #>(COLOR_BASE - SCREEN_BASE)   // $D4 — see screen.asm for parens note
    sta W3+1
    lda #COLOR_FG
    sta (W3),y

_bws_done:
    jmp postamble_return_none


// =============================================================================
// builtin_wget(col, row) — read screen at (col, row), return 1-char TYPE_STR.
// Out-of-range → return None.
//
// Reverses screen_put_char's translation: screen codes $00..$1F → PETSCII
// $40..$5F. Anything else passes through unchanged.
// =============================================================================
builtin_wget:
    preamble_call(2, 2)

    arg_get(0, W0)
    jsr int_to_unsigned_byte_W0
    bcc _bwg_oob
    cmp #SCREEN_COLS
    bcs _bwg_oob
    sta B0

    arg_get(1, W0)
    jsr int_to_unsigned_byte_W0
    bcc _bwg_oob
    cmp #SCREEN_ROWS
    bcs _bwg_oob
    sta B1

    lda B1
    jsr scr_row_offset_to_w2_a
    ldy B0
    lda (W2),y                   // screen code
    cmp #$20
    bcs _bwg_no_inv
    clc
    adc #$40                     // $00..$1F → $40..$5F PETSCII
_bwg_no_inv:
    sta B0                       // PETSCII byte
    jsr str_alloc_1_b0
    jmp postamble

_bwg_oob:
    jmp postamble_return_none


// =============================================================================
// builtin_cursor([col, row]) — get/set cursor.
//   0 args : returns (col, row) tuple of two 1-byte INTs.
//   2 args : sets cursor (clamped to screen bounds), returns None.
//   1 arg  : ERR_ARITY.
// Mirrors Admiral's `built_in_cursor` (builtin.dasm16:753).
// =============================================================================
builtin_cursor:
    preamble_call(0, 2)
    lda B7
    beq _bcur_get
    cmp #2
    beq _bcur_set
    lda #ERR_ARITY
    sta ERROR_CODE
    jmp error_handler

_bcur_set:
    arg_get(0, W0)
    jsr int_to_unsigned_byte_W0
    bcc _bcur_clamp_col_max
    cmp #SCREEN_COLS
    bcc _bcur_set_col
_bcur_clamp_col_max:
    lda #SCREEN_COLS - 1
_bcur_set_col:
    sta SCREEN_COL

    arg_get(1, W0)
    jsr int_to_unsigned_byte_W0
    bcc _bcur_clamp_row_max
    cmp #SCREEN_ROWS
    bcc _bcur_set_row
_bcur_clamp_row_max:
    lda #SCREEN_ROWS - 1
_bcur_set_row:
    sta SCREEN_ROW
    jmp postamble_return_none

_bcur_get:
    lda SCREEN_COL
    sta B0
    jsr _bcur_alloc_int_b0
    rs_push(RV)                  // RS: [args, col]

    lda SCREEN_ROW
    sta B0
    jsr _bcur_alloc_int_b0
    rs_push(RV)                  // RS: [args, col, row]

    lda #2
    jsr tuple_alloc              // RV = new 2-tuple
    rs_push(RV)                  // RS: [args, col, row, tuple]

    rs_peek(W0)                  // tuple
    rs_peek_at(W1, 2)            // col
    lda #0
    jsr tuple_set_leaf           // tuple[0] = col

    rs_peek_at(W1, 1)            // row (W0 still tuple — preserved by tuple_set_leaf)
    lda #1
    jsr tuple_set_leaf           // tuple[1] = row

    rs_peek(RV)                  // RV = tuple
    jmp postamble


// _bcur_alloc_int_b0 — allocate a 1-byte INT containing B0.
//   in:  B0 = value (0..255)
//   out: RV = new TYPE_INT handle.
//   clobbers: A, X, Y, W2.
_bcur_alloc_int_b0:
    lda #1
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2
    lda B0
    ldy #0
    sta (W2),y
    rts


// =============================================================================
// builtin_scroll([n]) — scroll the screen up by `n` lines (default 1).
// `n` is clamped to [0, SCREEN_ROWS]: 0 is a no-op; SCREEN_ROWS or more
// blanks the entire screen. Other types / bad values pass through as 1.
// Returns None.
// =============================================================================
builtin_scroll:
    preamble_call(0, 1)
    ldx #1                       // default n
    lda B7
    beq _bsc_have_n
    arg_get(0, W0)
    jsr int_to_unsigned_byte_W0
    bcc _bsc_have_n              // bad arg → keep default
    cmp #SCREEN_ROWS
    bcc _bsc_n_in_range
    lda #SCREEN_ROWS
_bsc_n_in_range:
    tax
_bsc_have_n:
    cpx #0
    beq _bsc_done
_bsc_loop:
    txa
    pha                          // save counter — screen_scroll_up clobbers X
    jsr screen_scroll_up
    pla
    tax
    dex
    bne _bsc_loop
_bsc_done:
    jmp postamble_return_none


// =============================================================================
// builtin_cls() — clear screen, cursor → (0,0). Returns None.
// =============================================================================
builtin_cls:
    preamble_call(0, 0)
    jsr screen_clear
    jmp postamble_return_none


// =============================================================================
// builtin_getc() — block until KERNAL GETIN returns a non-zero byte; return
// it as a 1-char TYPE_STR. Mirrors Admiral's `built_in_getchar`
// (builtin.dasm16:661).
// =============================================================================
builtin_getc:
    preamble_call(0, 0)
_bgc_spin:
    inc $01                            // $34 → $35 → $36 (KERNAL+I/O in)
    inc $01
    jsr KERNAL_GETIN
    pha
    dec $01
    dec $01
    pla
    beq _bgc_spin
    sta B0
    jsr str_alloc_1_b0
    jmp postamble


// =============================================================================
// builtin_key() — non-blocking GETIN poll. Returns a 1-char TYPE_STR if a
// key was buffered, else None. Mirrors Admiral's `built_in_key`.
// =============================================================================
builtin_key:
    preamble_call(0, 0)
    inc $01                            // $34 → $36 (KERNAL+I/O in)
    inc $01
    jsr KERNAL_GETIN
    pha
    dec $01
    dec $01
    pla
    beq _bky_empty
    sta B0
    jsr str_alloc_1_b0
    jmp postamble
_bky_empty:
    jmp postamble_return_none


// =============================================================================
// builtin_input([prompt]) — read a line of PETSCII from the keyboard and
// return it as a TYPE_STR (without the trailing newline).
//
// If `prompt` (a TYPE_STR) is supplied, it is printed first via print_str.
// The buffer is capped at INPUT_CAP bytes (extra keystrokes are dropped).
//
// Editing keys:
//   $0D (RETURN)  — finish input; echo a newline, return the buffer.
//   $14 (DEL)     — if buffer is non-empty, drop the last char and erase it
//                   from the screen (cursor walks back, blank cell painted).
//   else          — append to the buffer (if room) and echo via screen_put_char.
//
// Mirrors Admiral's `built_in_input` (builtin.dasm16:135).
// =============================================================================
.const INPUT_CAP = 80

builtin_input:
    preamble_call(0, 1)

    lda B7
    beq _bin_alloc_buf

    // Validate prompt is TYPE_STR; print it.
    arg_get(0, W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq _bin_print_prompt
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler
_bin_print_prompt:
    arg_get(0, W0)
    rs_push(W0)
    jsr print_str

_bin_alloc_buf:
    // Allocate INPUT_CAP-byte STR. We write actual content as we go and trim
    // O_LEN at the end. Root the handle on RS so GC during the loop (none
    // expected, but defense in depth) keeps the payload alive.
    lda #INPUT_CAP
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr str_alloc
    rs_push(RV)                    // RS: [..., buf]

    lda #0
    sta B0                         // B0 = current length

_bin_loop:
    inc $01                            // $34 → $36 (KERNAL+I/O in)
    inc $01
    jsr KERNAL_GETIN
    pha
    dec $01
    dec $01
    pla
    beq _bin_loop

    cmp #$0D
    beq _bin_return
    cmp #$14
    beq _bin_del

    // Append (if room).
    sta B1                         // save char
    lda B0
    cmp #INPUT_CAP
    bcs _bin_loop                  // full — drop the keypress

    rs_peek(W0)
    jsr deref_W0_to_W2             // W2 = buf payload
    ldy B0
    lda B1
    sta (W2),y
    inc B0

    lda B1
    jsr screen_put_char
    jmp _bin_loop

_bin_del:
    lda B0
    beq _bin_loop                  // empty buffer → ignore DEL
    dec B0

    // Walk cursor back one cell. At col 0, wrap to previous row's last col.
    // If already at top-left we just stop walking (rare; the user is wiping
    // out a multi-line entry from the start).
    lda SCREEN_COL
    bne _bin_del_dec_col
    lda SCREEN_ROW
    beq _bin_del_blank             // at (0,0) — leave cursor; still blank cell
    dec SCREEN_ROW
    lda #SCREEN_COLS - 1
    sta SCREEN_COL
    jmp _bin_del_blank
_bin_del_dec_col:
    dec SCREEN_COL
_bin_del_blank:
    jsr scr_row_offset_to_w2
    ldy SCREEN_COL
    lda #$20
    sta (W2),y
    jmp _bin_loop

_bin_return:
    // Trim the buffer's O_LEN to the actual length.
    rs_peek(W0)
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda B0
    sta (W2),y
    iny
    lda #0
    sta (W2),y

    // Echo the closing newline so subsequent print starts on a fresh row.
    lda #$0D
    jsr screen_put_char

    rs_peek(RV)
    jmp postamble


// =============================================================================
// builtin_edit([text]) — full-screen gap-buffer text editor.
//
//   edit()           → empty STR after the editor session.
//   edit(text)       → STR with the edited content; buffer pre-loaded with
//                     `text`.
//
// F1 saves and returns the buffer; F3 cancels and returns the original arg
// (or "" if no arg). Cursor keys / BS / RETURN edit the buffer in place.
// Mirrors Admiral's `built_in_input → edit_main`.
//
// Called via the V4' convention. The main editor buffer (EDIT_BUF_SIZE bytes)
// is rooted on RS for the lifetime of the call so GC during the post-finish
// result alloc doesn't reclaim it. No alloc happens inside the main loop —
// pointers stay stable.
// =============================================================================
builtin_edit:
    preamble_call(0, 1)

    // Allocate the editor buffer.
    lda #<EDIT_BUF_SIZE
    sta ALLOC_SIZE
    lda #>EDIT_BUF_SIZE
    sta ALLOC_SIZE+1
    jsr str_alloc
    rs_push(RV)                       // RS: [args, buf]

    // Init editor state.
    rs_peek(W0)
    jsr deref_W0_to_W2                // W2 = buf payload
    lda W2
    sta W0
    lda W2+1
    sta W0+1
    lda #<EDIT_BUF_SIZE
    sta W2
    lda #>EDIT_BUF_SIZE
    sta W2+1
    jsr edit_init

    // If 1 arg given, copy text into buffer via edit_insert_char.
    lda B7
    beq _bedit_render_initial
    arg_get(0, W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq _bedit_arg_str_ok
    jmp _bedit_panic_type
_bedit_arg_str_ok:
    arg_get(0, W0)
    jsr deref_W0_to_W2                // W2 = arg payload, A = O_LEN
    sta B4                             // B4 = length
    lda W2
    sta B2
    lda W2+1
    sta B3
    lda #0
    sta B5                             // B5 = index
_bedit_copy:
    lda B5
    cmp B4
    bcs _bedit_render_initial
    lda B2
    sta W0
    lda B3
    sta W0+1
    ldy B5
    lda (W0),y
    jsr edit_insert_char
    inc B5
    jmp _bedit_copy

_bedit_render_initial:
    jsr screen_clear
    jsr edit_view_focus
    jsr edit_draw_screen
    lda edit_scr_x
    sta SCREEN_COL
    lda edit_scr_y
    sta SCREEN_ROW

_bedit_loop:
    // Show cursor (reverse-video the cell at SCREEN_COL/ROW) before polling.
    // _bedit_after_key updates SCREEN_COL/ROW so the cursor reappears at the
    // post-edit position each time round.
    jsr screen_show_cursor

_bedit_poll:
    // KERNAL is normally banked OUT ($01 = MEM_NORMAL = $34). Flip it back
    // in for the GETIN call only, then bank back out so the rest of the
    // editor body runs in the steady-state config.
    inc $01                            // $34 → $36 (KERNAL+I/O in)
    inc $01
    jsr KERNAL_GETIN
    pha
    dec $01
    dec $01
    pla
    bne _bedit_got_key
    jmp _bedit_poll

_bedit_got_key:
    // Hide the cursor before any redraw — key handlers that mutate the
    // buffer call edit_draw_line / edit_draw_screen, which overwrite cells
    // unconditionally; if the cursor's bit-7 is still set on a cell those
    // routines don't touch, it would linger as a stale highlight. Hiding
    // here keeps cell state in sync with the model.
    pha
    jsr screen_hide_cursor
    pla

_bedit_dispatch:
    // Branch range to handlers is too far for relative beq; trampoline
    // through near JMPs.
    cmp #$85                           // F1 → save & exit
    bne !+
    jmp _bedit_save
!:
    cmp #$86                           // F3 → cancel
    bne !+
    jmp _bedit_cancel
!:
    // F5 (kill) is the only key that does NOT clear edit_clip_cut, so the
    // accumulating-cut behavior works. Handle it before the reset.
    cmp #$87                           // F5 → kill line
    bne !+
    jsr edit_key_kill
    jmp _bedit_after_key
!:
    // Any other key resets clip_cut so the next F5 starts a fresh kill.
    pha
    lda #0
    sta edit_clip_cut
    pla
    cmp #$88                           // F7 → yank
    bne !+
    jsr edit_key_yank
    jmp _bedit_after_key
!:
    cmp #$0D                           // RETURN
    beq _bedit_newline
    cmp #$14                           // INST/DEL → backspace
    beq _bedit_bs
    cmp #$11                           // CRSR-DOWN
    beq _bedit_down
    cmp #$91                           // SHIFT+CRSR-DOWN = up
    beq _bedit_up
    cmp #$1D                           // CRSR-RIGHT
    beq _bedit_right
    cmp #$9D                           // SHIFT+CRSR-RIGHT = left
    beq _bedit_left
    // Printable PETSCII: $20-$7E (ASCII) or $A0-$FE (graphics).
    cmp #$20
    bcs _bedit_check_printable
    jmp _bedit_loop
_bedit_check_printable:
    cmp #$7F
    bcc _bedit_insert
    cmp #$A0
    bcs _bedit_check_high_printable
    jmp _bedit_loop
_bedit_check_high_printable:
    cmp #$FF
    bcc _bedit_insert
    jmp _bedit_loop

_bedit_insert:
    // Lowercase-fold ASCII A-Z so the lexer recognizes keywords (its keyword
    // table is lowercase-only). The REPL's read_line does the same fold;
    // edit() needs to match so a buffer typed in the editor and exec'd as
    // a string call (`a = edit()` then `a()`) parses identically to a line
    // typed at the prompt.
    cmp #$41                           // 'A'
    bcc _bedit_insert_do
    cmp #$5B                           // 'Z'+1
    bcs _bedit_insert_do
    clc
    adc #$20                           // A-Z → a-z
_bedit_insert_do:
    jsr edit_insert_char
    jmp _bedit_after_key
_bedit_newline:
    jsr edit_key_newline
    jmp _bedit_after_key
_bedit_bs:
    jsr edit_key_bs
    jmp _bedit_after_key
_bedit_left:
    jsr edit_key_left
    jmp _bedit_after_key
_bedit_right:
    jsr edit_key_right
    jmp _bedit_after_key
_bedit_up:
    jsr edit_key_up
    jmp _bedit_after_key
_bedit_down:
    jsr edit_key_down
    jmp _bedit_after_key

_bedit_after_key:
    jsr edit_view_focus
    lda edit_dirty
    and #$02
    beq _bedit_check_line_dirty
    jsr edit_draw_screen
    jmp _bedit_update_cursor
_bedit_check_line_dirty:
    lda edit_dirty
    and #$01
    beq _bedit_update_cursor
    jsr edit_draw_current_line
_bedit_update_cursor:
    lda edit_scr_x
    sta SCREEN_COL
    lda edit_scr_y
    sta SCREEN_ROW
    jmp _bedit_loop

_bedit_save:
    jsr screen_clear
    // logical_size = (gap_start - buf_start) + (buf_end - gap_end)
    sec
    lda edit_gap_start
    sbc edit_buf_start
    sta B0
    lda edit_gap_start+1
    sbc edit_buf_start+1
    sta B1
    sec
    lda edit_buf_end
    sbc edit_gap_end
    sta B2
    lda edit_buf_end+1
    sbc edit_gap_end+1
    sta B3
    clc
    lda B0
    adc B2
    sta ALLOC_SIZE
    lda B1
    adc B3
    sta ALLOC_SIZE+1
    jsr str_alloc                      // RV = result handle
    rs_push(RV)                        // RS: [args, buf, result]

    // Copy logical content into result. RS-rooted source pointers (gap
    // pointers) survive — and the buffer alloc happened before the loop
    // (no further allocations from here), so static pointers are stable.
    rs_peek(W0)
    jsr deref_W0_to_W2                 // W2 = result payload
    lda W2
    sta W3
    lda W2+1
    sta W3+1

    // pre-gap [buf_start..gap_start)
    lda edit_buf_start
    sta W0
    lda edit_buf_start+1
    sta W0+1
_bedit_save_pre:
    lda W0
    cmp edit_gap_start
    bne _bedit_save_pre_step
    lda W0+1
    cmp edit_gap_start+1
    beq _bedit_save_post
_bedit_save_pre_step:
    ldy #0
    lda (W0),y
    sta (W3),y
    inc W0
    bne !+
    inc W0+1
!:
    inc W3
    bne !+
    inc W3+1
!:
    jmp _bedit_save_pre

_bedit_save_post:
    lda edit_gap_end
    sta W0
    lda edit_gap_end+1
    sta W0+1
_bedit_save_post_loop:
    lda W0
    cmp edit_buf_end
    bne _bedit_save_post_step
    lda W0+1
    cmp edit_buf_end+1
    beq _bedit_finish
_bedit_save_post_step:
    ldy #0
    lda (W0),y
    sta (W3),y
    inc W0
    bne !+
    inc W0+1
!:
    inc W3
    bne !+
    inc W3+1
!:
    jmp _bedit_save_post_loop

_bedit_finish:
    rs_peek(RV)                        // RV = result (top of RS)
    jmp postamble

_bedit_cancel:
    jsr screen_clear
    lda B7
    beq _bedit_cancel_empty
    arg_get(0, RV)
    jmp postamble
_bedit_cancel_empty:
    lda #0
    sta ALLOC_SIZE
    sta ALLOC_SIZE+1
    jsr str_alloc
    jmp postamble

_bedit_panic_type:
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler


// =============================================================================
// Method-style builtins. Receiver is tuple slot 0 — `led_dot` stages
// METHOD_RECEIVER which `led_lparen` prepends to the args tuple as element 0
// before calling. For an N-arg method like obj.m(a, b), the args tuple is
// (obj, a, b) and the impl reads obj via `arg_get(0, ...)`.
// =============================================================================

// --- str.upper() — return a new TYPE_STR with ASCII letters folded UP -------
//   in:  args = (me,)   me: TYPE_STR
// =============================================================================
builtin_str_upper:
    jsr preamble_call_1_1_w0
    rs_push(W0)                       // root me at RS top so we can re-deref after alloc
    jsr deref_W0_to_W2                // W2 = me payload, A = O_LEN
    sta B0                            // B0 = len

    lda B0
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                         // RV = new STR

    // src = me.payload (re-deref post-GC); dst = RV.payload.
    rs_peek(W0)
    jsr deref_W0_to_W3
    jsr deref_RV_to_W2

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
//   in:  args = (me,)   me: TYPE_STR
// =============================================================================
builtin_str_lower:
    jsr preamble_call_1_1_w0
    rs_push(W0)                       // root me at RS top
    jsr deref_W0_to_W2
    sta B0

    lda B0
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc

    // src = me.payload; dst = RV.payload.
    rs_peek(W0)
    jsr deref_W0_to_W3
    jsr deref_RV_to_W2

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

// --- str.find(sub[, start[, end]]) — return first position or -1 ----------
//   in:  args = (me, sub)               full-range search
//        args = (me, sub, start)         search from `start`
//        args = (me, sub, start, end)    search in `[start, end)`
//      All ints are taken as 8-bit signed; negatives are normalized via
//      `me_len + idx` and then clamped to `[0, me_len]`. Larger-magnitude
//      negatives clamp to 0.
//
// str_find_pos expects RS = [needle (deeper), haystack (top)] and reads
// B5 (start) / B6 (end_excl, $FF=sentinel for "haystack_len") as inputs.
// =============================================================================
builtin_str_find:
    preamble_call(2, 4)

    // Cache me's length first — needed for negative-index normalization.
    arg_get(0, W0)
    jsr deref_W0_to_W2
    sta B0                            // B0 = me_len

    // Default range: full string.
    lda #0
    sta B5                            // start
    lda #$FF
    sta B6                            // end (sentinel → haystack_len)

    lda B7
    cmp #3
    bcc _bfind_args_done

    // Read start (arg index 2) — low byte of int payload, signed.
    arg_get(2, W0)
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    bpl _bfind_start_set
    clc
    adc B0
    bpl _bfind_start_set              // raw + len ≥ 0 → use that
    lda #0                            // far-negative → 0
_bfind_start_set:
    sta B5

    lda B7
    cmp #4
    bcc _bfind_args_done

    // Read end (arg index 3) — same sign-handling.
    arg_get(3, W0)
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    bpl _bfind_end_set
    clc
    adc B0
    bpl _bfind_end_set
    lda #0
_bfind_end_set:
    sta B6

_bfind_args_done:
    // Push needle, haystack on RS for str_find_pos.
    arg_get(0, W0)
    arg_get(1, W1)
    rs_push(W1)                       // sub deeper
    rs_push(W0)                       // me top
    jsr str_find_pos                  // A = pos or $FF
    sta B0

    // Allocate 2-byte signed INT (so positions ≥ 128 stay positive).
    lda #2
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2

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
//   in:  args = (me, prefix)
// =============================================================================
builtin_str_startswith:
    jsr preamble_call_2_2_w0_w1
    // Cache both args before clobbering W3 (which arg_get reads from).
    jsr deref_W1_to_W3                // W3 = prefix payload, A = prefix len
    sta B0                            // B0 = prefix len
    jsr deref_W0_to_W2                // W2 = me payload, A = me len
    sta B1                            // B1 = me len

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
    jmp postamble_return_true
_bsw_false:
    jmp postamble_return_false

// --- str.endswith(suffix) ---------------------------------------------------
//   in:  args = (me, suffix)
// =============================================================================
builtin_str_endswith:
    jsr preamble_call_2_2_w0_w1
    jsr deref_W1_to_W3                // W3 = suffix payload, A = suffix len
    sta B0                            // B0 = suffix len
    jsr deref_W0_to_W2                // W2 = me payload, A = me len
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
    jmp postamble_return_true
_bew_false:
    jmp postamble_return_false

// --- str.split(sep=None) — list of substrings -----------------------------
//   in:  args = (me)         — whitespace mode
//        args = (me, sep)    — explicit-separator mode
//   out: RV = TYPE_LIST of TYPE_STR. Args consumed.
//
// Whitespace mode (no sep): split on runs of $20/$0D, drop empty segments,
// strip leading/trailing whitespace. `"".split()` → [].
//
// Sep mode: empty sep → ERR_TYPE. Empty me → [""]. Consecutive seps produce
// empty strings (Python `"a,,b".split(",")` → ["a","","b"]).
// =============================================================================
builtin_str_split:
    preamble_call(1, 2)

    arg_get(0, W0)
    rs_push(W0)                       // RS: [tuple, me]

    lda B7
    cmp #1
    beq _bsp_ws_setup                  // 1-arg form → whitespace mode

    // Sep mode: push sep too. Rest of body reads me at depth 2, sep at
    // depth 1, list at depth 0 (after the alloc).
    arg_get(1, W0)
    rs_push(W0)                       // RS: [tuple, me, sep]
    jmp _bsp_sep_body

_bsp_ws_setup:
    // Whitespace mode reuses the same emit_segment helper as sep mode, which
    // expects me at depth 3 of [tuple, me, sep, list, seg]. Push me a second
    // time as a "sep slot" decoy — its bytes are never inspected by the
    // helper, but it preserves layout and is GC-safe (it's a real handle).
    rs_peek(W0)
    rs_push(W0)                       // RS: [tuple, me, me_decoy]
    jmp _bsp_ws_body

_bsp_sep_body:

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
    rs_push(RV)                       // RS: [args_tuple, me, sep, list]

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
// list. Caller's RS at entry: [args_tuple, me, sep, list]. Helper must NOT
// change that on return.
//
// Preserves: B0, B1, B2, B4. Clobbers: A, X, Y, B5..B7, W0..W3, RV.
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
    rs_push(RV)                       // RS: [args_tuple, me, sep, list, seg]

    // Copy me[B4..B4+B5] into seg. seg payload first (W3), me payload after (W2).
    rs_peek(W0)                       // seg (slot 0)
    jsr deref_W0_to_W2                // W2 = seg payload
    lda W2
    sta W3
    lda W2+1
    sta W3+1                          // W3 = seg payload (saved)

    rs_peek_at(W0, 3)                 // me (slot 3)
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

    rs_pop(W0)                        // drop the seg root; RS: [args_tuple, me, sep, list]
    rts

// --- whitespace-mode body for builtin_str_split ----------------------------
// RS at entry: [tuple, me, me_decoy]. Allocates the result list, then
// alternates between skipping a run of whitespace and scanning a non-empty
// segment. The decoy slot keeps RS layout aligned with sep mode so we can
// share `_bsp_emit_segment` (which reads `me` at depth 3 during emission).
//
// Whitespace = $20 (space) or $0D (return) — same set the lexer recognizes.
_bsp_ws_body:
    lda #0
    ldx #TYPE_LIST
    jsr _array_alloc_init             // RV = empty list
    rs_push(RV)                       // RS: [tuple, me, me_decoy, list]

    rs_peek_at(W0, 2)                 // me
    jsr deref_W0_to_W2                // W2 = me payload, A = me_len
    sta B0

    lda #0
    sta B3                            // pos

_bsp_ws_skip:
    // Walk past whitespace until either end-of-string or first segment char.
    lda B3
    cmp B0
    bcs _bsp_ws_done
    ldy B3
    lda (W2),y
    cmp #$20
    beq _bsp_ws_skip_inc
    cmp #$0D
    bne _bsp_ws_seg_start
_bsp_ws_skip_inc:
    inc B3
    jmp _bsp_ws_skip

_bsp_ws_seg_start:
    lda B3
    sta B4                            // segment start = current pos

_bsp_ws_scan:
    lda B3
    cmp B0
    bcs _bsp_ws_emit
    ldy B3
    lda (W2),y
    cmp #$20
    beq _bsp_ws_emit
    cmp #$0D
    beq _bsp_ws_emit
    inc B3
    jmp _bsp_ws_scan

_bsp_ws_emit:
    jsr _bsp_emit_segment             // appends me[B4..B3] to list
    rs_peek_at(W0, 2)                 // re-deref me — emit may have GC'd
    jsr deref_W0_to_W2
    jmp _bsp_ws_skip

_bsp_ws_done:
    rs_peek(RV)                       // RV = list (TOS)
    jmp postamble

// --- str.replace(old, new) — replace all occurrences. ----------------------
//   in:  args = (me, old, new)   all TYPE_STR
//   out: RV = new TYPE_STR with substitutions applied. Args consumed.
//
// Two-pass algorithm: pass 1 counts matches, pass 2 copies. Empty `old`
// panics ERR_TYPE (Python's behaviour is to insert `new` between every char,
// not worth the complexity). Total result must fit in 255 bytes else ERR_OOM.
// =============================================================================
builtin_str_replace:
    preamble_call(3, 3)

    // Mirror the v1 RS layout by re-rooting each arg as its own RS slot.
    // After this, RS: [args_tuple, me, old, new] — same depth scheme as v1's
    // [me, old, new], so the rest of the body reads each slot via familiar
    // peek_at offsets without any args-tuple awareness.
    arg_get(0, W0)
    rs_push(W0)
    arg_get(1, W0)
    rs_push(W0)
    arg_get(2, W0)
    rs_push(W0)

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
//   in:  args = (me,)
// =============================================================================
builtin_str_isalpha:
    jsr preamble_call_1_1_w0
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
    jmp postamble_return_true
_bia_false:
    jmp postamble_return_false

// --- str.isdigit() — TRUE iff every byte is 0-9 (and len > 0) --------------
//   in:  args = (me,)
// =============================================================================
builtin_str_isdigit:
    jsr preamble_call_1_1_w0
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
    jmp postamble_return_true
_bid_false:
    jmp postamble_return_false

// --- list.append(item) — push item; returns NONE -----------------------------
//   in:  args = (me, item)   me: TYPE_LIST
// =============================================================================
builtin_list_append:
    jsr preamble_call_2_2_w0_w1
    rs_push(W0)
    rs_push(W1)
    jsr list_append                   // consumes 2 pushed RS args
    jmp postamble_return_none

// --- list.insert(idx, item) — splice in at idx; returns NONE -----------------
//   in:  args = (me, idx, item)   me: TYPE_LIST, idx: TYPE_INT
// =============================================================================
builtin_list_insert:
    preamble_call(3, 3)
    arg_get(0, W0)                    // me
    arg_get(1, W2)                    // idx handle (use W2 to avoid clobbering W3 yet)
    arg_get(2, W1)                    // item

    // Extract idx byte from int handle → fs_push as a word.
    ldy #H_PTR
    lda (W2),y
    sta W3
    iny
    lda (W2),y
    sta W3+1
    ldy #O_HEADER
    lda (W3),y                        // A = idx byte
    sta W2
    lda #0
    sta W2+1
    fs_push(W2)

    rs_push(W0)                       // RS: [args_tuple, me]
    rs_push(W1)                       // RS: [args_tuple, me, item]
    jsr array_insert                  // consumes 2 RS + 1 FS; mutates me

    jmp postamble_return_none

// --- list.pop() — remove and return last element ----------------------------
//   in:  args = (me,)   me: TYPE_LIST. Empty list → ERR_TYPE.
// =============================================================================
builtin_list_pop:
    jsr preamble_call_1_1_w0

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

// --- dict.keys() — list of keys --------------------------------------------
//   in:  args = (me,)   me: TYPE_DICT
// =============================================================================
builtin_dict_keys:
    jsr preamble_call_1_1_w0
    rs_push(W0)                       // root for _bd_build_list
    lda #0                            // entry-tuple byte offset for the key
    jsr _bd_build_list
    jmp postamble

// --- dict.values() — list of values ----------------------------------------
//   in:  args = (me,)   me: TYPE_DICT
// =============================================================================
builtin_dict_values:
    jsr preamble_call_1_1_w0
    rs_push(W0)                       // root for _bd_build_list
    lda #2                            // entry-tuple byte offset for the value
    jsr _bd_build_list
    jmp postamble

// -----------------------------------------------------------------------------
// _bd_build_list — common body for dict.keys / dict.values. Builds a list of
// either the key (offset 0) or value (offset 2) field of each (key, value)
// 2-tuple in the dict's payload.
//
// in:  A = byte offset within entry tuple (0 = key, 2 = value)
//      RS top = dict handle (caller pushed it as a fresh root before calling;
//      untouched on return).
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
//   in:  args = (me,)   me: TYPE_DICT
//   out: RV = new dict, with new["_"] = me
//
// Mirrors Admiral's `built_in__dict_create` (builtin.dasm16:64). The new dict
// holds a single (`_`, me) entry so scope_get's prototype walk picks up the
// chain.
// =============================================================================
builtin_dict_create:
    jsr preamble_call_1_1_w0

    // Cache me before dict_alloc so we don't depend on W3 (args tuple
    // payload, invalidated by any GC inside dict_alloc).
    rs_push(W0)                       // RS: [args_tuple, me]

    jsr dict_alloc                    // RV = new dict
    rs_push(RV)                       // RS: [args_tuple, me, new]

    // Stage dict_set(new, "_", me): caller pushes (dict, key, value) on top.
    rs_push(RV)                       // RS: [..., me, new, new]
    rs_push_const(STR_UNDERSCORE)     // RS: [..., me, new, new, "_"]
    rs_peek_at(W0, 3)                 // me at depth 3
    rs_push(W0)                       // RS: [..., me, new, new, "_", me]
    jsr dict_set                      // consumes top 3; RS: [args_tuple, me, new]

    rs_peek(RV)                       // RV = new (slot 0)
    jmp postamble

// =============================================================================
// try_builtin_lookup — TST-driven name → impl-address lookup for free-function
// builtins.
//
// Walks the input string RIGHT-TO-LEFT (Y descends from len-1 toward 0; the
// `dey; bmi` flag-fall handles end-of-input without an extra compare).
// `tools/build_tst.py` builds the parallel SoA tables (tst_char/lt/eq/gt/
// payload, tst_impl_lo/hi) with names inserted in reversed character order to
// match this walk direction.
//
// Functions are not first-class values in admiral, so we don't materialize a
// handle on hit — the impl address is delivered straight to the caller in W3
// for direct dispatch through `_call_dispatch`.
//
//   in:  RS top = name handle (TYPE_STR). NOT consumed unless we hit.
//   out: A = 1 on hit  → name popped from RS, W3 = impl_addr.
//        A = 0 on miss → RS unchanged, W3 unspecified.
//   clobbers: A, X, Y, W0, W2.
//
// Leaf routine (no preamble): only ZP scratch is touched.
//
// Walker invariants:
//   X = current TST node id (0..N-1). Sentinel 0 doubles as "no child"; the
//       root is at index 0 but is never anyone's child, so the dual use is
//       unambiguous.
//   Y = current input position. dey wraps 0 → $FF to signal end-of-input.
// =============================================================================
try_builtin_lookup:
    rs_peek(W0)                  // W0 = name handle
    jsr deref_W0_to_W2           // W2 = name payload, A = name length
    tay
    dey                          // Y = last index (or $FF for empty name)
    bmi _tbl_miss
    ldx #0                       // start at root
_tbl_walk:
    lda (W2),y
    cmp tst_char,x
    beq _tbl_eq
    bcs _tbl_gt
    // input < discriminator → descend lt. C=0 from the cmp survives the
    // lda (LDA doesn't touch C), so the bcc is always-taken.
    lda tst_lt,x
    bcc _tbl_check
_tbl_gt:
    lda tst_gt,x
_tbl_check:
    tax
    bne _tbl_walk                // non-zero child id: keep walking
    // Fall through: child id 0 = no child = miss. A is already 0 here
    // because the lda that fed `tax` just read a 0 byte. The empty-name
    // BMI at entry also lands here with A=0 (length).
_tbl_miss:
    rts

_tbl_eq:
    dey
    bmi _tbl_terminal
    // Arrived via beq (C=1, Z=1). dey/bmi/lda all preserve C, so the bcs
    // is always-taken — joins the lt/gt tail at _tbl_check.
    lda tst_eq,x
    bcs _tbl_check

_tbl_terminal:
    // X = node where the last input char matched. tst_payload[X] is 0 if
    // this node is non-terminal (the input was a strict prefix of some
    // registered name → miss), else a 1-based payload index. Load via A
    // so a zero hits _tbl_miss with A=0 already in place for the rts.
    lda tst_payload,x
    beq _tbl_miss
    tay
    dey                          // 1-based → 0-based impl-table index
    lda tst_impl_lo,y
    sta W3
    lda tst_impl_hi,y
    sta W3+1

    rs_pop(W0)                   // caller's contract: pop name on hit

    lda #1
    rts

#import "tst_builtins.asm"

// =============================================================================
// _method_lookup — find a method's impl address by name in a per-type table.
//
// Tables are 0-terminated arrays of (name_handle, impl_addr) pairs:
//   .word STR_NAME_FOO, builtin_foo_impl
//   .word 0   ; sentinel
// Comparison goes through `val_eq` so name-string identity isn't required.
// Methods are not first-class values in admiral, so the table holds raw impl
// addresses and the lookup returns one in RV (the caller copies it into W3
// before invoking `_call_dispatch`).
//
//   in:  W0 = table base, W1 = name handle (TYPE_STR)
//   out: A = 1 if found, 0 if not. RV = impl_addr when A = 1.
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
// Each entry: 2-byte name_handle + 2-byte impl_addr. _method_lookup matches
// by name and returns the impl_addr in RV (caller copies it into W3 for
// _call_dispatch). No method-handle indirection — methods aren't first-class
// values in admiral.
str_methods:
    .word STR_NAME_M_UPPER, builtin_str_upper
    .word STR_NAME_M_LOWER, builtin_str_lower
    .word STR_NAME_M_FIND, builtin_str_find
    .word STR_NAME_M_STARTSWITH, builtin_str_startswith
    .word STR_NAME_M_ENDSWITH, builtin_str_endswith
    .word STR_NAME_M_ISALPHA, builtin_str_isalpha
    .word STR_NAME_M_ISDIGIT, builtin_str_isdigit
    .word STR_NAME_M_REPLACE, builtin_str_replace
    .word STR_NAME_M_SPLIT, builtin_str_split
    .word 0

list_methods:
    .word STR_NAME_M_APPEND, builtin_list_append
    .word STR_NAME_M_INSERT, builtin_list_insert
    .word STR_NAME_M_POP, builtin_list_pop
    .word 0

dict_methods:
    .word STR_NAME_M_KEYS, builtin_dict_keys
    .word STR_NAME_M_VALUES, builtin_dict_values
    .word STR_NAME_M_CREATE, builtin_dict_create
    .word 0
