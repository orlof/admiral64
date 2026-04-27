// -----------------------------------------------------------------------------
// parser — Pratt-style expression parser/evaluator.
//
// Per the architecture decision (see PLANS/stages-7-10.md): there is NO AST.
// NUDs and LEDs evaluate immediately, returning value handles. Loops re-parse
// their body via lexer save/restore. Functions store source-as-strings and
// re-lex on each call.
//
// Token-kind dispatch uses three parallel byte tables indexed by TK_*:
//   nud_lo / nud_hi  — prefix-form handler (literals, unary ops, parens)
//   led_lo / led_hi  — infix-form handler (binary ops, call, subscript)
//   lbp              — left-binding power; 0 = terminator (don't bind)
//
// Self-modifying JSR is used at the dispatch site (4 bytes saved vs. an
// indirect-via-ZP call helper). Handlers are V4' routines that consume
// args via RS and return values in RV.
//
// Initial Stage 8a milestone: TK_INT NUD + TK_PLUS LED + parser_eval entry.
// Expand from here.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

// -----------------------------------------------------------------------------
// LBP precedence levels. Higher binds tighter. Levels are spaced so future
// operator additions can slot in without renumbering. Numeric values match
// general Python precedence ordering.
// -----------------------------------------------------------------------------
.const LBP_TERM    = 0       // EOF, NEWLINE, RPAREN, etc. — no infix binding
.const LBP_OR      = $05     // or
.const LBP_AND     = $06     // and
.const LBP_CMP     = $08     // < <= > >= == != is `is not`
.const LBP_BITOR   = $0A     // |
.const LBP_BITXOR  = $0B     // ^
.const LBP_BITAND  = $0C     // &
.const LBP_SHIFT   = $0D     // << >>
.const LBP_PLUS    = $10     // + -
.const LBP_TIMES   = $20     // * / // %
.const LBP_UNARY   = $30     // unary -, +, ~, not (NUD recursion floor)
.const LBP_POWER   = $40     // ** (right-assoc)
.const LBP_INDEX   = $50     // a[i] (binds even tighter than unary)

// -----------------------------------------------------------------------------
// parser_eval — top-level entry: lex + parse + evaluate a TYPE_STR source.
//   in:   1 handle on RS = TYPE_STR source.
//   out:  RV = handle of the LAST expression's value, or NONE for empty
//         source. Multiple newline-separated statements are evaluated in
//         order; the result of the last one is returned.
//
// Sets up a fresh global scope (TYPE_DICT) at start. Both source and scope
// are RS-rooted for the duration of the body so neither is reaped by GC
// triggered by intermediate allocations.
// V4' wrapper.
// -----------------------------------------------------------------------------
parser_eval:
    preamble_args(1, 0)

    // Source is on RS top from the caller. lexer_init reads it without
    // consuming (preamble_args(0, 0) — see lexer.asm).
    jsr lexer_init

    // Allocate the program's root scope and push it on RS as the second
    // root. Cache the handle in BOTH GLOBAL_SCOPE (current) and ROOT_SCOPE
    // (immutable parent target). Function calls below will swap GLOBAL_SCOPE
    // but always use ROOT_SCOPE as the new local scope's parent.
    jsr dict_alloc                // RV = empty dict
    rs_push(RV)                   // RS: [source, root_scope]
    lda RV
    sta GLOBAL_SCOPE
    sta ROOT_SCOPE
    lda RV+1
    sta GLOBAL_SCOPE+1
    sta ROOT_SCOPE+1

    // Method-call side channel starts cleared.
    lda #0
    sta METHOD_RECEIVER
    sta METHOD_RECEIVER+1

    // Bind built-ins. Each is `name → builtin_handle` in the global dict.
    rs_push_const(STR_NAME_LEN)
    rs_push_const(BUILTIN_LEN)
    jsr scope_set
    rs_push_const(STR_NAME_RANGE)
    rs_push_const(BUILTIN_RANGE)
    jsr scope_set
    rs_push_const(STR_NAME_BOOL)
    rs_push_const(BUILTIN_BOOL)
    jsr scope_set
    rs_push_const(STR_NAME_ABS)
    rs_push_const(BUILTIN_ABS)
    jsr scope_set
    rs_push_const(STR_NAME_CHR)
    rs_push_const(BUILTIN_CHR)
    jsr scope_set
    rs_push_const(STR_NAME_ORD)
    rs_push_const(BUILTIN_ORD)
    jsr scope_set
    rs_push_const(STR_NAME_TYPE)
    rs_push_const(BUILTIN_TYPE)
    jsr scope_set
    rs_push_const(STR_NAME_INT)
    rs_push_const(BUILTIN_INT)
    jsr scope_set
    rs_push_const(STR_NAME_FLOAT)
    rs_push_const(BUILTIN_FLOAT)
    jsr scope_set
    rs_push_const(STR_NAME_STR)
    rs_push_const(BUILTIN_STR)
    jsr scope_set
    rs_push_const(STR_NAME_ID)
    rs_push_const(BUILTIN_ID)
    jsr scope_set
    rs_push_const(STR_NAME_CMP)
    rs_push_const(BUILTIN_CMP)
    jsr scope_set
    rs_push_const(STR_NAME_HEX)
    rs_push_const(BUILTIN_HEX)
    jsr scope_set
    rs_push_const(STR_NAME_REPR)
    rs_push_const(BUILTIN_REPR)
    jsr scope_set
    rs_push_const(STR_NAME_SORT)
    rs_push_const(BUILTIN_SORT)
    jsr scope_set
    rs_push_const(STR_NAME_RND)
    rs_push_const(BUILTIN_RND)
    jsr scope_set

    // Default result if source is empty: NONE.
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1

_pe_loop:
    // Skip leading NEWLINE / INDENT / DEDENT tokens between statements.
    // (At top level, INDENT/DEDENT shouldn't appear in well-formed source,
    // but tolerate them for robustness — Stage 8b's suite parser will
    // care more.)
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    beq _pe_advance
    cmp #TK_INDENT
    beq _pe_advance
    cmp #TK_DEDENT
    beq _pe_advance
    cmp #TK_EOF
    beq _pe_done

    // Parse one statement (dispatches keywords / expression-as-statement).
    jsr parser_stmt
    jmp _pe_loop

_pe_advance:
    jsr lexer_next
    jmp _pe_loop

_pe_done:
    jmp postamble

// -----------------------------------------------------------------------------
// parser_stmt — parse one statement. Pure trampoline: indexes the std_lo /
// std_hi tables by the current token kind and tail-jumps via the rts trick
// to the matching `stmt_*` routine. Mirrors the lexer's char dispatch
// (`_lex_dispatch_char`) and Admiral's STD-table pattern (parser.dasm16:1).
//
// **Not V4'-wrapped.** Each `stmt_*` handler is itself V4' and does its
// own preamble/postamble; its rts returns directly to parser_stmt's caller.
// Total dispatch overhead: 9 bytes regardless of how many statement kinds
// we add.
// -----------------------------------------------------------------------------
parser_stmt:
    ldx LEX_TOKEN_KIND
    lda std_hi,x
    pha
    lda std_lo,x
    pha
    rts                            // → handler (table holds label-1)

// -----------------------------------------------------------------------------
// stmt_expression — default STD: evaluate an expression statement.
// -----------------------------------------------------------------------------
stmt_expression:
    preamble_args(0, 0)
    lda #0
    sta B7
    jsr expression
    jmp postamble

// -----------------------------------------------------------------------------
// stmt_pass — `pass` keyword. Consume token; return NONE.
// -----------------------------------------------------------------------------
stmt_pass:
    preamble_args(0, 0)
    jsr lexer_next
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// stmt_break — `break` keyword. Consume token; return CTRL_BREAK.
// -----------------------------------------------------------------------------
stmt_break:
    preamble_args(0, 0)
    jsr lexer_next
    lda #<CTRL_BREAK
    sta RV
    lda #>CTRL_BREAK
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// stmt_continue — `continue` keyword. Consume token; return CTRL_CONTINUE.
// -----------------------------------------------------------------------------
stmt_continue:
    preamble_args(0, 0)
    jsr lexer_next
    lda #<CTRL_CONTINUE
    sta RV
    lda #>CTRL_CONTINUE
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// stmt_return — `return [expr]`. Allocates a TYPE_CTRL handle with O_LEN=2
// whose payload holds the return-value handle (or NONE if no expression).
//
// Distinguishing CTRL_BREAK / CTRL_CONTINUE / CTRL_RETURN at runtime: the
// break/continue statics have O_LEN=0; return handles have O_LEN=2 with a
// value handle in the payload. Callers (call dispatcher) check O_LEN.
// -----------------------------------------------------------------------------
stmt_return:
    preamble_args(0, 0)
    jsr lexer_next                  // consume `return`

    // No-value variant: `return` followed by NEWLINE / DEDENT / EOF.
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    beq _sret_no_value
    cmp #TK_DEDENT
    beq _sret_no_value
    cmp #TK_EOF
    beq _sret_no_value

    lda #0
    sta B7
    jsr expression                  // RV = return value
    jmp _sret_have_value

_sret_no_value:
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1

_sret_have_value:
    // Wrap RV in a TYPE_CTRL handle. Root the value first since alloc may GC.
    rs_push(RV)
    lda #2
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_CTRL
    sta ALLOC_TYPE
    jsr alloc                       // RV = new TYPE_CTRL handle

    // Write payload[0..1] = the saved value (pop from RS).
    rs_pop(W1)
    jsr deref_RV_to_W2
    ldy #0
    lda W1
    sta (W2),y
    iny
    lda W1+1
    sta (W2),y

    jmp postamble

// -----------------------------------------------------------------------------
// stmt_del — `del NAME[expr]`. Parses a subscript-only target (no `del NAME`
// form for plain locals yet) and removes the entry. LIST: `array_del` at the
// integer index. DICT: binary-search for the key, then `array_del` at the
// found slot. Other types (TUPLE etc.) panic ERR_TYPE.
// V4' wrapper. RV = NONE on success.
// -----------------------------------------------------------------------------
stmt_del:
    preamble_args(0, 0)
    jsr lexer_next                  // consume `del`

    lda LEX_TOKEN_KIND
    cmp #TK_NAME
    beq _sd_have_name
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler
_sd_have_name:
    jsr lexer_get_token_as_string   // RV = name TYPE_STR
    rs_push(RV)                     // RS: [name]
    jsr lexer_next                  // consume name
    jsr scope_get                   // consumes name; RV = container

    lda #TK_LBRACK
    jsr lexer_advance               // consume `[`

    rs_push(RV)                     // RS: [container]
    lda #0
    sta B7
    jsr expression                  // RV = index/key

    lda #TK_RBRACK
    jsr lexer_advance               // consume `]`

    // Dispatch on container type.
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_LIST
    beq _sd_list_del
    cmp #TYPE_DICT
    beq _sd_dict_del
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_sd_list_del:
    // Extract index byte from int handle in RV → fs_push as a word.
    ldy #H_PTR
    lda (RV),y
    sta W2
    iny
    lda (RV),y
    sta W2+1
    ldy #O_HEADER
    lda (W2),y
    sta W2
    lda #0
    sta W2+1
    fs_push(W2)
    jsr array_del                   // consumes container + index
    jmp _sd_done

_sd_dict_del:
    // Find key index via binary search.
    rs_peek(W0)                     // dict
    lda RV
    sta W1
    lda RV+1
    sta W1+1                        // W1 = key
    jsr _dict_bin_search            // A = 1 hit / 0 miss; RV = index on hit
    cmp #0
    bne _sd_dict_remove
    // Miss → KeyError.
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler
_sd_dict_remove:
    lda RV
    sta W2
    lda #0
    sta W2+1
    fs_push(W2)
    jsr array_del                   // consumes dict + index
    // fall through

_sd_done:
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// parser_suite — parse the body of a block: consume INDENT, run statements
// until DEDENT (or EOF), consume DEDENT.
// V4' wrapper. RV is the value of the LAST statement in the suite (mostly
// for symmetry — control-flow contexts ignore it).
// -----------------------------------------------------------------------------
parser_suite:
    preamble_args(0, 0)
    lda #TK_INDENT
    jsr lexer_advance              // expect+consume INDENT

_psu_loop:
    lda LEX_TOKEN_KIND
    cmp #TK_DEDENT
    beq _psu_done
    cmp #TK_EOF
    beq _psu_done_no_dedent
    cmp #TK_NEWLINE
    bne _psu_stmt
    jsr lexer_next                  // skip blank line in body
    jmp _psu_loop

_psu_stmt:
    jsr parser_stmt                 // RV = stmt result (might be a CTRL sentinel)

    // If RV is TYPE_CTRL, exit suite early — caller (loop / if) handles.
    // Save RV before any further allocation could clobber it.
    lda RV
    sta W2                           // W2 = RV (preserved across this block)
    lda RV+1
    sta W2+1
    ldy #H_TYPE
    lda (W2),y
    cmp #TYPE_CTRL
    beq _psu_skip_rest

    // Consume trailing NEWLINE if present.
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    bne _psu_loop
    jsr lexer_next
    jmp _psu_loop

_psu_skip_rest:
    // Control sentinel hit. Skip remaining suite tokens up to and including
    // the matching DEDENT (initial depth = 1, since INDENT was consumed at
    // top). RV must be preserved.
    lda #1
    sta B5                           // B5 = nesting depth (we're inside)
_psu_sk_loop:
    lda LEX_TOKEN_KIND
    cmp #TK_EOF
    beq _psu_sk_restore_rv
    cmp #TK_INDENT
    beq _psu_sk_indent
    cmp #TK_DEDENT
    beq _psu_sk_dedent
    jsr lexer_next
    jmp _psu_sk_loop
_psu_sk_indent:
    inc B5
    jsr lexer_next
    jmp _psu_sk_loop
_psu_sk_dedent:
    dec B5
    jsr lexer_next
    lda B5
    bne _psu_sk_loop
_psu_sk_restore_rv:
    // Re-establish RV from W2 (in case anything in the loop touched it).
    lda W2
    sta RV
    lda W2+1
    sta RV+1
    jmp postamble                    // skip the regular DEDENT-consume

_psu_done:
    jsr lexer_next                  // consume DEDENT
_psu_done_no_dedent:
    jmp postamble

// -----------------------------------------------------------------------------
// skip_suite — advance the lexer past a block without evaluating it. Used
// for the false branches of `if`/`elif`/`else`.
//
// Counts INDENT/DEDENT to find the matching DEDENT. Starts at depth 0.
// First INDENT increments to 1. When a DEDENT brings the count back to 0,
// we've consumed the entire suite (including its closing DEDENT).
// -----------------------------------------------------------------------------
skip_suite:
    preamble_args(0, 0)
    lda #0
    sta B0                          // B0 = nesting depth

_ssu_loop:
    lda LEX_TOKEN_KIND
    cmp #TK_EOF
    beq _ssu_done
    cmp #TK_INDENT
    beq _ssu_indent
    cmp #TK_DEDENT
    beq _ssu_dedent
    jsr lexer_next
    jmp _ssu_loop

_ssu_indent:
    inc B0
    jsr lexer_next
    jmp _ssu_loop

_ssu_dedent:
    dec B0
    jsr lexer_next
    lda B0
    bne _ssu_loop
_ssu_done:
    jmp postamble

// -----------------------------------------------------------------------------
// stmt_if — `if cond: body [elif cond: body]* [else: body]`.
// Uses `branch_taken` (B0) to ensure exactly one body runs.
// -----------------------------------------------------------------------------
stmt_if:
    preamble_args(0, 0)
    jsr lexer_next                  // consume `if`
    lda #0
    sta B6                          // B6 = "branch_taken" — using B6 because
                                    //  val_truthy clobbers B0/B1 as scratch

_sif_main_clause:
    // Just consumed `if` or `elif`. Eval condition.
    lda #0
    sta B7
    jsr expression                  // RV = condition value

    lda #TK_COLON
    jsr lexer_advance               // consume `:`

    // Optional NEWLINE before the suite.
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    bne _sif_no_nl1
    jsr lexer_next
_sif_no_nl1:

    // Earlier branch already taken? Skip this body unconditionally.
    lda B6
    bne _sif_skip

    // Test truthy(cond).
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    jsr val_truthy
    beq _sif_skip

    // Truthy: run the suite, mark branch taken.
    jsr parser_suite
    lda #1
    sta B6
    jmp _sif_check_more

_sif_skip:
    jsr skip_suite

_sif_check_more:
    // After the suite, look for `elif` / `else`. NEWLINEs between blocks
    // are consumed by parser_suite's DEDENT-trailing logic, but a stray
    // one might appear; skip it.
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    bne _sif_check_kw
    jsr lexer_next
    jmp _sif_check_more
_sif_check_kw:
    cmp #TK_ELIF
    bne _sif_check_else
    jsr lexer_next                  // consume `elif`
    jmp _sif_main_clause
_sif_check_else:
    cmp #TK_ELSE
    bne _sif_done
    jsr lexer_next                  // consume `else`
    lda #TK_COLON
    jsr lexer_advance
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    bne _sif_no_nl2
    jsr lexer_next
_sif_no_nl2:
    lda B6
    bne _sif_skip_else
    jsr parser_suite
    jmp _sif_done
_sif_skip_else:
    jsr skip_suite

_sif_done:
    // Propagate body's RV if it's a control sentinel (break/continue need
    // to bubble up through if-statements). Otherwise return NONE — `if` is
    // a statement, not an expression.
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_CTRL
    beq _sif_propagate
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
_sif_propagate:
    jmp postamble

// -----------------------------------------------------------------------------
// stmt_while — `while cond: body`. Re-evaluates cond each iteration via
// lexer save/restore; the cond expression and body source are re-lexed
// each pass.
// -----------------------------------------------------------------------------
stmt_while:
    preamble_args(0, 0)
    jsr lexer_next                  // consume `while`

_swh_loop:
    jsr lexer_save                  // save cond position on FS (28 bytes)

    // Eval cond.
    lda #0
    sta B7
    jsr expression                  // RV = cond

    lda #TK_COLON
    jsr lexer_advance               // consume `:`
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    bne _swh_no_nl
    jsr lexer_next
_swh_no_nl:

    // Test truthy.
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    jsr val_truthy
    beq _swh_exit

    // Truthy: run body.
    jsr parser_suite                // RV = result or CTRL sentinel

    // Check for break / continue.
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_CTRL
    bne _swh_iterate                // not control → normal iteration

    // CTRL sentinel — distinguish break vs continue by handle identity.
    lda RV
    cmp #<CTRL_BREAK
    bne _swh_iterate                // not BREAK → must be CONTINUE → loop
    lda RV+1
    cmp #>CTRL_BREAK
    bne _swh_iterate

    // CTRL_BREAK: pop save, exit.
    jsr lexer_drop
    jmp _swh_done

_swh_iterate:
    // Normal completion or CTRL_CONTINUE: rewind to cond, re-iterate.
    jsr lexer_restore
    jmp _swh_loop

_swh_exit:
    // Falsy: discard save, skip body.
    jsr lexer_drop
    jsr skip_suite

_swh_done:
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// stmt_for — `for VAR in EXPR: body`. EXPR may be LIST / TUPLE / DICT.
// LIST/TUPLE iterate by integer index 0..len-1, binding VAR to each element.
// DICT iterates over keys (Python convention): for each entry tuple
// [key, value] in the payload, VAR is bound to `key`.
//
// RS layout maintained throughout: [..., var_name, container]. Both are
// rooted (var_name is a TYPE_STR, container is a LIST / TUPLE / DICT).
//
// Index counter lives in B5 (1-byte; max 255 iterations — fine).
// B7 is set to 1 when iterating a dict (so the body extracts entry[KEY])
// and 0 for list/tuple.
// -----------------------------------------------------------------------------
stmt_for:
    preamble_args(0, 0)
    jsr lexer_next                  // consume `for`

    // Loop variable name.
    lda LEX_TOKEN_KIND
    cmp #TK_NAME
    beq _sfor_have_name
    jmp _lh_recover                 // expected a name
_sfor_have_name:
    jsr lexer_get_token_as_string   // RV = name TYPE_STR
    rs_push(RV)                     // RS: [..., name]
    jsr lexer_next                  // advance past name

    lda #TK_IN
    jsr lexer_advance               // consume `in`

    // Container expression.
    lda #0
    sta B7
    jsr expression                  // RV = container
    rs_push(RV)                     // RS: [..., name, container]

    // Detect container kind for the loop body. B4 selects the iter mode:
    //   0 = LIST/TUPLE — use the element handle directly.
    //   1 = DICT       — element is (key, value) tuple; bind .key.
    //   2 = STR        — fetch payload byte at index, alloc a fresh 1-char STR.
    lda #0
    sta B4
    ldy #H_TYPE
    lda (RV),y
    cmp #TYPE_DICT
    bne _sfor_check_str
    lda #1
    sta B4
    jmp _sfor_kind_done
_sfor_check_str:
    cmp #TYPE_STR
    bne _sfor_kind_done
    lda #2
    sta B4
_sfor_kind_done:

    lda #TK_COLON
    jsr lexer_advance
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    bne _sfor_no_nl
    jsr lexer_next
_sfor_no_nl:

    // Save lexer state at start of body so each iteration re-lexes.
    jsr lexer_save

    // Counters: B5 = index, B6 = "body_entered" flag (so we know whether
    // the lexer is currently past-body vs at-body-start when exiting).
    lda #0
    sta B5
    sta B6

_sfor_loop:
    // Bounds check: if index >= len(container), exit.
    rs_peek_at(W0, 0)               // W0 = container
    rs_push(W0)                     // for array_len
    jsr array_len                   // A = length (low byte)
    cmp B5
    bcs !ok+
    jmp _sfor_done                  // length < index → exit
!ok:
    bne !go+
    jmp _sfor_done                  // length == index → exit
!go:

    // Dispatch on container kind (B4).
    lda B4
    cmp #2
    beq _sfor_str_iter

    // LIST / TUPLE / DICT path: fetch container[index] via array_get.
    rs_peek_at(W0, 0)
    rs_push(W0)
    lda B5
    sta W2
    lda #0
    sta W2+1
    fs_push(W2)                     // index on FS
    jsr array_get                   // RV = element

    // Dict iteration: RV is a (key, value) 2-tuple — extract the key.
    lda B4
    beq _sfor_bind                  // list/tuple: bind RV directly
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    jsr deref_W0_to_W2              // W2 = entry payload (post-header)
    ldy #0
    lda (W2),y
    sta RV
    iny
    lda (W2),y
    sta RV+1
    jmp _sfor_bind

_sfor_str_iter:
    // String iteration: fetch container.payload[B5] (one byte), then alloc a
    // fresh 1-char TYPE_STR with that byte as the payload. The container is
    // RS-rooted so it survives any GC the alloc triggers.
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2              // W2 = container payload
    ldy B5
    lda (W2),y
    pha                             // save char across alloc

    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                       // RV = new 1-byte TYPE_STR; O_LEN = 1.

    ldy #H_PTR
    lda (RV),y
    sta W3
    iny
    lda (RV),y
    sta W3+1
    ldy #O_HEADER
    pla
    sta (W3),y                      // payload[0] = char

_sfor_bind:

    // scope_set(name, RV).
    rs_peek_at(W0, 1)               // W0 = name (slot 1; container is slot 0)
    rs_push(W0)
    rs_push(RV)
    jsr scope_set                   // consumes 2

    // Restore lexer to body position, re-save for next iter.
    jsr lexer_restore
    jsr lexer_save

    // Run body.
    lda #1
    sta B6                          // mark body entered (lexer will end past body)
    jsr parser_suite                // RV = result or CTRL sentinel

    // Check for break/continue.
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_CTRL
    bne _sfor_step

    lda RV
    cmp #<CTRL_BREAK
    bne _sfor_step                  // CTRL_CONTINUE → just step
    lda RV+1
    cmp #>CTRL_BREAK
    bne _sfor_step

    // CTRL_BREAK: exit.
    jmp _sfor_done

_sfor_step:
    inc B5
    jmp _sfor_loop

_sfor_done:
    jsr lexer_drop                  // pop the active save
    lda B6
    bne _sfor_done_post_body        // we entered body → lexer past body
    jsr skip_suite                  // never entered → still at body start

_sfor_done_post_body:
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// stmt_print — `print expr`. Evaluates expr, prints via print_value, emits a
// trailing newline. Returns NONE.
// -----------------------------------------------------------------------------
stmt_print:
    preamble_args(0, 0)
    jsr lexer_next                  // consume `print`
    lda #0
    sta B7
    jsr expression                  // RV = value
    rs_push(RV)
    jsr print_value                 // consumes 1 arg
    lda #$0D
    jsr screen_put_char             // newline
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// expression — Pratt's expression(rbp). Dispatches NUD then loops on LED.
//   in:   B7 = rbp (right-binding power; 0 for top-level)
//   out:  RV = value handle of the parsed expression.
// V4' wrapper. Recursive (via LED).
// -----------------------------------------------------------------------------
expression:
    preamble_args(0, 0)

    // --- NUD phase ---
    ldx LEX_TOKEN_KIND
    lda nud_lo,x
    sta _expr_nud_jsr+1
    lda nud_hi,x
    sta _expr_nud_jsr+2
_expr_nud_jsr:
    jsr $0000                     // → NUD; returns RV = value
    // Note: NUD is responsible for advancing the lexer past its trigger
    // token. After return, LEX_TOKEN_* points at the *next* token.

_expr_loop:
    // --- LED loop: while lbp[current] > rbp, dispatch LED. ---
    ldx LEX_TOKEN_KIND
    lda lbp_table,x
    cmp B7
    bcc _expr_done                // lbp < rbp → done
    beq _expr_done                // lbp == rbp → done (left-assoc; LED uses rbp=lbp)

    // Push current LHS (RV) on RS so the LED can consume it.
    rs_push(RV)
    lda led_lo,x
    sta _expr_led_jsr+1
    lda led_hi,x
    sta _expr_led_jsr+2
_expr_led_jsr:
    jsr $0000                     // → LED; consumes RS top, returns RV
    jmp _expr_loop

_expr_done:
    jmp postamble

// -----------------------------------------------------------------------------
// skip_expression — consume tokens spanning one expression at the given rbp,
// without evaluating any of them. Used by led_and / led_or to short-circuit
// the RHS while keeping the lexer position correct.
//
// in:  B7 = rbp (right-binding power; same convention as expression).
// out: lexer advanced past the expression. RV unchanged.
//
// Algorithm: state machine with paren/bracket/curly depth tracking.
//   - NUD phase: consume any prefix unaries (+ - not ~), then consume the
//     base value (atom, or open-group → balanced skip).
//   - LED phase: while lbp[current] > rbp at depth 0, consume the LED
//     trigger and re-enter NUD phase. `(` and `[` as LEDs (call / subscript)
//     descend into balanced-skip; `.` consumes the following NAME.
//
// Limitations: does NOT recognize `name = rhs`, `obj.name = rhs`, or
// `obj[i] = rhs` as expression forms. These bind only as the syntax of
// nud_name / led_dot / led_lbrack and would parse as their assignment forms
// during normal evaluation. In skip mode the `=` token has lbp=0 and would
// terminate the skip. For our use (RHS of `and`/`or`) this is fine: Python
// rejects `x and y = 5`, and `(y = 5)` is correctly handled by the depth
// tracker because the `=` is inside parens.
// V4'.
// -----------------------------------------------------------------------------
skip_expression:
    preamble_args(0, 0)

    lda B7
    sta B6                            // B6 = our rbp (preserved across skip)
    lda #0
    sta B5                            // B5 = depth

    // ----- NUD phase: prefix unaries -----
_skipe_prefix:
    ldx LEX_TOKEN_KIND
    cpx #TK_PLUS
    beq _skipe_eat_prefix
    cpx #TK_MINUS
    beq _skipe_eat_prefix
    cpx #TK_NOT
    beq _skipe_eat_prefix
    cpx #TK_TILDE
    beq _skipe_eat_prefix
    bne _skipe_atom
_skipe_eat_prefix:
    jsr lexer_next
    jmp _skipe_prefix

    // ----- NUD phase: base value -----
_skipe_atom:
    cpx #TK_LPAREN
    beq _skipe_open
    cpx #TK_LBRACK
    beq _skipe_open
    cpx #TK_LCURLY
    beq _skipe_open
    // Plain atom: NAME, INT, FLOAT, STR, TRUE, FALSE, NONE_KW, etc.
    jsr lexer_next
    jmp _skipe_after

_skipe_open:
    inc B5
    jsr lexer_next
    // fall into _skipe_inside

    // ----- balanced-skip while depth > 0 -----
_skipe_inside:
    ldx LEX_TOKEN_KIND
    cpx #TK_EOF
    beq _skipe_done                   // malformed — bail
    cpx #TK_LPAREN
    beq _skipe_inside_open
    cpx #TK_LBRACK
    beq _skipe_inside_open
    cpx #TK_LCURLY
    beq _skipe_inside_open
    cpx #TK_RPAREN
    beq _skipe_inside_close
    cpx #TK_RBRACK
    beq _skipe_inside_close
    cpx #TK_RCURLY
    beq _skipe_inside_close
    jsr lexer_next
    jmp _skipe_inside
_skipe_inside_open:
    inc B5
    jsr lexer_next
    jmp _skipe_inside
_skipe_inside_close:
    dec B5
    jsr lexer_next
    lda B5
    bne _skipe_inside
    // depth back to 0 — return to LED phase.
    // fall into _skipe_after

    // ----- LED phase: terminator check + dispatch -----
_skipe_after:
    ldx LEX_TOKEN_KIND
    lda lbp_table,x
    cmp B6
    bcc _skipe_done
    beq _skipe_done
    cpx #TK_LPAREN
    beq _skipe_open                   // call: balanced ( ... )
    cpx #TK_LBRACK
    beq _skipe_open                   // subscript / slice: balanced [ ... ]
    cpx #TK_DOT
    beq _skipe_dot
    // Ordinary infix: consume op token, parse next operand.
    jsr lexer_next
    jmp _skipe_prefix

_skipe_dot:
    jsr lexer_next                    // consume `.`
    lda LEX_TOKEN_KIND
    cmp #TK_NAME
    bne _skipe_done                   // malformed — bail
    jsr lexer_next                    // consume NAME
    jmp _skipe_after

_skipe_done:
    jmp postamble

// -----------------------------------------------------------------------------
// _skip_layout — consume any TK_NEWLINE / TK_INDENT / TK_DEDENT tokens at the
// current position. Used inside literal bodies (`[...]`, `{...}`, `(...)`) so
// they may span multiple physical lines. The lexer doesn't track bracket
// depth itself, so we make layout transparent at known boundaries (after the
// open, before the close, around `,` and `:`).
//
// Leaf helper — does not preserve W/B (calls only V4'-wrapped lexer_next,
// which does its own save/restore). Uses A as scratch.
// -----------------------------------------------------------------------------
_skip_layout:
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    beq _skl_eat
    cmp #TK_INDENT
    beq _skl_eat
    cmp #TK_DEDENT
    beq _skl_eat
    rts
_skl_eat:
    jsr lexer_next
    jmp _skip_layout

// -----------------------------------------------------------------------------
// cast_common_number_type — promote two RS-top numeric handles to a common
// type. Accepts INT, BOOL (treated as 1-byte int), or FLOAT. Any other
// operand type panics with ERR_TYPE — type-correctness is the caller's
// problem to dispatch around BEFORE calling here.
//
//   in:  RS [a, b] — top is b.
//   out: RS [a', b'] — both same numeric type; possibly new handles.
//
// **Leaf helper, NOT V4'-wrapped.** Calls int_to_float (V4', preserves W/B
// of its caller) but doesn't preserve W/B itself. That's fine: every LED
// using this calls it just before the type dispatch, so no W/B state is
// expected to survive across.
// -----------------------------------------------------------------------------
cast_common_number_type:
    rs_peek_at(W0, 1)            // a
    rs_peek_at(W1, 0)            // b

    // Validate `a`. INT/BOOL → int-side. FLOAT → float-side. Else panic.
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq _ccnt_a_int
    cmp #TYPE_BOOL
    beq _ccnt_a_int
    cmp #TYPE_FLOAT
    beq _ccnt_a_float
    jmp _ccnt_type_error

_ccnt_a_int:
    // a is int-shaped. Validate b.
    lda (W1),y
    cmp #TYPE_INT
    beq _ccnt_done                // both int-shaped — no cast
    cmp #TYPE_BOOL
    beq _ccnt_done
    cmp #TYPE_FLOAT
    beq _ccnt_promote_a
    jmp _ccnt_type_error

_ccnt_promote_a:
    // a int-ish, b FLOAT → promote a.
    rs_pop(W1)                    // pop b → W1; RS: [a]
    jsr int_to_float              // consumes top (a); RV = a_float; RS: []
    rs_push(RV)                   // RS: [a_float]
    rs_push(W1)                   // RS: [a_float, b]
    rts

_ccnt_a_float:
    // a is FLOAT. Validate b.
    lda (W1),y
    cmp #TYPE_FLOAT
    beq _ccnt_done                // both FLOAT — no cast
    cmp #TYPE_INT
    beq _ccnt_promote_b
    cmp #TYPE_BOOL
    beq _ccnt_promote_b
    jmp _ccnt_type_error

_ccnt_promote_b:
    // a FLOAT, b int-ish → promote b. b is on top; int_to_float consumes it.
    jsr int_to_float              // RV = b_float; RS: [a]
    rs_push(RV)                   // RS: [a, b_float]
_ccnt_done:
    rts

_ccnt_type_error:
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

// -----------------------------------------------------------------------------
// infix_eval — shared prologue for every binary LED. Reads the current
// token's LBP from the lbp_table (so we don't hardcode `lda #LBP_PLUS` in
// each LED), advances past the operator, parses+evaluates the RHS, and
// leaves both operands on RS in [LHS, RHS] order.
//
//   in:   RS top = LHS (already pushed by caller). LEX_* at the operator.
//   out:  RS top = RHS, slot 1 = LHS. RV = unspecified.
//
// **Leaf helper, NOT V4'-wrapped.** A V4' postamble would restore RSP to
// its frame's target_RSP — wiping the RHS push we just made. Instead we
// inherit the caller's frame: B7 is the caller's saved register, set here
// for `expression`'s rbp; the caller's `jmp postamble` restores it on exit.
// Mirrors DCPU's `infix` (parser.dasm16:2330) but elides the `eval`
// indirection since we already eagerly evaluate operands.
// -----------------------------------------------------------------------------
infix_eval:
    ldx LEX_TOKEN_KIND
    lda lbp_table,x
    sta B7                            // rbp for left-associative recursion
    jsr lexer_next                    // consume the operator token
    jsr expression                    // RV = RHS handle (W/B preserved by V4')
    rs_push(RV)                       // RS: [..., LHS, RHS]
    rts

// -----------------------------------------------------------------------------
// infixr_eval — right-associative variant. Parses the RHS at LBP - 1.
// Used by `**` (power) when it lands.
// -----------------------------------------------------------------------------
infixr_eval:
    ldx LEX_TOKEN_KIND
    lda lbp_table,x
    sec
    sbc #1
    sta B7
    jsr lexer_next
    jsr expression
    rs_push(RV)
    rts

// -----------------------------------------------------------------------------
// led_binop / led_cmp macros — the per-operator LED collapses to one line
// of source. led_binop calls a routine that consumes 2 RS args and returns
// RV. led_cmp uses val_cmp + a result-bit mask passed via X.
// -----------------------------------------------------------------------------
.macro led_binop(op_routine) {
    preamble_args(1, 0)
    jsr infix_eval                    // ← caller's LHS now under RS top RHS
    jsr op_routine                    // consumes both, RV = result
    jmp postamble
}

.macro led_binop_r(op_routine) {
    preamble_args(1, 0)
    jsr infixr_eval                   // right-assoc variant
    jsr op_routine
    jmp postamble
}

// led_arith — type-promoting binary op. After infix_eval, casts both
// operands to a common numeric type (INT or FLOAT), then dispatches to
// `int_op` or `float_op` based on the (now-uniform) RS top type.
.macro led_arith(int_op, float_op) {
    preamble_args(1, 0)
    jsr infix_eval
    jsr cast_common_number_type
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_FLOAT
    beq !float+
    jsr int_op
    jmp postamble
!float:
    jsr float_op
    jmp postamble
}

// Right-associative type-promoting variant — used by `**`.
.macro led_arith_r(int_op, float_op) {
    preamble_args(1, 0)
    jsr infixr_eval
    jsr cast_common_number_type
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_FLOAT
    beq !float+
    jsr int_op
    jmp postamble
!float:
    jsr float_op
    jmp postamble
}

.macro led_cmp(mask) {
    preamble_args(1, 0)
    jsr infix_eval
    jsr cast_common_number_type       // promote so int/float compare correctly
    jsr val_cmp                       // A = $FF / $00 / $01; consumes 2 args
    ldx #mask
    jsr _cmp_finish                   // RV = TRUE / FALSE
    jmp postamble
}

// -----------------------------------------------------------------------------
// nud_int — parse the current TK_INT span into a TYPE_INT handle.
// V4' wrapper. Advances the lexer before returning.
// -----------------------------------------------------------------------------
nud_int:
    preamble_args(0, 0)
    // W0 = LEX_TOKEN_START; A = (LEX_TOKEN_END - LEX_TOKEN_START).
    lda LEX_TOKEN_START
    sta W0
    lda LEX_TOKEN_START+1
    sta W0+1
    sec
    lda LEX_TOKEN_END
    sbc LEX_TOKEN_START
    // (high byte assumed 0 — int literals don't span 256 bytes)
    jsr int_parse_dec             // RV = handle
    jsr lexer_next                // advance past the int token
    jmp postamble

// -----------------------------------------------------------------------------
// nud_hex / nud_bin — TK_HEX / TK_BIN spans (include "0x" / "0b" prefix).
// -----------------------------------------------------------------------------
nud_hex:
    preamble_args(0, 0)
    lda LEX_TOKEN_START
    sta W0
    lda LEX_TOKEN_START+1
    sta W0+1
    sec
    lda LEX_TOKEN_END
    sbc LEX_TOKEN_START
    jsr int_parse_hex
    jsr lexer_next
    jmp postamble

nud_bin:
    preamble_args(0, 0)
    lda LEX_TOKEN_START
    sta W0
    lda LEX_TOKEN_START+1
    sta W0+1
    sec
    lda LEX_TOKEN_END
    sbc LEX_TOKEN_START
    jsr int_parse_bin
    jsr lexer_next
    jmp postamble

// -----------------------------------------------------------------------------
// Binary arithmetic LEDs — each is one macro line. infix_eval reads the
// per-token LBP, parses+evaluates the RHS, and leaves [LHS, RHS] on RS.
// `/` and `//` both currently map to integer division; when TYPE_FLOAT
// participates, `/` will switch to float division.
// -----------------------------------------------------------------------------
// led_plus dispatches by LHS type. Numeric operands (INT/BOOL/FLOAT) take
// the cast-and-arith path. Container operands (STR/LIST/TUPLE) take
// array_merge, which validates the RHS type matches.
led_plus:
    preamble_args(1, 0)
    jsr infix_eval                    // RS: [LHS, RHS]
    rs_peek_at(W0, 1)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq _lp_merge
    cmp #TYPE_LIST
    beq _lp_merge
    cmp #TYPE_TUPLE
    beq _lp_merge
    jsr cast_common_number_type
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_FLOAT
    beq _lp_float
    jsr int_add
    jmp postamble
_lp_float:
    jsr float_add
    jmp postamble
_lp_merge:
    jsr array_merge
    jmp postamble

led_minus:
    led_arith(int_sub, float_sub)

// led_star dispatches by operand types. Numeric × numeric uses cast+arith.
// container × INT, INT × container both delegate to array_repeat (with a
// swap when the container is on the right). Container × container is
// rejected by array_repeat's n-type check.
led_star:
    preamble_args(1, 0)
    jsr infix_eval                    // RS: [LHS, RHS]
    rs_peek_at(W0, 1)
    rs_peek_at(W1, 0)
    ldy #H_TYPE
    lda (W0),y
    sta B0                            // B0 = LHS type
    lda (W1),y
    sta B1                            // B1 = RHS type

    // LHS is container?
    lda B0
    cmp #TYPE_STR
    beq _ls_repeat_jmp
    cmp #TYPE_LIST
    beq _ls_repeat_jmp
    cmp #TYPE_TUPLE
    beq _ls_repeat_jmp

    // RHS is container? Swap operands so container is on the deeper slot,
    // then dispatch to repeat.
    lda B1
    cmp #TYPE_STR
    beq _ls_swap_repeat_jmp
    cmp #TYPE_LIST
    beq _ls_swap_repeat_jmp
    cmp #TYPE_TUPLE
    beq _ls_swap_repeat_jmp
    jmp _ls_numeric
_ls_repeat_jmp:
    jmp _ls_repeat
_ls_swap_repeat_jmp:
    jmp _ls_swap_repeat
_ls_numeric:

    // Numeric path.
    jsr cast_common_number_type
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_FLOAT
    beq _ls_float
    jsr int_mul
    jmp postamble
_ls_float:
    jsr float_mul
    jmp postamble

_ls_swap_repeat:
    rs_pop(W1)                        // top: was b
    rs_pop(W0)                        // below: was a
    rs_push(W1)
    rs_push(W0)
_ls_repeat:
    jsr array_repeat
    jmp postamble
led_slash:
    led_arith(int_div, float_div)
led_dslash:
    led_arith(int_div, float_floordiv)   // int floor-div / Python-style float //
led_percent:
    led_arith(int_mod, float_mod)        // float `%` is Python a - floor(a/b)*b
led_power:
    led_arith_r(int_pow, float_pow)      // right-assoc; FPWRT for float operands
led_amp:
    led_binop(int_bitwise_and)
led_pipe:
    led_binop(int_bitwise_or)
led_caret:
    led_binop(int_bitwise_xor)
led_lshift:
    led_binop(int_lshift)
led_rshift:
    led_binop(int_rshift)

// -----------------------------------------------------------------------------
// nud_minus / nud_plus — unary - and +. Parse operand at LBP_UNARY (binds
// tighter than * / so `-2*3` is `(-2)*3`). Unary `+` is the identity; we
// just return the operand value untouched.
// -----------------------------------------------------------------------------
nud_minus:
    preamble_args(0, 0)
    jsr lexer_next
    lda #LBP_UNARY
    sta B7
    jsr expression
    rs_push(RV)
    // Dispatch on operand type. INT/BOOL → int_negate; FLOAT → float_neg;
    // anything else panics ERR_TYPE.
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_FLOAT
    beq _nm_float
    cmp #TYPE_INT
    beq _nm_int
    cmp #TYPE_BOOL
    beq _nm_int
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler
_nm_int:
    jsr int_negate
    jmp postamble
_nm_float:
    jsr float_neg
    jmp postamble

nud_plus:
    preamble_args(0, 0)
    jsr lexer_next
    lda #LBP_UNARY
    sta B7
    jsr expression                // RV = operand value (already in RV)
    jmp postamble

// -----------------------------------------------------------------------------
// nud_lparen — `(...)` overload:
//   `()`          → empty tuple
//   `(expr)`      → grouping (just return expr)
//   `(expr,)`     → 1-tuple
//   `(a, b, ...)` → tuple
//
// Trick (mirrors Admiral): build the result as a TYPE_LIST via list_append
// — same payload shape as TYPE_TUPLE — then mutate H_TYPE to TYPE_TUPLE at
// the end. Avoids needing a "tuple grow" primitive.
// -----------------------------------------------------------------------------
nud_lparen:
    preamble_args(0, 0)
    jsr lexer_next                // consume '('
    jsr _skip_layout              // newlines OK after `(`

    // Empty `()` → empty tuple.
    lda LEX_TOKEN_KIND
    cmp #TK_RPAREN
    bne _nlp_first
    jsr lexer_next
    lda #0
    jsr tuple_alloc
    jmp postamble

_nlp_first:
    // Parse first expression.
    lda #0
    sta B7
    jsr expression                // RV = first element
    jsr _skip_layout              // newlines OK before `,` / `)`

    // Next token decides: `)` → grouping; `,` → tuple build.
    lda LEX_TOKEN_KIND
    cmp #TK_COMMA
    beq _nlp_tuple_mode
    // Grouping — consume `)` and return RV unchanged.
    lda #TK_RPAREN
    jsr lexer_advance
    jmp postamble

_nlp_tuple_mode:
    // Build a list accumulator with the first element, then loop.
    rs_push(RV)                   // RS: [first]
    lda #0
    jsr list_alloc                // RV = empty list
    // Re-arrange to RS: [list], with first element appended.
    rs_pop(W0)                    // W0 = first; RS: []
    rs_push(RV)                   // RS: [list]
    rs_peek(W1)                   // W1 = list
    rs_push(W1)                   // RS: [list, list]
    rs_push(W0)                   // RS: [list, list, first]
    jsr list_append               // → RS: [list]

_nlp_tloop:
    lda LEX_TOKEN_KIND
    cmp #TK_COMMA
    bne _nlp_tclose
    jsr lexer_next                // consume ','
    jsr _skip_layout              // newlines OK after `,`
    // Trailing comma `(a, b,)` is allowed.
    lda LEX_TOKEN_KIND
    cmp #TK_RPAREN
    beq _nlp_tclose
    lda #0
    sta B7
    jsr expression                // RV = next element
    jsr _skip_layout              // newlines OK before `,` / `)`
    rs_peek(W0)
    rs_push(W0)                   // RS: [list, list]
    rs_push(RV)                   // RS: [list, list, element]
    jsr list_append               // → RS: [list]
    jmp _nlp_tloop

_nlp_tclose:
    lda #TK_RPAREN
    jsr lexer_advance
    // Mutate type tag list → tuple. Same payload layout, no realloc needed.
    rs_peek(W0)
    ldy #H_TYPE
    lda #TYPE_TUPLE
    sta (W0),y
    rs_pop(RV)
    jmp postamble

// -----------------------------------------------------------------------------
// nud_lcurly — dict literal `{key: value, ...}`.  `{}` is an empty dict
// (Python convention; sets aren't supported).
// -----------------------------------------------------------------------------
nud_lcurly:
    preamble_args(0, 0)
    jsr lexer_next                // consume '{'
    jsr _skip_layout              // newlines OK after `{`
    jsr dict_alloc                // RV = empty dict
    rs_push(RV)                   // RS: [dict]

    lda LEX_TOKEN_KIND
    cmp #TK_RCURLY
    bne _ndc_loop
    jsr lexer_next                // empty `{}`
    rs_pop(RV)
    jmp postamble

_ndc_loop:
    // Push a dict copy so dict_set's 3-arg consume leaves the persistent
    // reference (RS slot 1) intact for the next iteration.
    rs_peek(W0)
    rs_push(W0)                   // RS: [dict, dict_copy]

    // Parse key.
    lda #0
    sta B7
    jsr expression
    jsr _skip_layout              // newlines OK before `:`
    rs_push(RV)                   // RS: [dict, dict_copy, key]

    lda #TK_COLON
    jsr lexer_advance
    jsr _skip_layout              // newlines OK after `:`

    // Parse value.
    lda #0
    sta B7
    jsr expression
    jsr _skip_layout              // newlines OK before `,` / `}`
    rs_push(RV)                   // RS: [dict, dict_copy, key, value]

    jsr dict_set                  // consumes 3 → RS: [dict]

    lda LEX_TOKEN_KIND
    cmp #TK_COMMA
    bne _ndc_close
    jsr lexer_next                // consume ','
    jsr _skip_layout              // newlines OK after `,`
    // Trailing comma `{a: 1,}` is allowed.
    lda LEX_TOKEN_KIND
    cmp #TK_RCURLY
    beq _ndc_close
    jmp _ndc_loop

_ndc_close:
    lda #TK_RCURLY
    jsr lexer_advance
    rs_pop(RV)
    jmp postamble

// -----------------------------------------------------------------------------
// Comparison LEDs — <, <=, >, >=, ==, !=.
//
// Strategy: push LHS+RHS onto RS, call val_cmp (returns A in {$FF, $00, $01}
// = lt / eq / gt). Translate via per-op A-bit tests into TRUE/FALSE static
// handle in RV.
// -----------------------------------------------------------------------------

// Shared tail: A holds val_cmp result; X holds a "true mask" — 1=lt, 2=eq,
// 4=gt. If the mask bit corresponding to the result is set → TRUE else FALSE.
_cmp_finish:
    // Convert val_cmp's $FF/$00/$01 to bit positions 1/2/4.
    cmp #$00
    beq !eq+
    cmp #$01
    beq !gt+
    // $FF → lt
    lda #1
    jmp !test+
!eq:
    lda #2
    jmp !test+
!gt:
    lda #4
!test:
    sta B0                       // B0 = result-bit
    txa
    and B0
    bne _cmp_true
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
    rts
_cmp_true:
    lda #<TRUE
    sta RV
    lda #>TRUE
    sta RV+1
    rts

// -----------------------------------------------------------------------------
// Comparison LEDs — one macro line each. The bit-mask passed to
// _cmp_finish picks which val_cmp results map to TRUE (lt=1, eq=2, gt=4).
// -----------------------------------------------------------------------------
led_lt:
    led_cmp(1)
led_le:
    led_cmp(1 | 2)
led_gt:
    led_cmp(4)
led_ge:
    led_cmp(2 | 4)
led_eq:
    led_cmp(2)
led_neq:
    led_cmp(1 | 4)

// -----------------------------------------------------------------------------
// Boolean / None literal NUDs. Each just sets RV to the static singleton
// handle and advances past its token.
// -----------------------------------------------------------------------------
nud_true:
    preamble_args(0, 0)
    lda #<TRUE
    sta RV
    lda #>TRUE
    sta RV+1
    jsr lexer_next
    jmp postamble

nud_false:
    preamble_args(0, 0)
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
    jsr lexer_next
    jmp postamble

nud_none:
    preamble_args(0, 0)
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jsr lexer_next
    jmp postamble

// -----------------------------------------------------------------------------
// nud_tilde — prefix bitwise NOT `~x`.
// -----------------------------------------------------------------------------
nud_tilde:
    preamble_args(0, 0)
    jsr lexer_next                // consume '~'
    lda #LBP_UNARY
    sta B7
    jsr expression                // RV = operand
    rs_push(RV)
    jsr int_bitwise_not           // RV = ~x
    jmp postamble

// -----------------------------------------------------------------------------
// nud_not — prefix `not`. Recurses at LBP_AND so `not 1 < 2` parses as
// `not (1 < 2)` (cmp binds tighter) and `x and not y` as `x and (not y)`
// (and exits at its own LBP).
// -----------------------------------------------------------------------------
nud_not:
    preamble_args(0, 0)
    jsr lexer_next                // consume `not`
    lda #LBP_AND
    sta B7
    jsr expression                // RV = operand handle
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    jsr val_truthy                // A = 1 / 0
    bne _nn_to_false
    // operand was falsy → result True
    lda #<TRUE
    sta RV
    lda #>TRUE
    sta RV+1
    jmp postamble
_nn_to_false:
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// led_and / led_or — boolean conjunction / disjunction with Python-style
// short-circuit. The truthiness of LHS is checked BEFORE RHS is parsed; if
// the result is fully determined by LHS, the RHS tokens are skipped (no
// allocation, no calls, no scope writes) via skip_expression.
//
// Result rule (matches Python on already-evaluated operands):
//   x and y  →  x if not truthy(x) else y
//   x or  y  →  x if     truthy(x) else y
// -----------------------------------------------------------------------------
led_and:
    preamble_args(1, 0)               // LHS on RS
    jsr lexer_next                    // consume `and`

    rs_peek(W0)                       // W0 = LHS handle
    jsr val_truthy
    beq _land_short                   // LHS falsy → short-circuit

    // LHS truthy → eval RHS, return RHS.
    lda #LBP_AND
    sta B7
    jsr expression
    jmp postamble

_land_short:
    // LHS falsy → skip RHS, return LHS.
    lda #LBP_AND
    sta B7
    jsr skip_expression
    rs_peek(RV)                       // RV = LHS (still on RS)
    jmp postamble

led_or:
    preamble_args(1, 0)
    jsr lexer_next                    // consume `or`

    rs_peek(W0)
    jsr val_truthy
    bne _lor_short                    // LHS truthy → short-circuit

    // LHS falsy → eval RHS, return RHS.
    lda #LBP_OR
    sta B7
    jsr expression
    jmp postamble

_lor_short:
    // LHS truthy → skip RHS, return LHS.
    lda #LBP_OR
    sta B7
    jsr skip_expression
    rs_peek(RV)
    jmp postamble

// -----------------------------------------------------------------------------
// led_is — handle identity `a is b` and `a is not b`.
// Doesn't fit the led_binop / led_cmp shape because the `not` token after
// `is` is parser-level state, not part of the lexer's token stream.
// -----------------------------------------------------------------------------
led_is:
    preamble_args(1, 0)
    jsr lexer_next                    // consume `is`
    lda #0
    sta B0                            // B0 = invert flag (0 = `is`, 1 = `is not`)
    lda LEX_TOKEN_KIND
    cmp #TK_NOT
    bne !skip_not+
    lda #1
    sta B0
    jsr lexer_next                    // consume `not`
!skip_not:
    lda #LBP_CMP
    sta B7
    jsr expression                    // RV = RHS handle

    // Handle-pointer compare: LHS (still on RS top) vs RV.
    rs_peek(W0)
    lda W0
    cmp RV
    bne _lis_diff
    lda W0+1
    cmp RV+1
    bne _lis_diff
    // Same handle. `is` → TRUE; `is not` → FALSE.
    lda B0
    bne _lis_to_false
    jmp _lis_to_true
_lis_diff:
    lda B0
    beq _lis_to_false
_lis_to_true:
    lda #<TRUE
    sta RV
    lda #>TRUE
    sta RV+1
    jmp postamble
_lis_to_false:
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// led_in — `x in container`. Membership test. Dispatches on the RHS
// (container) type:
//   STR   → str_search (substring; LHS must also be STR)
//   LIST  → array_find (val_eq scan)
//   TUPLE → array_find
//   DICT  → _dict_bin_search (key membership)
// Returns the TRUE / FALSE static handle.
// -----------------------------------------------------------------------------
led_in:
    preamble_args(1, 0)               // RS: [LHS]
    jsr infix_eval                    // RS: [LHS, RHS]

    rs_peek(W0)                       // W0 = RHS = container
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq _lin_str
    cmp #TYPE_LIST
    beq _lin_seq
    cmp #TYPE_TUPLE
    beq _lin_seq
    cmp #TYPE_DICT
    beq _lin_dict
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_lin_str:
    // For STR membership the needle must also be a TYPE_STR. (Python rejects
    // `1 in "abc"` with TypeError; we follow.)
    rs_peek_at(W0, 1)
    ldy #H_TYPE                       // rs_peek_at clobbered Y
    lda (W0),y
    cmp #TYPE_STR
    beq !ok+
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler
!ok:
    jsr str_find_pos                  // A = position or $FF (not found)
    cmp #$FF
    beq _lin_false
    lda #1
    jmp _lin_to_bool

_lin_seq:
    jsr array_find
    jmp _lin_to_bool

_lin_dict:
    // _dict_bin_search expects W0 = dict, W1 = key. Args via ZP only — RS
    // unaffected. Our two args still occupy RS [LHS=key, RHS=dict] and will
    // be consumed by postamble's target_RSP cleanup.
    rs_peek_at(W0, 0)                 // dict (top)
    rs_peek_at(W1, 1)                 // key
    jsr _dict_bin_search              // A = 1 (hit) or 0 (miss)
    // fall through

_lin_to_bool:
    cmp #0
    beq _lin_false
    lda #<TRUE
    sta RV
    lda #>TRUE
    sta RV+1
    jmp postamble
_lin_false:
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// nud_lbrack — list literal `[a, b, c]`. Handles empty `[]` too.
// -----------------------------------------------------------------------------
nud_lbrack:
    preamble_args(0, 0)
    jsr lexer_next                    // consume '['
    jsr _skip_layout                  // newlines OK after `[`
    lda #0
    jsr list_alloc                    // RV = empty list
    rs_push(RV)                       // root + accumulator: RS top = list

    lda LEX_TOKEN_KIND
    cmp #TK_RBRACK
    bne _nlb_loop
    // Empty list — consume ']' and return.
    jsr lexer_next
    rs_pop(RV)
    jmp postamble

_nlb_loop:
    // Parse element expression at top precedence.
    lda #0
    sta B7
    jsr expression                    // RV = element
    jsr _skip_layout                  // newlines OK before `,` / `]`

    // Append: list_append wants RS [list, child]. We have [list]; push a
    // duplicate, then the child.
    rs_peek(W0)
    rs_push(W0)
    rs_push(RV)
    jsr list_append                   // consumes 2 args; original list (RS slot) untouched

    lda LEX_TOKEN_KIND
    cmp #TK_COMMA
    bne _nlb_check_close
    jsr lexer_next                    // consume ','
    jsr _skip_layout                  // newlines OK after `,`
    // Accept trailing comma: `[1, 2,]` → list of [1, 2].
    lda LEX_TOKEN_KIND
    cmp #TK_RBRACK
    beq _nlb_done
    jmp _nlb_loop

_nlb_check_close:
    cmp #TK_RBRACK
    bne _nlb_recover

_nlb_done:
    jsr lexer_next                    // consume ']'
    rs_pop(RV)                        // RV = the assembled list
    jmp postamble

_nlb_recover:
    jmp _lh_recover_parser

// -----------------------------------------------------------------------------
// led_lparen — function call `f(arg1, arg2, ...)`.
//
// Pratt LED on TK_LPAREN: caller (expression's loop) has the callable on
// RS as the LHS. We parse args (comma-separated), pushing each on RS, then
// dispatch based on the callable's type. Stage 10 starter only handles
// TYPE_BUILTIN: payload is a 2-byte impl address; we SMC-JSR to it.
// User-defined functions (Stage 9c) will dispatch on TYPE_FUNC.
//
// RS layout maintained in body: [..., LHS, arg1, ..., argN]. Arg count
// tracked in B0 so we can locate LHS in the dispatch step (it's at depth
// B0 from RS top).
// -----------------------------------------------------------------------------
led_lparen:
    preamble_args(1, 0)             // LHS on RS (the callable)
    jsr lexer_next                  // consume `(`

    // Snapshot METHOD_RECEIVER (set by led_dot if this is a method call),
    // push it onto RS as a root, then clear ZP. RS layout: [LHS, me_or_0].
    // me_or_0 = NONE-handle-style 0 if no preceding led_dot.
    lda METHOD_RECEIVER
    sta W0
    lda METHOD_RECEIVER+1
    sta W0+1
    rs_push(W0)                     // RS: [LHS, me]
    lda #0
    sta METHOD_RECEIVER
    sta METHOD_RECEIVER+1

    // Peek LHS type before parsing args — TYPE_STR uses kwargs (`name=value`),
    // TYPE_BUILTIN uses positional args. LHS is now at slot 1 (slot 0 = me).
    rs_peek_at(W0, 1)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq _llp_str_call
    cmp #TYPE_BUILTIN
    beq _llp_builtin_call
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler

// --- Built-in: positional args, dispatch via SMC JSR to impl ----------------
_llp_builtin_call:
    lda #0
    sta B0                          // B0 = arg count

    lda LEX_TOKEN_KIND
    cmp #TK_RPAREN
    beq _llp_b_args_done

_llp_b_arg_loop:
    lda #0
    sta B7
    jsr expression                  // RV = arg
    rs_push(RV)
    inc B0

    lda LEX_TOKEN_KIND
    cmp #TK_COMMA
    bne _llp_b_args_done
    jsr lexer_next
    jmp _llp_b_arg_loop

_llp_b_args_done:
    lda #TK_RPAREN
    jsr lexer_advance

    // Locate LHS at RS depth = arg_count + 1 (LHS is below the args AND
    // the me-root we pushed at function entry). Byte offset = 2*(B0+1).
    lda B0
    clc
    adc #1
    asl
    tay
    lda (RSP),y
    sta W0
    iny
    lda (RSP),y
    sta W0+1

    // Read impl address from the builtin's 2-byte payload.
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
    bcc !skip+
    inc W2+1
!skip:
    ldy #0
    lda (W2),y
    sta _llp_jsr+1
    iny
    lda (W2),y
    sta _llp_jsr+2
_llp_jsr:
    jsr $0000                       // → builtin impl
    jmp postamble                   // postamble cleans LHS off RS

// --- TYPE_STR: kwargs, body re-lex in fresh scope ---------------------------
//
// Algorithm:
//   1. Save current GLOBAL_SCOPE on RS (root).
//   2. Allocate new scope dict, set GLOBAL_SCOPE.
//   3. Parse `(name=value, ...)`, scope_set each name→value (now into new scope).
//   4. Save outer lexer state on FS.
//   5. Push body string handle on RS, lexer_init on it.
//   6. Run statement loop until EOF or CTRL_RETURN.
//   7. If CTRL_RETURN, extract its payload as the call's result.
//   8. Pop body-handle copy. lexer_restore. Restore GLOBAL_SCOPE.
//
// RS layout during body execution:
//   [..., LHS, old_scope, new_scope, body_handle_for_lexer]
_llp_str_call:
    // Save current global scope onto RS for restoration after the call.
    lda GLOBAL_SCOPE
    sta W0
    lda GLOBAL_SCOPE+1
    sta W0+1
    rs_push(W0)                     // RS: [LHS, old_scope]

    // New scope.
    jsr dict_alloc                  // RV = empty dict
    rs_push(RV)                     // RS: [LHS, old_scope, new_scope]

    // Link parent: new_scope["_"] = ROOT_SCOPE.
    rs_peek(W0)
    rs_push(W0)                     // RS: [..., new_scope]
    rs_push_const(STR_UNDERSCORE)
    rs_push(ROOT_SCOPE)
    jsr dict_set                    // consumes 3 → RS: [LHS, old, new]

    // Parse kwargs in CALLER's scope (GLOBAL_SCOPE unchanged), pushing each
    // (name, value) pair on RS for later binding. Track the count in B0.
    lda #0
    sta B0

    lda LEX_TOKEN_KIND
    cmp #TK_RPAREN
    beq _llp_s_args_done

_llp_s_arg_loop:
    lda LEX_TOKEN_KIND
    cmp #TK_NAME
    beq _llp_s_have_name
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler
_llp_s_have_name:
    jsr lexer_get_token_as_string   // RV = name TYPE_STR
    rs_push(RV)                     // RS: [..., new, ..., name]
    jsr lexer_next                  // consume name
    lda #TK_ASSIGN
    jsr lexer_advance               // consume `=`
    lda #0
    sta B7
    jsr expression                  // RV = value (resolved in caller scope)
    rs_push(RV)                     // RS: [..., new, ..., name, value]
    inc B0

    lda LEX_TOKEN_KIND
    cmp #TK_COMMA
    bne _llp_s_args_done
    jsr lexer_next
    jmp _llp_s_arg_loop

_llp_s_args_done:
    lda #TK_RPAREN
    jsr lexer_advance               // consume `)`

    // All kwargs evaluated. Switch GLOBAL_SCOPE = new_scope. With B0 kwargs
    // (2 words each) plus the unchanged me push, new_scope is at slot index
    // 2*B0 from RS top; byte offset = 4*B0.
    lda B0
    asl
    asl
    tay
    lda (RSP),y
    sta GLOBAL_SCOPE
    iny
    lda (RSP),y
    sta GLOBAL_SCOPE+1

    // Bind: call scope_set B0 times. Each call consumes the (name, value)
    // pair on top — pushes were name-then-value, so RS top = value, slot 1
    // = name, exactly what scope_set expects.
_llp_s_bind_loop:
    lda B0
    beq _llp_s_bind_done
    jsr scope_set
    dec B0
    jmp _llp_s_bind_loop
_llp_s_bind_done:

    // If the call was via `obj.method(...)`, bind `me` → obj. me is at RS
    // slot 2 (slot 0 = new, slot 1 = old, slot 2 = me, slot 3 = LHS).
    rs_peek_at(W0, 2)
    lda W0
    ora W0+1
    beq _llp_s_no_me                // me == 0 → not a method call
    rs_push_const(STR_ME)
    rs_push(W0)
    jsr scope_set
_llp_s_no_me:

    // Save outer lexer state onto FS (28 bytes).
    jsr lexer_save

    // Re-init lexer on the body string. RS state at this point is
    // [LHS, me, old, new] — slot 0 (top) = new, slot 1 = old, slot 2 = me,
    // slot 3 = LHS. Push a copy of LHS as the new source root.
    rs_peek_at(W0, 3)
    rs_push(W0)                     // RS: [LHS, me, old, new, body_src]
    jsr lexer_init                  // doesn't consume; body_src stays rooted

    // Default RV = NONE (in case body has no return).
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1

_llp_s_stmt_loop:
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    beq _llp_s_advance
    cmp #TK_INDENT
    beq _llp_s_advance
    cmp #TK_DEDENT
    beq _llp_s_advance
    cmp #TK_EOF
    beq _llp_s_done

    jsr parser_stmt                 // RV = stmt result

    // If RV is TYPE_CTRL with payload (= return), extract value and exit.
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_CTRL
    bne _llp_s_stmt_loop

    // Determine kind via O_LEN: 0 = break/continue (panic — not in a loop);
    // 2 = return (extract payload).
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_LEN
    lda (W2),y
    cmp #2
    beq _llp_s_extract_return
    // Stray break/continue inside a function body — panic.
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler

_llp_s_extract_return:
    // Read the value handle from O_HEADER+0..1.
    ldy #O_HEADER
    lda (W2),y
    sta W3
    iny
    lda (W2),y
    sta W3+1
    lda W3
    sta RV
    lda W3+1
    sta RV+1
    jmp _llp_s_done

_llp_s_advance:
    jsr lexer_next
    jmp _llp_s_stmt_loop

_llp_s_done:
    // Pop body source handle, restore outer lexer.
    rs_drop(1)                       // pop body_src (was rooting source)
    jsr lexer_restore                // pops 28 bytes from FS

    // Pop new_scope, then old_scope into GLOBAL_SCOPE.
    rs_drop(1)                       // discard new_scope
    rs_pop(W0)                       // W0 = old_scope
    lda W0
    sta GLOBAL_SCOPE
    lda W0+1
    sta GLOBAL_SCOPE+1

    jmp postamble                    // postamble cleans LHS off RS

// -----------------------------------------------------------------------------
// led_lbrack — subscription:
//   `a[i]`           read    → RV = element
//   `a[i] = value`   assign  → mutates a; RV = NONE
// Dispatch on LHS type for both:
//   LIST / TUPLE → integer index (list_set / array_get)
//   DICT         → key
// -----------------------------------------------------------------------------
led_lbrack:
    preamble_args(1, 0)               // LHS on RS
    jsr lexer_next                    // consume '['
    lda #0
    sta B7
    jsr expression                    // RV = index/start

    // Slice form: `a[start:stop]`?
    lda LEX_TOKEN_KIND
    cmp #TK_COLON
    bne _llb_no_slice
    jmp _llb_slice
_llb_no_slice:

    lda #TK_RBRACK
    jsr lexer_advance                 // consume ']'

    // Check for assignment.
    lda LEX_TOKEN_KIND
    cmp #TK_ASSIGN
    bne !skip+
    jmp _llb_assign
!skip:

    rs_peek(W0)                       // W0 = container handle
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_DICT
    bne !skip+
    jmp _llb_dict
!skip:
    cmp #TYPE_STR
    bne !skip+
    jmp _llb_str_get
!skip:

    // LIST / TUPLE — extract index byte from int handle in RV.
    lda RV
    sta W1
    lda RV+1
    sta W1+1
    ldy #H_PTR
    lda (W1),y
    sta W2
    iny
    lda (W1),y
    sta W2+1
    ldy #O_HEADER
    lda (W2),y                        // A = raw index byte
    // Normalize: if bit 7 set, A += container.O_LEN low byte (Python `a[-1]`).
    bpl _llb_idx_pos
    sta B6
    rs_peek(W0)
    jsr deref_W0_to_W2
    clc
    adc B6
_llb_idx_pos:
    sta W3
    lda #0
    sta W3+1
    fs_push(W3)                       // index goes on FS as a word
    jsr array_get                     // consumes RS+FS args; RV = element
    jmp postamble

_llb_dict:
    // Dict subscript: walk prototype chain (matches `obj.attr` semantics and
    // Admiral's `eval_subscription_dict` → scope_get).
    rs_push(RV)
    jsr dict_get_proto
    jmp postamble

_llb_str_get:
    // String subscript: read 1 byte at the (possibly-negative) index, alloc
    // a fresh 1-char TYPE_STR with that byte. Mirrors stmt_for's str path.
    lda RV
    sta W1
    lda RV+1
    sta W1+1
    ldy #H_PTR
    lda (W1),y
    sta W2
    iny
    lda (W1),y
    sta W2+1
    ldy #O_HEADER
    lda (W2),y                        // A = raw index byte
    bpl _llb_str_idx_pos
    sta B6
    rs_peek(W0)
    jsr deref_W0_to_W2
    clc
    adc B6
_llb_str_idx_pos:
    sta B5                            // B5 = effective index

    // Alloc 1-byte TYPE_STR.
    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                         // RV = new 1-byte STR

    // Re-deref container after alloc (GC may have moved it).
    rs_peek(W0)
    jsr deref_W0_to_W2                // W2 = me payload
    ldy B5
    lda (W2),y
    sta B5                            // stash byte (W2 about to be overwritten)

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

// Subscript assignment: `a[i] = value`. RS at entry: [container]; RV = index.
// Push index on RS (= [container, index]), parse RHS, dispatch on container.
_llb_assign:
    rs_push(RV)                       // RS: [container, index]
    jsr lexer_next                    // consume `=`
    lda #0
    sta B7
    jsr expression                    // RV = value
    rs_push(RV)                       // RS: [container, index, value]

    rs_peek_at(W0, 2)                 // W0 = container
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_DICT
    bne !next+
    jmp _llb_assign_dict
!next:
    cmp #TYPE_LIST
    bne !next+
    jmp _llb_assign_list
!next:
    // STR / TUPLE / other → immutable; reject.
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_llb_assign_list:
    // LIST: list_set wants RS [container, child], FS [index_word].
    rs_pop(W1)                        // W1 = value
    rs_pop(W0)                        // W0 = index handle. RS: [container]
    // Extract index byte from int handle.
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1
    ldy #O_HEADER
    lda (W2),y                        // A = raw index byte
    // Normalize: if bit 7 set, A += container.O_LEN low byte.
    bpl _llba_idx_pos
    sta B6
    rs_peek(W0)
    jsr deref_W0_to_W2
    clc
    adc B6
_llba_idx_pos:
    sta W2
    lda #0
    sta W2+1
    fs_push(W2)
    rs_push(W1)                       // RS: [container, value]
    jsr list_set                      // consumes 2 RS + 1 FS

    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

_llb_assign_dict:
    // dict_set takes RS [dict, key, value] — exactly what we have.
    jsr dict_set
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

// Slice form: `a[start:stop]`. Entry: RS top = container, RV = start handle,
// `:` is the current token. Push start, parse stop, expect `]`, then fall
// through into the slice body — which runs in led_lbrack's frame (no nested
// preamble) and exits via led_lbrack's postamble.
//
// RS layout entering the body: [container (deeper), start, stop (top)].
// W/B regs are led_lbrack's scratch — free to clobber.
//
// Indices read the low byte of each int handle's payload. List/tuple slices
// with start ≥ 128 may overflow the 2*index byte offset; strings up to 255
// chars work because the index *is* the byte offset.
_llb_slice:
    rs_push(RV)                       // RS: [container, start]
    jsr lexer_next                    // consume ':'
    lda #0
    sta B7
    jsr expression                    // RV = stop
    rs_push(RV)                       // RS: [container, start, stop]
    lda #TK_RBRACK
    jsr lexer_advance                 // consume ']'

    // Read container length first — we need it for negative-index
    // normalization AND for stop clamping. Stash in B6 (overwritten by
    // new_len further down).
    rs_peek_at(W0, 2)
    jsr deref_W0_to_W2                // A = O_LEN low byte
    sta B6                            // B6 = container len (temporary)

    // B4 = start (normalize: if raw byte is negative, add len).
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    bpl _slh_start_pos
    clc
    adc B6
_slh_start_pos:
    sta B4

    // B5 = stop (normalize negative).
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    ldy #0
    lda (W2),y
    bpl _slh_stop_pos
    clc
    adc B6
_slh_stop_pos:
    sta B5

    // Clamp stop to len (B6).
    lda B5
    cmp B6
    bcc _slh_stop_ok
    lda B6
    sta B5
_slh_stop_ok:
    // Clamp start to stop.
    lda B4
    cmp B5
    bcc _slh_start_ok
    lda B5
    sta B4
_slh_start_ok:

    // B6 = new_len = stop - start
    sec
    lda B5
    sbc B4
    sta B6

    // B7 = original type tag
    rs_peek_at(W0, 2)
    ldy #H_TYPE
    lda (W0),y
    sta B7
    cmp #TYPE_STR
    bne _slh_lt_alloc

    // STR: allocate B6 raw bytes.
    lda B6
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                          // RV = new str; O_LEN already = B6
    jmp _slh_copy_bytes

_slh_lt_alloc:
    // LIST/TUPLE: allocate B6 zeroed handle slots.
    lda B6
    ldx #TYPE_LIST
    jsr _array_alloc_init              // RV = new list, O_LEN = B6, payload zeroed.

    // If original was TUPLE, mutate H_TYPE on the new handle so the result
    // is also a tuple.
    lda B7
    cmp #TYPE_TUPLE
    bne _slh_lt_after_type
    ldy #H_TYPE
    sta (RV),y
_slh_lt_after_type:
    // Convert element-counted offsets to byte-counted.
    asl B4                              // B4 = src byte offset = 2*start
    asl B6                              // B6 = byte count       = 2*new_len

_slh_copy_bytes:
    // src = container.H_PTR + O_HEADER + B4 (in W3).
    rs_peek_at(W0, 2)
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
    clc
    lda W3
    adc B4
    sta W3
    bcc !+
    inc W3+1
!:

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

    // Copy B6 bytes from (W3) to (W2). Backward loop ends when Y wraps below 0.
    ldy B6
    beq _slh_done
_slh_cb_loop:
    dey
    lda (W3),y
    sta (W2),y
    cpy #0
    bne _slh_cb_loop
_slh_done:
    jmp postamble

// Local trampoline so far-branches from nud_lbrack can reach _lh_recover.
_lh_recover_parser:
    jmp _lh_recover

// -----------------------------------------------------------------------------
// led_dot — `obj.attr` (read), `obj.attr = value` (assign), and the prefix
// of `obj.method(...)` (method call, via METHOD_RECEIVER side-channel).
//
// The next-token after the name disambiguates:
//   `=`  → attribute assignment: dict_set(obj, name, RHS); RV = NONE
//   `(`  → method-call prefix:   METHOD_RECEIVER = obj; RV = dict_get(obj, name)
//   else → property read:        RV = dict_get(obj, name)
//
// METHOD_RECEIVER is set only when `(` follows immediately, so it can't
// pollute unrelated later call sites.
// -----------------------------------------------------------------------------
led_dot:
    preamble_args(1, 0)             // LHS on RS = the dict
    jsr lexer_next                  // consume `.`

    lda LEX_TOKEN_KIND
    cmp #TK_NAME
    beq _ldot_have_name
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler
_ldot_have_name:
    jsr lexer_get_token_as_string   // RV = name TYPE_STR
    rs_push(RV)                     // RS: [..., dict, name]
    jsr lexer_next                  // consume name

    // Branch on the token following the name.
    lda LEX_TOKEN_KIND
    cmp #TK_ASSIGN
    bne !next+
    jmp _ldot_assign
!next:
    cmp #TK_LPAREN
    bne !next+
    jmp _ldot_method_prefix
!next:

    // Property read — walk prototype chain on miss.
    jsr dict_get_proto              // consumes 2; RV = value or NONE
    jmp postamble

_ldot_method_prefix:
    // Set METHOD_RECEIVER = obj (slot 1; name on top).
    rs_peek_at(W0, 1)
    lda W0
    sta METHOD_RECEIVER
    lda W0+1
    sta METHOD_RECEIVER+1

    // Dispatch by receiver type:
    //   TYPE_DICT  → user-defined methods come from the dict itself (existing
    //                prototype pattern); fall back to dict_methods table on miss.
    //   TYPE_STR   → str_methods table.
    //   TYPE_LIST/TUPLE → list_methods table.
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_DICT
    beq _ldot_dict_method
    cmp #TYPE_STR
    beq _ldot_str_method
    cmp #TYPE_LIST
    beq _ldot_list_method
    cmp #TYPE_TUPLE
    beq _ldot_list_method
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler

_ldot_dict_method:
    // User-dict-with-prototype-chain wins over built-ins. Walk the "_" chain
    // until we find the name, or fall back to dict_methods on full-chain miss.
    // RS: [..., dict, name]. dict_get_proto consumes both; we save name in W1
    // first so we can re-stage for _method_lookup if the chain misses.
    rs_peek(W1)                     // W1 = name (preserved across dict_get_proto)
    jsr dict_get_proto              // consumes 2; RV = value or NONE

    lda RV+1
    cmp #>NONE
    bne _ldot_dict_user_hit
    lda RV
    cmp #<NONE
    bne _ldot_dict_user_hit

    // Miss across whole chain: try built-in dict methods. _method_lookup
    // expects W1 = name — we restored that above (dict_get_proto's frame
    // saved/restored W1).
    lda #<dict_methods
    sta W0
    lda #>dict_methods
    sta W0+1
    jsr _method_lookup              // A = 1/0; RV = builtin handle on hit
    cmp #0
    beq _ldot_dict_no_method
    jmp postamble                   // RV = builtin handle

_ldot_dict_user_hit:
    jmp postamble                   // RV already holds the user-defined value

_ldot_dict_no_method:
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler

_ldot_str_method:
    lda #<str_methods
    sta W0
    lda #>str_methods
    sta W0+1
    jmp _ldot_table_method

_ldot_list_method:
    lda #<list_methods
    sta W0
    lda #>list_methods
    sta W0+1
_ldot_table_method:
    // RS top = name handle. _method_lookup expects W0=table, W1=name (ZP only).
    rs_pop(W1)                      // pop name; RS: [..., obj]
    jsr _method_lookup              // A = 1/0; RV = builtin handle on hit
    cmp #0
    bne _ldot_method_found
    lda #ERR_TYPE
    sta ERROR_CODE
    jmp error_handler
_ldot_method_found:
    jmp postamble                   // RV = method builtin handle

_ldot_assign:
    // Attribute assignment. dict_set takes [dict, key, value] on RS top.
    // We have [..., dict, name]; need to push value on top.
    jsr lexer_next                  // consume `=`
    lda #0
    sta B7
    jsr expression                  // RV = RHS value
    rs_push(RV)                     // RS: [..., dict, name, value]
    jsr dict_set                    // consumes 3 → applies in place

    // Assignment-as-expression returns NONE (matches Python; matches our
    // existing nud_name assignment convention).
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// nud_float — parse a TK_FLOAT_LIT span into a TYPE_FLOAT handle.
// Materializes the span as a TYPE_STR (via lexer_get_token_as_string), then
// delegates to str_to_float (which wraps BASIC ROM's FIN).
// -----------------------------------------------------------------------------
nud_float:
    preamble_args(0, 0)
    jsr lexer_get_token_as_string  // RV = TYPE_STR for the span
    rs_push(RV)                     // arg for str_to_float
    jsr str_to_float                // RV = TYPE_FLOAT
    jsr lexer_next                  // advance past the float token
    jmp postamble

// -----------------------------------------------------------------------------
// nud_name — TK_NAME prefix.
//   `name`         → scope_get(name) → value
//   `name = rhs`   → eval rhs; scope_set(name, rhs); return NONE
//
// Assignment is handled at the NUD level (rather than at parser_stmt) so
// statements like `x = 1 + 2` work without a separate statement-vs-
// expression switch — Python's ban on `(x = 5)` doesn't apply here yet.
// -----------------------------------------------------------------------------
nud_name:
    preamble_args(0, 0)

    // Materialize the name as a TYPE_STR. Push for rooting.
    jsr lexer_get_token_as_string  // RV = TYPE_STR for the identifier span
    rs_push(RV)                     // RS: [..., name]
    jsr lexer_next                  // advance past the name

    // Assignment / augmented assignment?
    lda LEX_TOKEN_KIND
    cmp #TK_ASSIGN
    beq _nname_assign
    cmp #TK_AUGASS_BASE
    bcc _nname_get
    cmp #TK_AUGASS_LAST + 1
    bcs _nname_get
    jmp _nname_augass

_nname_get:
    // Plain reference: scope_get consumes the name from RS, returns RV.
    jsr scope_get
    jmp postamble

_nname_assign:
    jsr lexer_next                  // consume `=`
    lda #0
    sta B7
    jsr expression                  // RV = RHS value
    rs_push(RV)                     // RS: [..., name, value]
    jsr scope_set                   // consumes 2 → side effect

    // Assignment-as-expression returns NONE (matches Python's `=` which is
    // a statement, but here we're an expression so we need *some* value).
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

// Augmented assignment: `x op= rhs` rewrites to `x = x op rhs`. We delegate
// to the matching `led_*` function via the augass_lo/hi tables — each
// led_* expects RS top = LHS and the current lexer token = the operator,
// so we leave the augass token in place, push the current value of x, and
// SMC-jsr into the right `led_op`. After it returns RV = result, store back
// into x via scope_set.
_nname_augass:
    rs_peek(W0)                     // duplicate name handle
    rs_push(W0)
    jsr scope_get                   // consumes the dup; RV = current x value

    rs_push(RV)                     // RS: [..., name, x_val]

    ldx LEX_TOKEN_KIND
    lda augass_lo - TK_AUGASS_BASE,x
    sta _nna_jsr+1
    lda augass_hi - TK_AUGASS_BASE,x
    sta _nna_jsr+2
_nna_jsr:
    jsr $0000                       // → led_plus / led_minus / etc.
                                    // led_op consumes x_val + the augass token
                                    // + the RHS span; returns RV = result.
    rs_push(RV)                     // RS: [..., name, result]
    jsr scope_set                   // consumes 2

    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// nud_str — parse a TK_STR span into a TYPE_STR handle via
// lexer_get_token_as_string. Note: escape sequences are NOT yet decoded
// (the materialized string contains literal `\n` / `\t` etc.). When we
// teach lexer_get_token_as_string to decode, this NUD inherits the upgrade.
// -----------------------------------------------------------------------------
nud_str:
    preamble_args(0, 0)
    jsr lexer_get_token_as_string  // RV = TYPE_STR handle
    jsr lexer_next                  // advance past the string token
    jmp postamble

// -----------------------------------------------------------------------------
// nud_recover / led_recover — fallback handler for token kinds with no
// registered NUD/LED. Panics with ERR_LEX (we share the lex panic for now).
// Stage 8 will distinguish PARSE errors from LEX errors when it grows a
// proper recovery story.
// -----------------------------------------------------------------------------
nud_recover:
led_recover:
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler

// -----------------------------------------------------------------------------
// Token-kind dispatch tables. Indexed by TK_* (0..127).
// Default rows: NUD/LED → recover, LBP = 0.
// Register entries via the macros below to keep the table source-of-truth
// inline and easy to scan.
//
// Layout: 76 entries × 7 bytes = 532 bytes total (including STD pair).
//
// Tables are written linearly using `.fill N, default` for runs of defaults
// and explicit `.byte` for per-kind exceptions. Kick Assembler can't patch
// already-emitted bytes via `* = addr`, so the entire table is built in one
// forward pass.
// -----------------------------------------------------------------------------
.const TK_TABLE_SIZE = $4C    // TK_PRINT + 1 = 76

// --- nud_lo / nud_hi ---------------------------------------------------------
// Active NUDs: literals (INT/HEX/BIN/STR/TRUE/FALSE/NONE), unary +/-,
// parenthesized expressions.
// Token-id contiguity: TK_INT=4..TK_NAME=9 (literals), TK_LPAREN=10,
// TK_PLUS=21, TK_MINUS=22, TK_TRUE=72, TK_FALSE=73, TK_NONE_KW=74.

// Macro for parallel lo/hi byte. Given a label `name`, expand to the
// matching low or high byte at table-build time. Simplifies long fills.
nud_lo:
    .fill TK_INT, <nud_recover                 // 0..3  EOF/NEWLINE/INDENT/DEDENT
    .byte <nud_int                              // 4  TK_INT
    .byte <nud_hex                              // 5  TK_HEX
    .byte <nud_bin                              // 6  TK_BIN
    .byte <nud_float                            // 7  TK_FLOAT_LIT
    .byte <nud_str                              // 8  TK_STR
    .byte <nud_name                             // 9  TK_NAME
    .byte <nud_lparen                           // 10 TK_LPAREN
    .byte <nud_recover                          // 11 TK_RPAREN
    .byte <nud_lbrack                           // 12 TK_LBRACK (list literal)
    .byte <nud_recover                          // 13 TK_RBRACK
    .byte <nud_lcurly                           // 14 TK_LCURLY (dict literal)
    .fill TK_PLUS - 15, <nud_recover            // 15..TK_PLUS-1
    .byte <nud_plus                             // 21 TK_PLUS
    .byte <nud_minus                            // 22 TK_MINUS
    .fill TK_TILDE - TK_MINUS - 1, <nud_recover // 23..32
    .byte <nud_tilde                            // 33 TK_TILDE
    .fill TK_NOT - TK_TILDE - 1, <nud_recover   // 34..69
    .byte <nud_not                              // TK_NOT (=$46 = 70)
    .byte <nud_recover                          // TK_IS — LED only
    .byte <nud_true                             // TK_TRUE
    .byte <nud_false                            // TK_FALSE
    .byte <nud_none                             // TK_NONE_KW
    .byte <nud_recover                          // TK_PRINT (statement only)

nud_hi:
    .fill TK_INT, >nud_recover
    .byte >nud_int
    .byte >nud_hex
    .byte >nud_bin
    .byte >nud_float
    .byte >nud_str
    .byte >nud_name
    .byte >nud_lparen
    .byte >nud_recover
    .byte >nud_lbrack
    .byte >nud_recover
    .byte >nud_lcurly
    .fill TK_PLUS - 15, >nud_recover
    .byte >nud_plus
    .byte >nud_minus
    .fill TK_TILDE - TK_MINUS - 1, >nud_recover
    .byte >nud_tilde
    .fill TK_NOT - TK_TILDE - 1, >nud_recover
    .byte >nud_not
    .byte >nud_recover
    .byte >nud_true
    .byte >nud_false
    .byte >nud_none
    .byte >nud_recover                          // TK_PRINT (statement only)

// --- led_lo / led_hi ---------------------------------------------------------
// Active LEDs: binary + - * / // %, comparisons < <= > >= == !=.
// Token IDs: TK_PLUS=21, TK_MINUS=22, TK_STAR=23, TK_SLASH=24, TK_DSLASH=25,
// TK_PERCENT=26; TK_LT=34, TK_LE=35, TK_GT=36, TK_GE=37, TK_EQ=38, TK_NEQ=39.
led_lo:
    .fill TK_LPAREN, <led_recover                  // 0..9
    .byte <led_lparen                              // 10 TK_LPAREN (call)
    .byte <led_recover                             // 11 TK_RPAREN
    .byte <led_lbrack                              // 12 TK_LBRACK (subscription)
    .byte <led_recover                             // 13 TK_RBRACK
    .byte <led_recover                             // 14 TK_LCURLY
    .byte <led_recover                             // 15 TK_RCURLY
    .byte <led_recover                             // 16 TK_COMMA
    .byte <led_recover                             // 17 TK_COLON
    .byte <led_recover                             // 18 TK_SEMICOLON
    .byte <led_dot                                 // 19 TK_DOT (attr access)
    .fill TK_PLUS - TK_DOT - 1, <led_recover       // 20..TK_PLUS-1
    .byte <led_plus                                // 21 TK_PLUS
    .byte <led_minus                               // 22 TK_MINUS
    .byte <led_star                                // 23 TK_STAR
    .byte <led_slash                               // 24 TK_SLASH
    .byte <led_dslash                              // 25 TK_DSLASH
    .byte <led_percent                             // 26 TK_PERCENT
    .byte <led_power                               // 27 TK_POWER
    .byte <led_lshift                              // 28 TK_LSHIFT
    .byte <led_rshift                              // 29 TK_RSHIFT
    .byte <led_amp                                 // 30 TK_AMP
    .byte <led_pipe                                // 31 TK_PIPE
    .byte <led_caret                               // 32 TK_CARET
    .byte <led_recover                             // 33 TK_TILDE (NUD only)
    .byte <led_lt                                  // 34 TK_LT
    .byte <led_le                                  // 35 TK_LE
    .byte <led_gt                                  // 36 TK_GT
    .byte <led_ge                                  // 37 TK_GE
    .byte <led_eq                                  // 38 TK_EQ
    .byte <led_neq                                 // 39 TK_NEQ
    .fill TK_IN - TK_NEQ - 1, <led_recover         // $28..$39
    .byte <led_in                                  // $3A TK_IN (binary `in`)
    .fill TK_AND - TK_IN - 1, <led_recover         // $3B..$43
    .byte <led_and                                 // $44 TK_AND
    .byte <led_or                                  // 69 TK_OR
    .byte <led_recover                             // 70 TK_NOT (NUD only)
    .byte <led_is                                  // 71 TK_IS
    .fill TK_TABLE_SIZE - TK_IS - 1, <led_recover

led_hi:
    .fill TK_LPAREN, >led_recover
    .byte >led_lparen
    .byte >led_recover
    .byte >led_lbrack
    .byte >led_recover
    .byte >led_recover
    .byte >led_recover
    .byte >led_recover
    .byte >led_recover
    .byte >led_recover
    .byte >led_dot                                 // 19 TK_DOT
    .fill TK_PLUS - TK_DOT - 1, >led_recover
    .byte >led_plus
    .byte >led_minus
    .byte >led_star
    .byte >led_slash
    .byte >led_dslash
    .byte >led_percent
    .byte >led_power
    .byte >led_lshift
    .byte >led_rshift
    .byte >led_amp
    .byte >led_pipe
    .byte >led_caret
    .byte >led_recover                             // 33 TK_TILDE
    .byte >led_lt
    .byte >led_le
    .byte >led_gt
    .byte >led_ge
    .byte >led_eq
    .byte >led_neq
    .fill TK_IN - TK_NEQ - 1, >led_recover
    .byte >led_in
    .fill TK_AND - TK_IN - 1, >led_recover
    .byte >led_and
    .byte >led_or
    .byte >led_recover
    .byte >led_is
    .fill TK_TABLE_SIZE - TK_IS - 1, >led_recover

// --- lbp_table ---------------------------------------------------------------
lbp_table:
    .fill TK_LPAREN, LBP_TERM
    .byte LBP_INDEX                                // TK_LPAREN (call)
    .byte LBP_TERM                                 // TK_RPAREN
    .byte LBP_INDEX                                // TK_LBRACK (subscription)
    .byte LBP_TERM                                 // TK_RBRACK
    .byte LBP_TERM                                 // TK_LCURLY
    .byte LBP_TERM                                 // TK_RCURLY
    .byte LBP_TERM                                 // TK_COMMA
    .byte LBP_TERM                                 // TK_COLON
    .byte LBP_TERM                                 // TK_SEMICOLON
    .byte LBP_INDEX                                // TK_DOT (attr access)
    .fill TK_PLUS - TK_DOT - 1, LBP_TERM
    .byte LBP_PLUS                                 // TK_PLUS
    .byte LBP_PLUS                                 // TK_MINUS
    .byte LBP_TIMES                                // TK_STAR
    .byte LBP_TIMES                                // TK_SLASH
    .byte LBP_TIMES                                // TK_DSLASH
    .byte LBP_TIMES                                // TK_PERCENT
    .byte LBP_POWER                                // TK_POWER
    .byte LBP_SHIFT                                // 28 TK_LSHIFT
    .byte LBP_SHIFT                                // 29 TK_RSHIFT
    .byte LBP_BITAND                               // 30 TK_AMP
    .byte LBP_BITOR                                // 31 TK_PIPE
    .byte LBP_BITXOR                               // 32 TK_CARET
    .byte LBP_TERM                                 // 33 TK_TILDE
    .byte LBP_CMP                                  // TK_LT
    .byte LBP_CMP                                  // TK_LE
    .byte LBP_CMP                                  // TK_GT
    .byte LBP_CMP                                  // TK_GE
    .byte LBP_CMP                                  // TK_EQ
    .byte LBP_CMP                                  // TK_NEQ
    .fill TK_IN - TK_NEQ - 1, LBP_TERM             // $28..$39
    .byte LBP_CMP                                  // $3A TK_IN — binary membership
    .fill TK_AND - TK_IN - 1, LBP_TERM
    .byte LBP_AND                                  // $44 TK_AND
    .byte LBP_OR                                   // TK_OR
    .byte LBP_TERM                                 // TK_NOT (NUD only)
    .byte LBP_CMP                                  // TK_IS
    .fill TK_TABLE_SIZE - TK_IS - 1, LBP_TERM

// --- std_lo / std_hi (statement dispatch) -----------------------------------
// Indexed by TK_*. Default = `stmt_expression - 1` (parser_stmt's rts trick
// adds 1). Specific keywords override:
//   TK_IF, TK_WHILE, TK_FOR, TK_BREAK, TK_CONTINUE, TK_PASS, TK_PRINT.
//
// Token-id positions (for the layout below):
//   TK_IF=$35  TK_ELIF=$36  TK_ELSE=$37  TK_WHILE=$38  TK_FOR=$39  TK_IN=$3A
//   TK_BREAK=$3B  TK_CONTINUE=$3C  TK_PASS=$3D  ...  TK_PRINT=$4B

// --- augass_lo / augass_hi --------------------------------------------------
// Maps a TK_AUGASS_BASE..TK_AUGASS_LAST token to the matching `led_*`
// handler. Indexed by `tk - TK_AUGASS_BASE`; nud_name uses these to dispatch
// `x op= rhs` through the same code path as the binary `op`.
augass_lo:
    .byte <led_plus     // $29 TK_PLUSEQ
    .byte <led_minus    // $2A TK_MINUSEQ
    .byte <led_star     // $2B TK_STAREQ
    .byte <led_slash    // $2C TK_SLASHEQ
    .byte <led_dslash   // $2D TK_DSLASHEQ
    .byte <led_percent  // $2E TK_PERCENTEQ
    .byte <led_power    // $2F TK_POWEREQ
    .byte <led_lshift   // $30 TK_LSHIFTEQ
    .byte <led_rshift   // $31 TK_RSHIFTEQ
    .byte <led_amp      // $32 TK_AMPEQ
    .byte <led_pipe     // $33 TK_PIPEEQ
    .byte <led_caret    // $34 TK_CARETEQ
augass_hi:
    .byte >led_plus
    .byte >led_minus
    .byte >led_star
    .byte >led_slash
    .byte >led_dslash
    .byte >led_percent
    .byte >led_power
    .byte >led_lshift
    .byte >led_rshift
    .byte >led_amp
    .byte >led_pipe
    .byte >led_caret

std_lo:
    .fill TK_IF, <(stmt_expression - 1)            // 0..$34
    .byte <(stmt_if - 1)                            // $35 TK_IF
    .byte <(stmt_expression - 1)                    // $36 TK_ELIF
    .byte <(stmt_expression - 1)                    // $37 TK_ELSE
    .byte <(stmt_while - 1)                         // $38 TK_WHILE
    .byte <(stmt_for - 1)                           // $39 TK_FOR
    .byte <(stmt_expression - 1)                    // $3A TK_IN
    .byte <(stmt_break - 1)                         // $3B TK_BREAK
    .byte <(stmt_continue - 1)                      // $3C TK_CONTINUE
    .byte <(stmt_pass - 1)                          // $3D TK_PASS
    .byte <(stmt_return - 1)                        // $3E TK_RETURN
    .fill TK_DEL - TK_RETURN - 1, <(stmt_expression - 1)   // $3F..$42 (try/except/finally/raise)
    .byte <(stmt_del - 1)                                  // $43 TK_DEL
    .fill TK_PRINT - TK_DEL - 1, <(stmt_expression - 1)    // $44..$4A
    .byte <(stmt_print - 1)                         // $4B TK_PRINT

std_hi:
    .fill TK_IF, >(stmt_expression - 1)
    .byte >(stmt_if - 1)
    .byte >(stmt_expression - 1)
    .byte >(stmt_expression - 1)
    .byte >(stmt_while - 1)
    .byte >(stmt_for - 1)
    .byte >(stmt_expression - 1)
    .byte >(stmt_break - 1)
    .byte >(stmt_continue - 1)
    .byte >(stmt_pass - 1)
    .byte >(stmt_return - 1)
    .fill TK_DEL - TK_RETURN - 1, >(stmt_expression - 1)
    .byte >(stmt_del - 1)
    .fill TK_PRINT - TK_DEL - 1, >(stmt_expression - 1)
    .byte >(stmt_print - 1)
