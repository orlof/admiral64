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
//      builtin into the root scope at start so `range` / `len` resolve
//      via normal scope lookup.
//
// To add a new built-in:
//   a) Write the impl: V4', `preamble_call(MIN, MAX)`, body, `postamble`.
//   b) Add `BUILTIN_<NAME>:` static + `STR_NAME_<NAME>:` static.
//   c) Add a binding line in parser_eval's init.
//
// GC re-deref rule: any sub-call that may allocate (alloc, alloc_inline_int,
// jsr to another builtin, etc.) can move tuple payload via gc_compact. After such a
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
    // Type-guard before the deref: TYPE_INT / TYPE_FLOAT / TYPE_BOOL / TYPE_NONE
    // are not heap-allocated payloads, so dereferencing one (H_PTR is the
    // inline value, not a heap pointer) reads garbage. Panic instead.
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq _blen_panic
    cmp #TYPE_FLOAT
    beq _blen_panic
    cmp #TYPE_BOOL
    beq _blen_panic
    cmp #TYPE_NONE
    beq _blen_panic
    jsr deref_W0_to_W2           // A:X = O_LEN word
    sta W2
    stx W2+1
    lda #0
    sta W3
    sta W3+1
    jmp postamble_set_rv_int32
_blen_panic:
    jmp panic_type

// =============================================================================
// builtin_range — Python-style range, bignum-aware.
//   range(end)              → list of ints 0..end-1
//   range(start, end)       → list of ints start..end-1
//   range(start, end, step) → start, start+step, ... while in range
//
// All args must be TYPE_INT. step == 0 returns an empty list (no infinite
// loop). Direction is taken from sgn(step): step > 0 continues while
// current < end; step < 0 continues while current > end.
//
// Mirrors DCPU Admiral's `built_in_range` (builtin.dasm16:158). The loop
// uses val_cmp + int_add so arbitrarily large ints work.
//
// Register plan during the loop:
//   B0:B1 = current handle (re-set each iter to int_add's result)
//   B2:B3 = end handle (constant)
//   B4:B5 = step handle (constant)
//   B6    = target val_cmp byte  ($FF for asc, $01 for desc)
// `end`, `step`, `list` also live on RS so GC sees them; current rides
// through preamble/postamble via B0:B1 (B regs are callee-saved).
// =============================================================================
builtin_range:
    preamble_call(1, 3)

    // --- Resolve start, end, step from argv based on count (B7) ---
    lda B7
    cmp #1
    bne _br_args_2plus

    // 1-arg form: start = INT_0, end = arg0, step = INT_1.
    arg_get(0, B2)               // end = arg0  (writes B2:B3)
    lda #<INT_0
    sta B0
    lda #>INT_0
    sta B1
    jmp _br_step_default

_br_args_2plus:
    arg_get(0, B0)               // start = arg0 (writes B0:B1)
    arg_get(1, B2)               // end   = arg1 (writes B2:B3)
    lda B7
    cmp #3
    bne _br_step_default
    arg_get(2, B4)               // step  = arg2 (writes B4:B5)
    jmp _br_typecheck

_br_step_default:
    lda #<INT_1
    sta B4
    lda #>INT_1
    sta B5

_br_typecheck:
    // All three handles must be TYPE_INT.
    lda B0
    sta W0
    lda B1
    sta W0+1
    jsr _br_check_int
    lda B2
    sta W0
    lda B3
    sta W0+1
    jsr _br_check_int
    lda B4
    sta W0
    lda B5
    sta W0+1
    jsr _br_check_int

    // --- Determine target cmp byte from sgn(step) ---
    lda B4
    sta W0
    lda B5
    sta W0+1
    // step is inline (W0 = step handle). Zero → empty list. Else sign = bit 31.
    ldy #0
    lda (W0),y
    iny
    ora (W0),y
    iny
    ora (W0),y
    iny
    ora (W0),y
    bne _br_step_nonzero
_br_step_zero:
    lda #0
    jsr list_alloc               // RV = empty list
    jmp postamble                // postamble preserves RV

_br_step_nonzero:
    ldy #3
    lda (W0),y                   // high byte → sign bit
    bmi _br_neg_step
    lda #$FF                     // step > 0 → continue while curr < end
    .byte $2C                    // BIT abs — skip the next `lda #$01`
_br_neg_step:
    lda #$01                     // step < 0 → continue while curr > end
    sta B6

    // --- Allocate empty list and enter the main loop ---
    lda #0
    jsr list_alloc               // RV = empty list
    rs_push(RV)                  // RS: [args_tuple, list]

_br_loop:
    // val_cmp(current, end) → A
    lda B0
    sta W0
    lda B1
    sta W0+1
    rs_push(W0)
    lda B2
    sta W0
    lda B3
    sta W0+1
    rs_push(W0)
    jsr val_cmp                  // consumes 2; A = $FF/$00/$01
    cmp B6
    bne _br_done

    // list.append(list, current)
    rs_peek(W0)                  // W0 = list (TOS)
    rs_push(W0)
    lda B0
    sta W0
    lda B1
    sta W0+1
    rs_push(W0)
    jsr list_append              // consumes 2

    // current = int_add(current, step)
    lda B0
    sta W0
    lda B1
    sta W0+1
    rs_push(W0)
    lda B4
    sta W0
    lda B5
    sta W0+1
    rs_push(W0)
    jsr int_add                  // consumes 2; RV = new int
    lda RV
    sta B0
    lda RV+1
    sta B1
    jmp _br_loop

_br_done:
    jmp postamble_pop_rv         // RV = list

_br_check_int:
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq !ok+
    jmp panic_type
!ok:
    rts

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
    jmp panic_type

_babs_int:
    ldy #0
    jsr arg_get_w0               // W0 = arg0 handle
    ldy #3
    lda (W0),y                   // high byte of inline int (bit 31 = sign)
    bpl _babs_passthrough
    jsr arg0_w0_push
    jsr int_negate               // consumes pushed arg, RV = magnitude
    jmp postamble

_babs_passthrough:
    jmp postamble_arg0_rv

_babs_float:
    // Packed MS-Basic float: byte 1 of payload holds (sign|mantissa-msb).
    // Bit 7 = sign. If clear, already non-negative.
    jsr arg0_w0_deref
    ldy #1
    lda (W2),y
    bpl _babs_passthrough
    jsr arg0_w0_push
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
    jmp panic_type
_bchr_ok:
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    bne _bchr_boxed
    ldy #0
    lda (W0),y                   // inline int: low byte
    sta B0
    jmp _bchr_alloc
_bchr_boxed:
    jsr deref_W0_to_W2           // BOOL: boxed payload byte
    ldy #0
    lda (W2),y
    sta B0
_bchr_alloc:
    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                    // RV = new 1-byte STR

    jsr deref_RV_to_W2           // Y = 0 at exit
    lda B0
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
    jmp panic_type
_bord_ok:
    jsr deref_W0_to_W2           // W2 = payload, A = O_LEN low
    cmp #1
    beq _bord_have
    jmp panic_type
_bord_have:
    lda (W2),y                   // Y = 0 from deref_W0_to_W2
    sta B0
    jmp postamble_set_rv_uint8_b0

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
    jmp panic_type

_bint_passthrough:
    jmp postamble_arg0_rv

_bint_from_bool:
    jsr arg0_w0_deref
    ldy #0
    lda (W2),y
    sta B0
    jmp postamble_set_rv_int_b0

_bint_from_float:
    jsr arg0_w0_push
    jsr float_to_int                 // consumes pushed arg, RV = INT
    jmp postamble

_bint_from_str:
    jsr arg0_w0_deref               // W2 = payload, A = len
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
    jmp panic_type

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
    jmp panic_type

_bflt_passthrough:
    jmp postamble_arg0_rv

_bflt_from_int:
    jsr arg0_w0_push
    jsr int_to_float
    jmp postamble

_bflt_from_str:
    jsr arg0_w0_push
    jsr str_to_float
    jmp postamble

// =============================================================================
// builtin_exp / builtin_log / builtin_sqrt / builtin_sin / builtin_cos /
// builtin_tan / builtin_atan — INT / BOOL / FLOAT → TYPE_FLOAT.
//
// All seven funnel through one body (`_b_trig_body`) that handles the entire
// arc: preamble, coerce-to-float, unpack into FAC1, bank in BASIC + KERNAL,
// JSR into a *self-modified* ROM target, bank out, alloc + pack, postamble.
// Each user-facing entry is a 5-byte stub that loads its index 0..6 into A
// and jumps to `_b_trig_dispatch`, which patches the JSR target from a
// 7-entry lo/hi table.
//
// Domain errors (LOG(x<=0), SQR(x<0), TAN at π/2 + nπ, EXP overflow) trip
// BASIC's own error vector — same exposure `**` already has via FPWRT.
// =============================================================================
builtin_exp:  lda #0
              jmp _b_trig_dispatch
builtin_log:  lda #1
              jmp _b_trig_dispatch
builtin_sqrt: lda #2
              jmp _b_trig_dispatch
builtin_sin:  lda #3
              jmp _b_trig_dispatch
builtin_cos:  lda #4
              jmp _b_trig_dispatch
builtin_tan:  lda #5
              jmp _b_trig_dispatch
builtin_atan: lda #6
              // fall through

// Patch `_fp_basic_target` AFTER coerce, not before — int_to_float (called
// by the INT-coerce path) internally invokes basic_op(GIVAYF / FADDT / ...),
// which rewrites the target. Patching first would lose our ROM address.
// HW-stack PHA/PLA survives preamble_call_1_1_w0 + the coerce subroutine
// because preamble's own PHAs are balanced 1:1 with PLAs.
_b_trig_dispatch:
    pha                              // save index 0..6 across coerce
    jsr preamble_call_1_1_w0
    jsr _coerce_arg0_to_rs_float
    pla
    tax
    lda _b_trig_lo,x
    sta _fp_basic_target+1
    lda _b_trig_hi,x
    sta _fp_basic_target+2

    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    jsr _fp_unpack_to_fac1

    jsr _fp_basic_envelope

    jsr _fp_alloc_and_pack
    jmp postamble

_b_trig_lo:
    .byte <BASIC_EXP, <BASIC_LOG, <BASIC_SQR, <BASIC_SIN, <BASIC_COS, <BASIC_TAN, <BASIC_ATN
_b_trig_hi:
    .byte >BASIC_EXP, >BASIC_LOG, >BASIC_SQR, >BASIC_SIN, >BASIC_COS, >BASIC_TAN, >BASIC_ATN

// _coerce_arg0_to_rs_float — after preamble_call_1_1_w0, W0 = arg-0 handle.
// Pushes a TYPE_FLOAT equivalent onto RS:
//   FLOAT      → push the original handle.
//   INT / BOOL → int_to_float (BOOL's 1-byte payload reads as a tiny int).
//   anything else → panic_type. `float(s)` is the explicit STR path.
_coerce_arg0_to_rs_float:
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_FLOAT
    beq _c2f_float
    cmp #TYPE_INT
    beq _c2f_int
    cmp #TYPE_BOOL
    beq _c2f_int
    jmp panic_type
_c2f_int:
    jsr arg0_w0_push
    jsr int_to_float
    jmp rs_push_rv                   // tail
_c2f_float:
    jmp arg0_w0_push                 // tail

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
    cmp #TYPE_NAME
    bne !next+
    // Names share TYPE_STR's payload layout; treat as a string.
    // print/repr of `globals()` keys land here.
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
    cmp #TYPE_CODE
    bne !next+
    // TYPE_CODE renders as the fixed string "<code>". Used by print_value too
    // (via _str_w0) so REPL auto-print of a code blob shows the same thing.
    lda #<STR_CODE
    ldx #>STR_CODE
    jmp postamble_set_rv_ax
!next:
    jmp _bstr_type_err
_bstr_type_err:
    jmp panic_type

_bstr_passthrough:
    jmp postamble_arg0_rv
_bstr_int:
    jsr arg0_w0_push
    jsr int_to_str                   // consumes pushed arg, RV = STR
    jmp postamble
_bstr_float:
    jsr arg0_w0_push
    jsr float_to_str
    jmp postamble
_bstr_bool:
    jsr arg0_w0_deref
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
//
// Cycle detection: each container path toggles bit 7 of its H_TYPE byte on
// entry. If the bit was already set (i.e., XOR brings it to 0) we're inside
// a render call already in progress on this same handle — emit the matching
// ellipsis static and skip rendering. Either path falls through to the
// shared finish that toggles the bit back, restoring state for the outer
// call (or leaving it clean at the top level). Same trick as DCPU's
// TYPE_EXTENSION-bit toggle in dict_repr.
// Common entry for the three container str()-paths. Loads W0 from arg 0,
// XOR-toggles FLAG_RENDERING, and returns with A = post-AND result so the
// caller's beq routes recursion (FLAG was set → A=0 → Z=1) vs render
// (FLAG was clear → A=FLAG_RENDERING → Z=0). Caller is responsible for
// pushing the container handle (lo/hi) on the HW stack for
// _bstr_container_finish; ferry Z across the PHAs via tay/tya.
_bstr_seq_setup:
    arg_get(0, W0)
    ldy #H_FLAGS
    lda (W0),y
    eor #FLAG_RENDERING
    sta (W0),y
    and #FLAG_RENDERING
    rts

_bstr_list:
    jsr _bstr_seq_setup
    tay
    lda W0+1
    pha
    lda W0
    pha
    tya
    beq _bstr_list_recursion
    rs_push(W0)
    rs_push_const(STR_LBRACK)
    rs_push_const(STR_RBRACK)
    jsr _bstr_render_seq
    jmp _bstr_container_finish
_bstr_list_recursion:
    lda #<STR_LIST_ELLIPSIS
    sta RV
    lda #>STR_LIST_ELLIPSIS
    sta RV+1
    jmp _bstr_container_finish

_bstr_tuple:
    jsr _bstr_seq_setup
    tay
    lda W0+1
    pha
    lda W0
    pha
    tya
    beq _bstr_tuple_recursion
    rs_push(W0)
    rs_push_const(STR_LPAREN)
    rs_push_const(STR_RPAREN)
    jsr _bstr_render_seq
    jmp _bstr_container_finish
_bstr_tuple_recursion:
    lda #<STR_TUPLE_ELLIPSIS
    sta RV
    lda #>STR_TUPLE_ELLIPSIS
    sta RV+1
    jmp _bstr_container_finish

_bstr_dict:
    jsr _bstr_seq_setup
    tay
    lda W0+1
    pha
    lda W0
    pha
    tya
    beq _bstr_dict_recursion
    rs_push(W0)
    jsr _bstr_render_dict
    jmp _bstr_container_finish
_bstr_dict_recursion:
    lda #<STR_DICT_ELLIPSIS
    sta RV
    lda #>STR_DICT_ELLIPSIS
    sta RV+1
    // fall through

_bstr_container_finish:
    // Restore container handle from HW stack, toggle FLAG_RENDERING back.
    pla
    sta W0
    pla
    sta W0+1
    ldy #H_FLAGS
    lda (W0),y
    eor #FLAG_RENDERING
    sta (W0),y
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

    // Container length word → B0:B1.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2                // A:X = O_LEN word
    sta B0
    stx B1

    // Index word B2:B3 = 0.
    lda #0
    sta B2
    sta B3

_brs_loop:
    // Loop while i < N (16-bit unsigned).
    lda B2
    cmp B0
    lda B3
    sbc B1
    bcc !go+
    jmp _brs_close
!go:

    // Fetch container[B2:B3] handle → W3.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2                // W2 = payload base
    // W2 += 2*(B2:B3)
    lda B2
    asl
    sta W3
    lda B3
    rol
    sta W3+1
    clc
    lda W3
    adc W2
    sta W2
    lda W3+1
    adc W2+1
    sta W2+1
    ldy #0
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

    // If i+1 < N, append ", ".
    clc
    lda B2
    adc #1
    sta B4
    lda B3
    adc #0
    sta B5
    lda B4
    cmp B0
    lda B5
    sbc B1
    bcs _brs_no_sep                   // i+1 >= N → no separator
    rs_peek(W3)
    rs_push(W3)
    rs_push_const(STR_COMMA_SPACE)
    jsr array_merge
    rs_pop(W3)
    rs_push(RV)
_brs_no_sep:
    inc B2
    bne !+
    inc B3
!:
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

    // Length word → B6:B7.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2                // A:X = O_LEN word
    sta B6
    stx B7

    // Index word → B4:B5 = 0.
    lda #0
    sta B4
    sta B5

_brd_loop:
    // Loop while i < N (16-bit unsigned).
    lda B4
    cmp B6
    lda B5
    sbc B7
    bcc !go+
    jmp _brd_close
!go:

    // Fetch dict.payload[B4:B5] = entry tuple handle → W3.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    // W2 += 2*(B4:B5)
    lda B4
    asl
    sta W3
    lda B5
    rol
    sta W3+1
    clc
    lda W3
    adc W2
    sta W2
    lda W3+1
    adc W2+1
    sta W2+1
    ldy #0
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

    // If i+1 < N, append ", ".
    clc
    lda B4
    adc #1
    sta B0
    lda B5
    adc #0
    sta B1                            // B0:B1 = i+1
    lda B0
    cmp B6
    lda B1
    sbc B7
    bcs _brd_no_sep                   // i+1 >= N → no separator
    rs_peek(W3)
    rs_push(W3)
    rs_push_const(STR_COMMA_SPACE)
    jsr array_merge
    rs_pop(W3)
    rs_push(RV)
_brd_no_sep:
    inc B4
    bne !+
    inc B5
!:
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
    jmp panic_type

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

    // rnd(end) INT: rand31 % end.
    jsr _brnd_alloc_rand              // RV = non-negative 31-bit rand
    rs_push(RV)                       // RS: [args, rand]
    // Re-deref the args tuple into W3 — _brnd_alloc_rand's alloc clobbered it.
    rs_peek_at(W0, 1)                 // W0 = args tuple
    jsr deref_W0_to_W2
    lda W2
    sta W3
    lda W2+1
    sta W3+1
    jsr arg0_w0_push                       // RS: [args, rand, end]
    jsr int_mod                       // RV = rand % end
    jmp postamble

_brnd_one_float:
    // rnd(end) FLOAT: result = float_random() * end.
    jsr float_random
    rs_push(RV)                       // RS: [args, frnd]
    jsr arg0_w0_push                       // RS: [args, frnd, end]
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

    // Allocate a non-negative 31-bit rand.
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

// Leaf helper: build a non-negative 31-bit random inline INT.
//   out: RV = new INT handle (0 .. 2^31-1).
//   clobbers: A, X, Y, B0..B3, W2/W3. (rand8 preserves X/Y/ZP.)
_brnd_alloc_rand:
    jsr rand8
    sta B0
    jsr rand8
    sta B1
    jsr rand8
    sta B2
    jsr rand8
    and #$7F                          // clear bit 31 → non-negative
    sta B3
    jmp alloc_int_b0                  // tail: RV = inline int, returns to caller

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
    lda W0                       // 16-bit handle address → inline int (hi16 = 0)
    sta W2
    lda W0+1
    sta W2+1
    lda #0
    sta W3
    sta W3+1
    jmp postamble_set_rv_int32

// =============================================================================
// builtin_globals() / builtin_locals() — return a scope dict.
//   globals() = ROOT_SCOPE (program-level, set once at parser_eval start)
//   locals()  = CURRENT_SCOPE (current; differs from ROOT_SCOPE only inside a
//              string-call lambda where led_lparen swaps to a per-call scope)
//
// Mirrors Admiral's `built_in_globals` / `built_in_locals`
// (builtin.dasm16:260, 251).
//
// Body shared via the classic `.byte $2C` BIT-abs trick: globals's `ldx #0`
// falls into the BIT prefix, which then eats locals's `ldx #$FE` (= -2) as
// its operand. Both entry points end up at the shared `lda ROOT_SCOPE,x`
// where the indexed ZP read targets either ROOT_SCOPE ($44) when X=0 or
// CURRENT_SCOPE ($42) when X=$FE (lda zp,x wraps within $00-$FF). RV and
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
    ldx #$FE                     // -2: shifts ZP base from ROOT_SCOPE to CURRENT_SCOPE
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
    sta W2
    lda NEXT_HANDLE+1
    sbc NEXT_DATA+1
    sta W2+1
    lda #0                       // free count is 16-bit non-negative → hi16 = 0
    sta W3
    sta W3+1
    jmp postamble_set_rv_int32

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
    jmp postamble_set_rv_int_b0        // signed byte → inline int (-1/0/1)

// =============================================================================
// builtin_hex(x) — render INT/BOOL as a hex string. Format: "0xDD…" for
// non-negative values, "-0xDD…" for negatives. Two hex chars per significant
// magnitude byte (leading all-zero bytes trimmed; minimum one byte → "0x00").
// =============================================================================
builtin_hex:
    jsr preamble_call_1_1_w0

    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq _bhex_int
    cmp #TYPE_BOOL
    beq _bhex_bool
    jmp panic_type
_bhex_bool:
    // Boxed BOOL: value = payload byte (0/1) into B0..B3.
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    sta B0
    lda #0
    sta B1
    sta B2
    sta B3
    jmp _bhex_value
_bhex_int:
    jsr int_load_a                      // B0..B3 = value
_bhex_value:
    // Sign → B6; magnitude into B0..B3.
    lda B3
    bpl _bhex_pos
    lda #$FF
    sta B6
    sec
    lda #0
    sbc B0
    sta B0
    lda #0
    sbc B1
    sta B1
    lda #0
    sbc B2
    sta B2
    lda #0
    sbc B3
    sta B3
    jmp _bhex_sig
_bhex_pos:
    lda #0
    sta B6
_bhex_sig:
    // Highest non-zero byte index → B7 (sig_len = B7 + 1; minimum 1).
    ldx #3
_bhex_findsig:
    lda B0,x
    bne _bhex_found
    dex
    bne _bhex_findsig
_bhex_found:
    stx B7

    // ALLOC_SIZE = (2 or 3 for "0x"/"-0x") + 2*(B7+1).
    txa
    clc
    adc #1
    asl                                  // 2 * sig_len
    sta B5
    lda B6
    bpl _bhex_plen
    lda #3
    jmp _bhex_dlen
_bhex_plen:
    lda #2
_bhex_dlen:
    clc
    adc B5
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                           // RV = new STR (B regs preserved — V4')
    jsr deref_RV_to_W3                  // W3 = dst payload base

    ldy #0
    lda B6
    bpl _bhex_no_minus
    lda #$2D                            // '-'
    sta (W3),y
    iny
_bhex_no_minus:
    lda #$30                            // '0'
    sta (W3),y
    iny
    lda #$78                            // 'x'
    sta (W3),y
    iny

    // Emit magnitude bytes from B7 (MSB) down to 0. X = byte index, Y = output
    // offset (carried across _bhex_emit_digit, which only iny's and clobbers A).
    ldx B7
_bhex_byte_loop:
    lda B0,x
    pha
    lsr
    lsr
    lsr
    lsr
    jsr _bhex_emit_digit
    pla
    and #$0F
    jsr _bhex_emit_digit
    dex
    bpl _bhex_byte_loop
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
// screen_put_char. Color RAM is left untouched — call MC.COLOR or POKE
// $D800+ explicitly to change a cell's color.
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
// builtin_peek(addr) / builtin_poke(addr, val) — shared body. The two TYPE_BUILTIN
// entry points pre-load X = arity (1 / 2), then strict-arity preamble_call(N, N)
// caches it in B7 — that becomes the read-vs-write switch in the body.
//
// addr: TYPE_INT — payload[0] = addr lo, payload[1] = addr hi when O_LEN >= 2,
//   else 0. No type-check.
// val (poke only): TYPE_INT — payload[0] = byte value; high bytes ignored.
//
// MEM_IO ($35) is banked across the byte access so VIC/SID/CIA registers are
// reachable. peek returns TYPE_INT 0..255 (1-byte if <128, 2-byte if >=128).
// poke returns NONE.
// =============================================================================
builtin_peek:
    ldx #1
    .byte $2C                           // BIT abs — eats `ldx #2`
builtin_poke:
    ldx #2
    txa
    tay                                 // X = Y = arity for strict preamble_call
    jsr _preamble_call                  // B7 = argc (1 = peek, 2 = poke)

    // Address from inline-int handle bytes: H_PTR (offsets 0,1) holds the
    // low 16 bits of the value. Going through deref_W0_to_W2 would chase
    // H_PTR as if it were a heap pointer and read garbage at that address,
    // so we read the address bytes directly here.
    arg_get(0, W0)
    ldy #0
    lda (W0),y
    sta W1
    iny
    lda (W0),y
    sta W1+1

    dec B7                              // 1 (peek) → 0; 2 (poke) → 1
    bne _bpkp_poke

    // peek path — bank MEM_IO only across the user-addr read; heap can lie
    // under BASIC ROM ($A000-$BFFF) so heap accesses must stay in MEM_NORMAL.
    ldx $01
    ldy #MEM_IO
    sty $01
    ldy #0
    lda (W1),y
    sta B0
    stx $01
    jmp postamble_set_rv_uint8_b0

_bpkp_poke:
    arg_get(1, W0)
    ldy #0
    lda (W0),y                          // inline int: low byte = value
    ldx $01
    ldy #MEM_IO
    sty $01
    ldy #0
    sta (W1),y
    stx $01
    jmp postamble_return_none

// =============================================================================
// builtin_code(s) — clone a TYPE_STR's payload into a new TYPE_CODE handle.
// The returned value is callable as `code(arg1, ..., arg5)` — `f(args)`
// dispatches to a JSR into the byte payload when f is TYPE_CODE, with W0 set
// to the code's own load address and arg handles in W1/W2/W3/B0:B1/B2:B3.
// Use this around hand-written `\xNN` literals or any STR you want to mark as
// machine code. asm.admiral's A.GO() also returns TYPE_CODE.
// =============================================================================
builtin_code:
    jsr preamble_call_1_1_w0
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq !+
    jmp _bcode_panic
!:

    // Unified TYPE_CODE framing: every payload is a v2 plugin image.
    //   +0 jsr SYS_RELOC   +3 linked_base   +5 fixups_off (= len+7)
    //   +7 the caller's bytes (position-independent by contract)
    //   +7+len  .word 0  (empty fixup table)
    // Size = len + 9.
    jsr arg0_w0_deref                   // A:X = src O_LEN
    sta B0
    stx B1                              // B0:B1 = len
    clc
    adc #9
    sta ALLOC_SIZE
    txa
    adc #0
    sta ALLOC_SIZE+1
    jsr str_alloc                       // RV = new object (rooted below)
    rs_push(RV)                         // RS: [args, code]
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    ldy #H_TYPE
    lda #TYPE_CODE
    sta (W0),y                          // retag in place
    jsr deref_W0_to_W2                  // W2 = dest payload (data start)

    // Header. linked_base = W2: the dispatcher derefs the handle and calls
    // the data start, so "where the code lives right now" IS W2.
    ldy #0
    lda #$20                            // JSR opcode
    sta (W2),y
    iny
    lda #<SYS_RELOC
    sta (W2),y
    iny
    lda #>SYS_RELOC
    sta (W2),y
    iny
    lda W2
    sta (W2),y                          // +3 linked_base lo
    iny
    lda W2+1
    sta (W2),y                          // +4 linked_base hi
    iny
    clc
    lda B0
    adc #7
    sta (W2),y                          // +5 fixups_off lo (= len+7)
    iny
    lda B1
    adc #0
    sta (W2),y                          // +6 fixups_off hi

    // Copy the source bytes to dest+7. Re-deref the source AFTER the alloc
    // (GC may have moved it). B4:B5 = dest walker, B0:B1 = remaining.
    clc
    lda W2
    adc #7
    sta B4
    lda W2+1
    adc #0
    sta B5
    arg_get(0, W0)
    jsr deref_W0_to_W2                  // W2 = src payload
_bcode_copy:
    lda B0
    ora B1
    beq _bcode_trailer
    ldy #0
    lda (W2),y
    sta (B4),y
    inc W2
    bne !+
    inc W2+1
!:
    inc B4
    bne !+
    inc B5
!:
    lda B0
    bne !+
    dec B1
!:
    dec B0
    jmp _bcode_copy

_bcode_trailer:
    ldy #0
    tya
    sta (B4),y                          // nfix = 0
    iny
    sta (B4),y
    jmp postamble_pop_rv                // RV = the new TYPE_CODE
_bcode_panic:
    jmp panic_type

// =============================================================================
// builtin_bitmap(on) — warm-restart Admiral into a heap config that does
// (or doesn't) reserve VIC bitmap memory.
//   falsy  → text-only / full-heap (handle ceiling $FFF8).
//   truthy → bitmap-capable: reserve $DC00-$FFFF for the screen RAM +
//            hi-res / multicolor bitmap (handle ceiling $DC00).
// Sets GFX_CONFIG, then JMPs to boot — NEVER returns (re-enters the REPL).
// boot resets the HW stack + RS/FS and re-snapshots the recovery state. The
// workspace is wiped (it's a restart) — programs/data persist on disk.
// (Named for the VIC's bitmap mode the reservation enables; this function
// only sets up the memory map — the actual VIC mode flip happens later via
// HIRES.SHOW() / MC.SHOW() / TEXT.SHOW() in user-space extensions.)
// =============================================================================
builtin_bitmap:
    jsr preamble_call_1_1_w0     // W0 = arg0 handle
    jsr val_truthy               // A = 0 (falsy) / 1 (truthy); leaf, no GC
    sta GFX_CONFIG
    jmp boot                     // never returns

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
    jmp panic_arity

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

    jmp postamble_peek_rv        // RV = tuple


// _bcur_alloc_int_b0 — allocate a 1-byte INT containing B0.
//   in:  B0 = value (0..255)
//   out: RV = new TYPE_INT handle.
//   clobbers: A, X, Y, W2.
_bcur_alloc_int_b0:
    lda B0                       // 0..255 → inline int (hi24 = 0)
    sta W2
    lda #0
    sta W2+1
    sta W3
    sta W3+1
    jmp alloc_inline_int         // tail call: sets RV, returns to our caller


// =============================================================================
// builtin_format() — re-initialize the disk in drive 8 with name "ADMIRAL",
// id "01". Wipes all files. Returns None.
//   Raises ERR_DISK if the 1541 reports a non-zero status code.
// =============================================================================
builtin_format:
    preamble_call(0, 0)

    lda #<DOS_CMD_FORMAT
    sta W0
    lda #>DOS_CMD_FORMAT
    sta W0+1
    lda #DOS_CMD_FORMAT_LEN
    sta B0
    jsr disk_dos_cmd_check            // A = DOS status code
    cmp #20                           // codes 00-19 are informational (CBM
    bcs _bfmt_panic                   // convention); ≥20 is a real error
    jmp postamble_return_none
_bfmt_panic:
    jmp panic_disk


// =============================================================================
// builtin_load(name) — read the file `name` and reconstruct the object graph.
// Returns the root handle (the first record of the stream).
//   name : TYPE_STR, 1..12 chars (PETSCII).
//   Raises ERR_TYPE for bad name; ERR_DISK if the read fails.
// =============================================================================
builtin_load:
    jsr preamble_call_1_1_w0          // W0 = name handle
    inc PAUSE_BLOCKED                 // suppress NMI banner during disk op
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    bne _bld_type_err
    jsr deref_W0_to_W2                // W2 = name bytes, A = length
    sta B0
    beq _bld_type_err
    cmp #13
    bcs _bld_type_err

    lda W2
    sta W0
    lda W2+1
    sta W0+1                          // W0 = name ptr
    jsr disk_open_seq_r               // CHKIN lfn 2

    jsr disk_deserialize              // RV = root handle; bails on early EOF

    rs_push(RV)                       // root via RS so close+status are safe

    jsr disk_close_data
    jsr disk_status_check             // A = DOS code
    cmp #20
    bcs _bld_disk_err

    rs_pop(W0)
    lda W0
    sta RV
    lda W0+1
    sta RV+1
    dec PAUSE_BLOCKED                 // happy-path balance
    jmp postamble

_bld_type_err:
    jmp panic_type
_bld_disk_err:
    jmp panic_disk


// =============================================================================
// builtin_save(name, obj) — serialize `obj` (and everything reachable from it)
// to disk under `name`. Returns None.
//   name : TYPE_STR, 1..12 chars (PETSCII).
//   obj  : any value; container subtypes are walked recursively.
//   Existing files with this name are silently overwritten (DOS @0:NAME,S,W).
//
//   Raises ERR_TYPE for non-string name, oversized/empty name.
//   Raises ERR_DISK if the 1541 reports a non-zero post-write status (write
//     protect, disk full, etc.).
// =============================================================================
builtin_save:
    jsr preamble_call_2_2_w0_w1       // W0 = name, W1 = obj
    inc PAUSE_BLOCKED                 // suppress NMI banner during disk op
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    bne _bsv_type_err
    rs_push(W1)                       // root the obj across the open call
    jsr deref_W0_to_W2                // W2 = name bytes, A = length
    sta B0                            // B0 = name length
    beq _bsv_type_err
    cmp #13
    bcs _bsv_type_err

    // Open SEQ-write channel for "name".
    lda W2
    sta W0
    lda W2+1
    sta W0+1                          // W0 = name ptr
    jsr disk_open_seq_w               // CHKOUT lfn 2

    // Serialize obj. Re-fetch from RS to refresh through any GC since rs_push.
    rs_peek(W0)                       // W0 = obj
    jsr disk_serialize_w0

    jsr disk_close_data
    jsr disk_status_check             // A = DOS error code (00 OK, 01 info, ...)
    cmp #20
    bcs _bsv_disk_err

    rs_pop(W0)                        // discard obj root
    dec PAUSE_BLOCKED                 // happy-path balance; panic paths reset via error_handler
    jmp postamble_return_none

_bsv_type_err:
    jmp panic_type
_bsv_disk_err:
    jmp panic_disk


// =============================================================================
// builtin_rm(name) — delete a file by name. Returns None.
//   name : TYPE_STR, 1..12 chars (PETSCII).
//   Raises ERR_TYPE for non-string args, oversized names, or empty names.
//   Raises ERR_DISK if the DOS scratch fails (file not found, write-protect,
//     etc.).
//
// Builds "S:NAME" in disk_filename_buf and dispatches via the cmd channel.
// =============================================================================
builtin_rm:
    jsr preamble_call_1_1_w0          // W0 = filename handle
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    bne _brm_type_err
    jsr deref_W0_to_W2                // W2 = name bytes, A = length
    sta B0                            // B0 = name length
    beq _brm_type_err                 // empty name
    cmp #13
    bcs _brm_type_err                 // length > 12 → reject

    // Build "S:" prefix into disk_filename_buf, then copy name bytes.
    lda #$53                          // 'S'
    sta disk_filename_buf
    lda #$3A                          // ':'
    sta disk_filename_buf + 1
    ldy #0
_brm_copy:
    cpy B0
    beq _brm_copy_done
    lda (W2),y
    sta disk_filename_buf + 2,y
    iny
    bne _brm_copy
_brm_copy_done:

    lda #<disk_filename_buf
    sta W0
    lda #>disk_filename_buf
    sta W0+1
    lda B0
    clc
    adc #2                            // 2-byte "S:" prefix
    sta B0

    jsr disk_dos_cmd_check
    cmp #20                           // 01,FILES SCRATCHED is informational
    bcs _brm_disk_err
    jmp postamble_return_none

_brm_type_err:
    jmp panic_type

_brm_disk_err:
    jmp panic_disk


// =============================================================================
// builtin_dir() — read directory and return { TYPE_STR name : TYPE_INT blocks }.
//   Empty disk → empty dict. Header line and "BLOCKS FREE." footer are skipped.
//   Raises ERR_DISK if the post-read status is non-zero.
// =============================================================================
builtin_dir:
    preamble_call(0, 0)

    jsr disk_dir                       // RV = dict

    rs_push(RV)                        // root across close + status

    jsr disk_close_data
    jsr disk_status_check              // A = DOS code
    cmp #20
    bcs _bdir_disk_err

    rs_pop(W0)
    lda W0
    sta RV
    lda W0+1
    sta RV+1
    jmp postamble

_bdir_disk_err:
    jmp panic_disk


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
    jmp panic_type
_bin_print_prompt:
    jsr arg0_w0_push
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

    // Append (if room). Storage is PETSCII uppercase ($41-$5A), which is
    // exactly what KERNAL_GETIN returns from the keyboard — no fold needed.
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

    jmp postamble_peek_rv


// =============================================================================
// Method-style builtins. Receiver is tuple slot 0 — `led_dot` stages
// METHOD_RECEIVER which `led_lparen` prepends to the args tuple as element 0
// before calling. For an N-arg method like obj.m(a, b), the args tuple is
// (obj, a, b) and the impl reads obj via `arg_get(0, ...)`.
// =============================================================================

// --- str.upper() — return a new TYPE_STR with ASCII letters folded UP -------
//   in:  args = (me,)   me: TYPE_STR
// =============================================================================
// upper and lower share one body via SMC trampoline.
builtin_str_upper:
    lda #$61                          // 'a'
    .byte $2C
builtin_str_lower:
    lda #$41                          // 'A'
    sta _bs_case_lo+1
    clc
    adc #26
    sta _bs_case_hi+1
    jsr preamble_call_1_1_w0
    rs_push(W0)
    jsr deref_W0_to_W2
    sta B0
    stx B1

    lda B0
    sta ALLOC_SIZE
    lda B1
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc

    rs_peek(W0)
    jsr deref_W0_to_W3
    jsr deref_RV_to_W2

_bs_case_loop:
    lda B0
    ora B1
    beq _bs_case_done
    ldy #0
    lda (W3),y
_bs_case_lo:
    cmp #$00                          // SMC: 'a' or 'A'
    bcc _bs_case_store
_bs_case_hi:
    cmp #$00                          // SMC: 'z'+1 or 'Z'+1
    bcs _bs_case_store
    eor #$20
_bs_case_store:
    sta (W2),y
    inc W3
    bne !+
    inc W3+1
!:
    inc W2
    bne !+
    inc W2+1
!:
    lda B0
    bne !+
    dec B1
!:
    dec B0
    jmp _bs_case_loop
_bs_case_done:
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
    jsr arg0_w0_deref                // A:X = me_len word
    sta B0
    stx B1                            // B0:B1 = me_len

    // Default range: full string. start=0:0; end_excl=$FFFF (sentinel).
    lda #0
    sta B4
    sta B5
    lda #$FF
    sta B6
    sta B7

    // Read args count from preamble's cached B7 — but we just clobbered B7
    // setting end_excl. Re-fetch from the args tuple to know how many args.
    rs_peek(W0)                       // args_tuple
    jsr deref_W0_to_W2                // A = args tuple element count (low byte; max ≤ 4)
    pha                               // save count
    cmp #3
    bcc _bfind_args_done_pop

    // Read start (arg index 2) — int payload, signed → 16-bit B4:B5.
    arg_get(2, W0)
    jsr _bfind_read_signed_int        // A:X = signed-extended int
    sta B4
    stx B5
    cpx #0                            // re-establish N flag (helper clobbered it)
    bpl _bfind_start_set              // non-negative → use as-is
    // negative → += me_len
    clc
    lda B4
    adc B0
    sta B4
    lda B5
    adc B1
    sta B5
    bpl _bfind_start_set              // (raw + me_len) >= 0 → ok
    // far-negative: clamp to 0.
    lda #0
    sta B4
    sta B5
_bfind_start_set:

    pla
    pha                               // restore arg count, keep saved
    cmp #4
    bcc _bfind_args_done_pop

    // Read end (arg index 3).
    arg_get(3, W0)
    jsr _bfind_read_signed_int
    sta B6
    stx B7
    cpx #0                            // re-establish N flag (helper clobbered it)
    bpl _bfind_end_set
    clc
    lda B6
    adc B0
    sta B6
    lda B7
    adc B1
    sta B7
    bpl _bfind_end_set
    lda #0
    sta B6
    sta B7
_bfind_end_set:

_bfind_args_done_pop:
    pla                               // discard saved count

    // Push needle, haystack on RS for str_find_pos.
    arg_get(0, W0)
    arg_get(1, W1)
    rs_push(W1)                       // sub deeper
    rs_push(W0)                       // me top
    jsr str_find_pos                  // RV = pos word or $FFFF
    lda RV
    sta B0
    lda RV+1
    sta B1

    // If RV == $FFFF → return -1.
    cmp #$FF
    bne _bfind_alloc
    lda B0
    cmp #$FF
    bne _bfind_alloc
    // Not found → -1 (all $FF).
    lda #$FF
    sta W2
    sta W2+1
    sta W3
    sta W3+1
    jmp postamble_set_rv_int32
_bfind_alloc:
    // Found (0..0xFFFE) → inline int (16-bit position, hi16 = 0).
    lda B0
    sta W2
    lda B1
    sta W2+1
    lda #0
    sta W3
    sta W3+1
    jmp postamble_set_rv_int32

// Helper: read signed int handle in W0 → A:X = sign-extended 16-bit value.
// 1-byte int → sign-extend low byte. 2-byte int → take both bytes verbatim.
// Bytes past index 1 are ignored.
//   in:  W0 = INT handle (O_LEN ≥ 1).
//   out: A = low, X = high.
//   clobbers: W2, Y, B2.
_bfind_read_signed_int:
    // Inline int: low 16 bits are handle bytes 0 (lo) and 1 (hi).
    ldy #0
    lda (W0),y
    pha
    iny
    lda (W0),y
    tax
    pla
    rts

// --- str.startswith(prefix) -------------------------------------------------
//   in:  args = (me, prefix)
// =============================================================================
builtin_str_startswith:
    jsr preamble_call_2_2_w0_w1
    // Cache both args before clobbering W3 (which arg_get reads from).
    jsr deref_W1_to_W3                // W3 = prefix payload, A:X = prefix_len word
    sta B0
    stx B1                            // B0:B1 = prefix len
    jsr deref_W0_to_W2                // W2 = me payload, A:X = me_len word
    sta B2
    stx B3                            // B2:B3 = me len

    // If prefix_len > me_len, not a prefix (16-bit unsigned compare).
    lda B2
    cmp B0
    lda B3
    sbc B1
    bcc _bsw_false                    // me_len < prefix_len

    // Empty prefix → always matches.
    lda B0
    ora B1
    beq _bsw_true

    // Walk B0:B1 bytes of W2 vs W3 from the start.
_bsw_loop:
    lda B0
    ora B1
    beq _bsw_true
    ldy #0
    lda (W2),y
    cmp (W3),y
    bne _bsw_false
    inc W2
    bne !+
    inc W2+1
!:
    inc W3
    bne !+
    inc W3+1
!:
    lda B0
    bne !+
    dec B1
!:
    dec B0
    jmp _bsw_loop
_bsw_true:
    jmp postamble_return_true
_bsw_false:
    jmp postamble_return_false

// --- str.endswith(suffix) ---------------------------------------------------
// Shares compare loop with startswith.
// =============================================================================
builtin_str_endswith:
    jsr preamble_call_2_2_w0_w1
    jsr deref_W1_to_W3
    sta B0
    stx B1
    jsr deref_W0_to_W2
    sta B2
    stx B3

    lda B2
    cmp B0
    lda B3
    sbc B1
    bcc _bsw_false

    sec
    lda B2
    sbc B0
    sta B4
    lda B3
    sbc B1
    sta B5
    clc
    lda W2
    adc B4
    sta W2
    lda W2+1
    adc B5
    sta W2+1
    jmp _bsw_loop

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

    jsr arg0_w0_push                       // RS: [tuple, me]

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
    jsr deref_W0_to_W2                // W2=me payload, A:X = me_len word
    sta B0
    stx B1
    jsr deref_W1_to_W3                // W3=sep payload, A:X = sep_len word
    cpx #0
    beq _bsp_sep_ok                   // sep < 256 — required (sep is short)
    jmp panic_type
_bsp_sep_ok:
    tax                               // refresh N/Z from A (cpx above set Z=1)
    sta B2                            // B2 = sep_len byte
    bne !ok+
    jmp panic_type
!ok:

    // Allocate empty list (capacity 0). _array_alloc_init clobbers B0,
    // so re-load me_len/sep_len after.
    lda #0
    ldx #TYPE_LIST
    jsr _array_alloc_init             // RV = list
    rs_push(RV)                       // RS: [args_tuple, me, sep, list]

    rs_peek_at(W0, 2)
    rs_peek_at(W1, 1)
    jsr deref_W0_to_W2                // A:X = me_len word
    sta B0
    stx B1
    jsr deref_W1_to_W3                // A = sep_len low byte (already validated)
    sta B2

    lda #0
    sta B4
    sta B5                            // pos = 0
    sta B6
    sta B7                            // segment_start = 0

_bsp_loop:
    // if pos (B4:B5) >= me_len (B0:B1) → done
    lda B4
    cmp B0
    lda B5
    sbc B1
    bcc !go+
    jmp _bsp_done
!go:
    // remaining = me_len - pos. If remaining < sep_len → can't match here; advance.
    sec
    lda B0
    sbc B4
    sta B3
    lda B1
    sbc B5
    bne _bsp_chk_room                 // (me_len - pos) >= 256 → fits any sep < 256
    lda B3
    cmp B2
    bcc _bsp_adv                      // remaining < sep_len → advance
_bsp_chk_room:
    jsr _bsr_match_at_pos
    cmp #0
    bne !go+
    jmp _bsp_adv
!go:
    // Match — emit me[seg_start..pos] then bump past sep.
    jsr _bsp_emit_segment
    // pos += sep_len (16-bit add)
    clc
    lda B4
    adc B2
    sta B4
    bcc !+
    inc B5
!:
    lda B4
    sta B6
    lda B5
    sta B7
    rs_peek_at(W0, 2)
    rs_peek_at(W1, 1)
    jsr deref_W0_to_W2
    jsr deref_W1_to_W3
    jmp _bsp_loop

_bsp_adv:
    // pos++ (16-bit)
    inc B4
    bne !+
    inc B5
!:
    jmp _bsp_loop

_bsp_done:
    // Emit final segment me[seg_start..me_len]. Set pos := me_len.
    lda B0
    sta B4
    lda B1
    sta B5
    jsr _bsp_emit_segment

    jmp postamble_peek_rv

// Helper: alloc TYPE_STR of (B4:B5)-(B6:B7) bytes, copy me[B6:B7..B4:B5]
// into it, append to list. Caller's RS at entry: [args_tuple, me, sep, list].
// Helper must NOT change that on return.
//
// In:  B4:B5 = end (word), B6:B7 = start (word).
// Preserves: B0, B1, B2 (me_len, sep_len), B4:B5, B6:B7. Clobbers: A, X, Y,
// B3, W0..W3, RV.
_bsp_emit_segment:
    sec
    lda B4
    sbc B6
    sta ALLOC_SIZE
    lda B5
    sbc B7
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc
    rs_push(RV)

    rs_peek(W0)
    jsr deref_W0_to_W2
    lda W2
    sta W3
    lda W2+1
    sta W3+1

    rs_peek_at(W0, 3)
    jsr deref_W0_to_W2
    clc
    lda W2
    adc B6
    sta W2
    lda W2+1
    adc B7
    sta W2+1
_bsp_cp:
    lda ALLOC_SIZE
    ora ALLOC_SIZE+1
    beq _bsp_cpd
    ldy #0
    lda (W2),y
    sta (W3),y
    inc W2
    bne !+
    inc W2+1
!:
    inc W3
    bne !+
    inc W3+1
!:
    lda ALLOC_SIZE
    bne !+
    dec ALLOC_SIZE+1
!:
    dec ALLOC_SIZE
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
    jsr deref_W0_to_W2                // W2 = me payload, A:X = me_len word
    sta B0
    stx B1

    lda #0
    sta B4
    sta B5                            // pos = 0

_bsp_ws_skip:
    // Walk past whitespace until either end-of-string or first segment char.
    lda B4
    cmp B0
    lda B5
    sbc B1
    bcs _bsp_ws_done                  // pos >= me_len → done
    // Byte at me + pos.
    clc
    lda W2
    adc B4
    sta W0
    lda W2+1
    adc B5
    sta W0+1
    ldy #0
    lda (W0),y
    cmp #$20
    beq _bsp_ws_skip_inc
    cmp #$0D
    bne _bsp_ws_seg_start
_bsp_ws_skip_inc:
    inc B4
    bne !+
    inc B5
!:
    jmp _bsp_ws_skip

_bsp_ws_seg_start:
    lda B4
    sta B6
    lda B5
    sta B7                            // segment_start = current pos

_bsp_ws_scan:
    lda B4
    cmp B0
    lda B5
    sbc B1
    bcs _bsp_ws_emit
    clc
    lda W2
    adc B4
    sta W0
    lda W2+1
    adc B5
    sta W0+1
    ldy #0
    lda (W0),y
    cmp #$20
    beq _bsp_ws_emit
    cmp #$0D
    beq _bsp_ws_emit
    inc B4
    bne !+
    inc B5
!:
    jmp _bsp_ws_scan

_bsp_ws_emit:
    jsr _bsp_emit_segment             // appends me[seg_start..pos] to list
    rs_peek_at(W0, 2)                 // re-deref me — emit may have GC'd
    jsr deref_W0_to_W2
    jmp _bsp_ws_skip

_bsp_ws_done:
    jmp postamble_peek_rv             // RV = list (TOS)

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
    jsr arg0_w0_push
    arg_get(1, W0)
    rs_push(W0)
    arg_get(2, W0)
    rs_push(W0)

    // Slot allocation (16-bit lengths only for me/output; old/new must each
    // fit 8 bits since they appear inside a Y-indexed inner loop):
    //   B0:B1 = me_len (word)
    //   B2    = old_len (byte; < 256)
    //   B3    = new_len (byte; < 256)
    //   B4:B5 = src pos (word) — pass 2
    //   B6:B7 = pass 1: match count (word); pass 2: dst pos (word)
    rs_peek_at(W0, 2)
    rs_peek_at(W1, 1)
    jsr deref_W0_to_W2                // A:X = me_len, W2 = me payload
    sta B0
    stx B1
    jsr deref_W1_to_W3                // A:X = old_len, W3 = old payload
    cpx #0
    beq _bsr_old_len_ok
    jmp panic_oom
_bsr_old_len_ok:
    tax                               // refresh N/Z from A (cpx above set Z=1)
    sta B2
    bne !ok+                          // empty old → ERR_TYPE
    jmp panic_type
!ok:
    rs_peek(W0)                       // new
    jsr deref_W0_to_W2                // A:X = new_len, W2 = new payload
    cpx #0
    beq _bsr_new_len_ok
    jmp panic_oom
_bsr_new_len_ok:
    sta B3

    // Re-establish W2=me, W3=old after the new-deref.
    rs_peek_at(W0, 2)
    rs_peek_at(W1, 1)
    jsr deref_W0_to_W2
    jsr deref_W1_to_W3

    // ----- Pass 1: count matches into B6:B7 (word). Walk pos B4:B5. -----
    lda #0
    sta B4
    sta B5
    sta B6
    sta B7
_bsr_p1:
    // remaining = me_len - pos. If remaining < old_len, done.
    sec
    lda B0
    sbc B4
    tax                               // X = remaining low
    lda B1
    sbc B5
    bne _bsr_p1_chk_room              // remaining >= 256 → fits any old < 256
    cpx B2
    bcc _bsr_p1d                      // remaining < old_len → done
_bsr_p1_chk_room:
    jsr _bsr_match_at_pos
    cmp #0
    beq _bsr_p1m
    // Match: count++, pos += old_len.
    inc B6
    bne !+
    inc B7
!:
    clc
    lda B4
    adc B2
    sta B4
    bcc !+
    inc B5
!:
    jmp _bsr_p1
_bsr_p1m:
    inc B4
    bne !+
    inc B5
!:
    jmp _bsr_p1
_bsr_p1d:

    // Compute output_len = me_len + count*(new_len - old_len) into W0:W0+1
    // (16-bit signed). count = B6:B7. Walking by repeated add, with a
    // signed delta of (new_len - old_len) — sign-extended to 16-bit.
    lda B0
    sta W0
    lda B1
    sta W0+1
    // count == 0 → shortcut.
    lda B6
    ora B7
    bne !go+
    jmp _bsr_alloc
!go:
    // Each iteration adds (new - old) signed. Compute delta in W1.
    sec
    lda B3
    sbc B2
    sta W1                            // delta low
    lda #0
    bcs !pos+
    lda #$FF
!pos:
    sta W1+1                          // delta high (sign-extended)
_bsr_olax:
    clc
    lda W0
    adc W1
    sta W0
    lda W0+1
    adc W1+1
    sta W0+1
    // count-- (16-bit)
    lda B6
    bne !+
    dec B7
!:
    dec B6
    lda B6
    ora B7
    bne _bsr_olax

_bsr_alloc:
    lda W0
    sta ALLOC_SIZE
    lda W0+1
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                         // RV = new str
    rs_push(RV)                       // RS: [me, old, new, out]

    // ----- Pass 2: build output. No allocations from here on, so we can
    // cache pointers and skip re-derefs. W2 = me_ptr (advances). W3 = old
    // payload base (constant). out_ptr lives in B6:B7 as an absolute address.
    rs_peek_at(W0, 3)                 // me
    jsr deref_W0_to_W2                // W2 = me_ptr (= me payload base)
    rs_peek_at(W0, 2)                 // old
    jsr deref_W0_to_W3                // W3 = old payload base
    // me_end = W2 + me_len → stash in B4:B5 (we no longer need src pos B4:B5
    // separately — comparing W2 against me_end ends the loop).
    clc
    lda W2
    adc B0
    sta B4
    lda W2+1
    adc B1
    sta B5                            // B4:B5 = me_end_ptr
    // out_ptr = out payload base.
    rs_peek(W0)
    jsr deref_W0_to_W3                // W3 used temporarily — but we need it back to old
    // Actually: stash out_ptr in B6:B7 then reload W3 = old payload base.
    lda W3
    sta B6
    lda W3+1
    sta B7                            // B6:B7 = out_ptr
    rs_peek_at(W0, 2)                 // old
    jsr deref_W0_to_W3                // W3 = old payload base again
_bsr_p2:
    // if W2 >= me_end (B4:B5) → done.
    lda W2
    cmp B4
    lda W2+1
    sbc B5
    bcc !ok+
    jmp _bsr_p2d
!ok:
    // Check if old fits in remaining: me_end - W2 >= old_len.
    sec
    lda B4
    sbc W2
    tax
    lda B5
    sbc W2+1
    bne _bsr_p2_can_match
    cpx B2
    bcc _bsr_p2byte                   // remaining < old_len → byte copy
_bsr_p2_can_match:
    // Inner compare: needle at W3 vs me at W2 for B2 bytes.
    ldy #0
_bsr_p2_cmp:
    cpy B2
    beq _bsr_p2_match
    lda (W2),y
    eor (W3),y
    bne _bsr_p2byte
    iny
    jmp _bsr_p2_cmp
_bsr_p2_match:
    // Match — copy B3 bytes (new_len) from new payload to out_ptr.
    // We need new payload temporarily; W2 = me_ptr is precious. Use W0.
    rs_peek_at(W0, 1)                 // new
    jsr deref_W0_to_W3                // W3 = new payload base (overwrites old —
                                       // ok, we don't need old until after
                                       // this match completes).
    lda B6
    sta W0
    lda B7
    sta W0+1                          // W0 = out_ptr
    ldy #0
_bsr_p2_cn:
    cpy B3
    beq _bsr_p2_cnd
    lda (W3),y
    sta (W0),y
    iny
    jmp _bsr_p2_cn
_bsr_p2_cnd:
    // out_ptr (B6:B7) += new_len; me_ptr (W2) += old_len.
    clc
    lda B6
    adc B3
    sta B6
    bcc !+
    inc B7
!:
    clc
    lda W2
    adc B2
    sta W2
    bcc !+
    inc W2+1
!:
    // Restore W3 = old payload base for the next iteration's compare.
    rs_peek_at(W0, 2)
    jsr deref_W0_to_W3
    jmp _bsr_p2

_bsr_p2byte:
    // No match: copy me[W2] to out_ptr; advance both by 1.
    ldy #0
    lda (W2),y
    sta B7_save_buf
    lda B6
    sta W0
    lda B7
    sta W0+1
    lda B7_save_buf
    sta (W0),y
    inc W2
    bne !+
    inc W2+1
!:
    inc B6
    bne !+
    inc B7
!:
    jmp _bsr_p2

_bsr_p2d:
    jmp postamble_peek_rv


// Leaf helper: compare (W2 + B4:B5)[0..B2-1] vs W3[0..B2-1].
// B4:B5 = position (word). B2 = compare length (byte; caller guarantees < 256).
// Returns A=1 if equal else 0. Clobbers A, X, Y, W0. Preserves B0..B7.
_bsr_match_at_pos:
    // W0 = W2 + B4:B5 (haystack pointer at the position).
    clc
    lda W2
    adc B4
    sta W0
    lda W2+1
    adc B5
    sta W0+1
    ldx #0
_bsr_mat:
    cpx B2
    beq _bsr_matok
    txa
    tay
    lda (W3),y
    eor (W0),y
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
    jsr deref_W0_to_W2
    sta B0
    stx B1
    ora B0
    beq _bia_false
_bia_loop:
    lda B0
    ora B1
    beq _bia_done
    ldy #0
    lda (W2),y
    and #$DF
    cmp #$41
    bcc _bia_false
    cmp #$5B
    bcs _bia_false
    inc W2
    bne !+
    inc W2+1
!:
    lda B0
    bne !+
    dec B1
!:
    dec B0
    jmp _bia_loop
_bia_done:
    jmp postamble_return_true
_bia_false:
    jmp postamble_return_false

builtin_str_isdigit:
    jsr preamble_call_1_1_w0
    jsr deref_W0_to_W2
    sta B0
    stx B1
    ora B0
    beq _bid_false
_bid_loop:
    lda B0
    ora B1
    beq _bid_done
    ldy #0
    lda (W2),y
    cmp #$30
    bcc _bid_false
    cmp #$3A
    bcs _bid_false
    inc W2
    bne !+
    inc W2+1
!:
    lda B0
    bne !+
    dec B1
!:
    dec B0
    jmp _bid_loop
_bid_done:
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

    // Inline int idx → 16-bit word on FS (low 16 bits of the value).
    ldy #0
    lda (W2),y
    sta W3
    iny
    lda (W2),y
    sta W3+1
    fs_push(W3)

    rs_push(W0)                       // RS: [args_tuple, me]
    rs_push(W1)                       // RS: [args_tuple, me, item]
    jsr array_insert                  // consumes 2 RS + 1 FS; mutates me

    jmp postamble_return_none

// --- list.pop() — remove and return last element ----------------------------
//   in:  args = (me,)   me: TYPE_LIST. Empty list → ERR_TYPE.
// =============================================================================
builtin_list_pop:
    jsr preamble_call_1_1_w0

    // W2 = object base (at O_LEN), B0:B1 = O_LEN word.
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
    sta B1
    lda B0
    ora B1
    bne _bpop_have
    jmp panic_type
_bpop_have:
    // 16-bit dec: B0:B1 = new O_LEN = idx of element to remove.
    lda B0
    bne !+
    dec B1
!:
    dec B0

    // W3 = W2 + O_HEADER + 2*(B0:B1). Build 2*(B0:B1) in W3, then add base.
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
    sta W3+1
    clc
    lda W3
    adc #O_HEADER
    sta W3
    bcc !+
    inc W3+1
!:

    // RV = payload[B0:B1].
    ldy #0
    lda (W3),y
    sta RV
    iny
    lda (W3),y
    sta RV+1

    // Write new O_LEN word at W2.
    ldy #O_LEN
    lda B0
    sta (W2),y
    iny
    lda B1
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

    jmp postamble_peek_rv             // RV = new (slot 0)

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
    jmp postamble_a_one

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
