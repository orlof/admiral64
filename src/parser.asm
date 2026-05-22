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
#import "int_util.asm"

// -----------------------------------------------------------------------------
// LBP precedence levels. Higher binds tighter. Levels are spaced so future
// operator additions can slot in without renumbering. Numeric values match
// general Python precedence ordering.
// -----------------------------------------------------------------------------
.const LBP_TERM    = 0       // EOF, NEWLINE, RPAREN, etc. — no infix binding
.const LBP_ASSIGN  = $01     // = and augmented (right-assoc, lowest binder)
.const LBP_COMMA   = $02     // tuple constructor — binds tighter than `=` so
                             // `a, b = c, d` parses as `(a, b) = (c, d)`
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
// Sets up a fresh root scope (TYPE_DICT) at start. Both source and scope
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
    // root. Cache the handle in BOTH CURRENT_SCOPE (current) and ROOT_SCOPE
    // (immutable parent target). Function calls below will swap CURRENT_SCOPE
    // but always use ROOT_SCOPE as the new local scope's parent.
    jsr dict_alloc                // RV = empty dict
    rs_push(RV)                   // RS: [source, root_scope]
    lda RV
    sta CURRENT_SCOPE
    sta ROOT_SCOPE
    lda RV+1
    sta CURRENT_SCOPE+1
    sta ROOT_SCOPE+1

    // Method-call side channel starts cleared.
    lda #0
    sta METHOD_RECEIVER
    sta METHOD_RECEIVER+1

    // Free-function builtins are resolved through `try_builtin_lookup`'s
    // hard-coded name table (Admiral-style). No scope registration needed.

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
// parser_exec — like parser_eval, but reuses an already-set-up scope owned
// by the caller. Used by the REPL so user-defined names persist across
// successive `print x` / `x = …` turns.
//
// Caller contract (REPL):
//   1. Has allocated a TYPE_DICT and rs_push'd it as a permanent root.
//   2. Has set CURRENT_SCOPE / ROOT_SCOPE to that handle.
//   3. rs_push'd the source TYPE_STR for this turn.
//   4. jsr parser_exec.
//
// On return, the source has been consumed; the scope handle is still on RS
// (rooted by the REPL across turns). RV holds the last statement's value or
// NONE.
// V4' wrapper.
// -----------------------------------------------------------------------------
parser_exec:
    preamble_args(1, 0)

    jsr lexer_init                  // reads RS top = source

    lda #0
    sta METHOD_RECEIVER
    sta METHOD_RECEIVER+1

    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1

_pex_loop:
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    beq _pex_advance
    cmp #TK_INDENT
    beq _pex_advance
    cmp #TK_DEDENT
    beq _pex_advance
    cmp #TK_EOF
    beq _pex_done

    jsr parser_stmt
    jmp _pex_loop

_pex_advance:
    jsr lexer_next
    jmp _pex_loop

_pex_done:
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
    // Run/Stop polled at every statement boundary by reading STOP_REQUESTED,
    // which the IRQ handler updates each ~16 ms by directly polling CIA1
    // PRB row 7 bit 7. Bit 7 set in STOP_REQUESTED → user is holding RUN/
    // STOP → ERR_BREAK lands in the panic chain and the REPL recovers via
    // the existing snapshot. Long inner loops in builtins won't break here
    // — they don't re-enter parser_stmt — but tight user-level loops do
    // every iteration.
    //
    // The "bit 7 set = break" encoding is deliberate: py65 has RAM default
    // $00 at STOP_REQUESTED so tests never see a false break despite never
    // running our IRQ.
    bit STOP_REQUESTED
    bpl !nostop+
    jmp panic_break
!nostop:
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
    rs_push(RV)
    jsr eval                        // force lazy NAME/REF/SUB/TUPLE → value
    jmp postamble

// -----------------------------------------------------------------------------
// stmt_pass — `pass` keyword. Consume token; return NONE.
// -----------------------------------------------------------------------------
stmt_pass:
    preamble_args(0, 0)
    jsr lexer_next
    jmp postamble_return_none

// -----------------------------------------------------------------------------
// stmt_break — `break` keyword. Consume token; return CTRL_BREAK.
// -----------------------------------------------------------------------------
stmt_break:
    preamble_args(0, 0)
    jsr lexer_next
    lda #<CTRL_BREAK
    ldx #>CTRL_BREAK
    jmp postamble_set_rv_ax

// -----------------------------------------------------------------------------
// stmt_continue — `continue` keyword. Consume token; return CTRL_CONTINUE.
// -----------------------------------------------------------------------------
stmt_continue:
    preamble_args(0, 0)
    jsr lexer_next
    lda #<CTRL_CONTINUE
    ldx #>CTRL_CONTINUE
    jmp postamble_set_rv_ax

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
    jsr expression                  // RV = lazy return value
    rs_push(RV)
    jsr eval                        // force to a concrete value
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
// stmt_del — `del NAME` or `del NAME[expr]`.
//   Plain `del NAME`: removes the binding from the current scope dict
//   (CURRENT_SCOPE). Subsequent reads of NAME walk the parent chain.
//   `del NAME[expr]`: scope_get(NAME) → container, then remove `expr` from
//   it. LIST → array_del at integer index. DICT → binary-search the key,
//   then array_del. Other types (TUPLE etc.) panic ERR_TYPE.
// Missing key/name → ERR_LEX.
// V4' wrapper. RV = NONE on success.
// -----------------------------------------------------------------------------
stmt_del:
    preamble_args(0, 0)
    jsr lexer_next                  // consume `del`

    lda LEX_TOKEN_KIND
    cmp #TK_NAME
    beq _sd_have_name
    jmp panic_lex
_sd_have_name:
    jsr lexer_get_token_as_string   // RV = name TYPE_STR
    rs_push(RV)                     // RS: [name]
    jsr lexer_next                  // consume name

    // Branch: subscript form `del NAME[...]` or plain `del NAME`?
    lda LEX_TOKEN_KIND
    cmp #TK_LBRACK
    beq _sd_subscript

    // Plain `del NAME`: bin-search CURRENT_SCOPE for the name handle, then
    // array_del that slot. Name is currently at RS top.
    rs_pop(W1)                      // W1 = name; RS: []
    rs_push(CURRENT_SCOPE)           // RS: [scope_dict]
    rs_peek(W0)                     // W0 = scope_dict
    jsr _dict_bin_search            // A = hit/miss; RV = index on hit
    cmp #0
    bne _sd_name_remove
    // Miss → name not bound in current scope.
    jmp panic_lex
_sd_name_remove:
    lda RV
    sta W2
    lda RV+1
    sta W2+1
    fs_push(W2)
    jsr array_del                   // consumes scope_dict + index
    jmp _sd_done

_sd_subscript:
    jsr scope_get                   // consumes name; RV = container

    lda #TK_LBRACK
    jsr lexer_advance               // consume `[`

    rs_push(RV)                     // RS: [container]
    lda #LBP_COMMA
    sta B7
    jsr expression                  // RV = lazy index/key
    rs_push(RV)
    jsr eval                        // force index/key

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
    jmp panic_type

_sd_list_del:
    // Inline int index (RV) → signed 16-bit B5:B6; negative → add O_LEN.
    lda RV
    sta W1
    lda RV+1
    sta W1+1
    jsr int_index_w1_b5b6
_sld_idx_check:
    lda B6
    bpl _sld_idx_pos
    rs_peek(W0)                      // container
    jsr deref_W0_to_W2               // A:X = container O_LEN word
    clc
    adc B5
    sta B5
    txa
    adc B6
    sta B6
_sld_idx_pos:
    lda B5
    sta W2
    lda B6
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
    jmp panic_lex
_sd_dict_remove:
    lda RV
    sta W2
    lda RV+1
    sta W2+1
    fs_push(W2)
    jsr array_del                   // consumes dict + index
    // fall through

_sd_done:
    jmp postamble_return_none

// -----------------------------------------------------------------------------
// parser_suite — parse the body of a block.
//   Block form: INDENT stmt* DEDENT — runs each statement until matching
//   DEDENT (or EOF), consumes the DEDENT.
//   Inline form: a single simple statement on the same line as the header
//   colon, e.g. `for x in [1,2,3]: print x`. Caller has consumed the `:`
//   (and any newline if a block follows). If the next token is not INDENT
//   we take the inline path — parse one statement and return.
// V4' wrapper. RV is the value of the LAST statement in the suite (mostly
// for symmetry — control-flow contexts ignore it).
// -----------------------------------------------------------------------------
parser_suite:
    preamble_args(0, 0)
    lda LEX_TOKEN_KIND
    cmp #TK_INDENT
    beq _psu_block
    // Inline body — one simple statement, then return.
    jsr parser_stmt
    jmp postamble

_psu_block:
    jsr lexer_next                  // consume INDENT

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
    // Inline body: no INDENT yet → eat tokens up to (but not including) the
    // statement-ending NEWLINE / EOF, leaving the lexer where it would be
    // after a normal parser_stmt run on the inline body.
    lda LEX_TOKEN_KIND
    cmp #TK_INDENT
    beq _ssu_block

_ssu_inline_loop:
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    beq _ssu_done
    cmp #TK_EOF
    beq _ssu_done
    jsr lexer_next
    jmp _ssu_inline_loop

_ssu_block:
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
    jsr expression                  // RV = lazy condition
    rs_push(RV)
    jsr eval                        // RV = condition value

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
    jsr expression                  // RV = lazy cond
    rs_push(RV)
    jsr eval                        // RV = cond value

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
    jmp postamble_return_none

// -----------------------------------------------------------------------------
// stmt_for — `for VAR in EXPR: body`. EXPR may be LIST / TUPLE / DICT.
// LIST/TUPLE iterate by integer index 0..len-1, binding VAR to each element.
// DICT iterates over keys (Python convention): for each entry tuple
// [key, value] in the payload, VAR is bound to `key`.
//
// RS layout maintained throughout: [..., var_name, container]. Both are
// rooted (var_name is a TYPE_STR, container is a LIST / TUPLE / DICT).
//
// Index counter is 16-bit in B5 (lo) + B7 (hi). Containers can have up to
// 65535 elements, and `range(N)` for any N>255 is a common case.
// B4 selects iteration mode (0=LIST/TUPLE, 1=DICT, 2=STR).
// B6 is a "body_entered" flag (1 once parser_suite has run, so _sfor_done
// knows whether the lexer is past the body or still at its start).
// -----------------------------------------------------------------------------
stmt_for:
    preamble_args(0, 0)
    jsr lexer_next                  // consume `for`

    jsr parse_for_target            // RV = TYPE_NAME or TYPE_TUPLE of targets
    rs_push(RV)                     // RS: [..., target]

_sfor_target_ready:
    lda #TK_IN
    jsr lexer_advance               // consume `in`

    // Container expression.
    lda #0
    sta B7
    jsr expression                  // RV = lazy container
    rs_push(RV)
    jsr eval                        // RV = forced container value
    rs_push(RV)                     // RS top = container

    // Detect container kind for the loop body. B4 selects iter mode:
    //   0 = LIST/TUPLE — element is the slot value.
    //   1 = DICT       — element is the (key, value) entry tuple (bind whole).
    //   2 = STR        — fetch payload byte and alloc a fresh 1-char STR.
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

    // Counters: B5:B7 = 16-bit index, B6 = "body_entered" flag (so we know
    // whether the lexer is currently past-body vs at-body-start when exiting).
    lda #0
    sta B5
    sta B6
    sta B7

_sfor_loop:
    // Bounds check: if index >= len(container), exit. Read O_LEN as 16-bit
    // directly from the container (array_len would only return the low byte
    // and stop us at iteration 244 for range(500)).
    rs_peek_at(W0, 0)               // W0 = container handle
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1                        // W2 = payload ptr
    ldy #O_LEN+1
    lda (W2),y                      // A = O_LEN hi
    cmp B7
    bcc !exit+                      // hi(len) < hi(idx) → exit
    bne _sfor_in_bounds             // hi(len) > hi(idx) → continue
    ldy #O_LEN
    lda (W2),y                      // A = O_LEN lo
    cmp B5
    bcc !exit+                      // lo(len) < lo(idx) → exit
    bne _sfor_in_bounds             // lo(len) > lo(idx) → continue
!exit:
    jmp _sfor_done                  // len == idx → exit
_sfor_in_bounds:

    // Dispatch on container kind (B4).
    lda B4
    cmp #2
    beq _sfor_str_iter

    // LIST / TUPLE / DICT path: fetch container[index] via array_get.
    // For dicts, the element is the (key, value) entry tuple — `assign` will
    // unpack it into a tuple-LHS target or bind it whole to a single name.
    rs_peek_at(W0, 0)
    rs_push(W0)
    lda B5
    sta W2
    lda B7
    sta W2+1
    fs_push(W2)                     // 16-bit index on FS
    jsr array_get                   // RV = element
    jmp _sfor_bind

_sfor_str_iter:
    // String iteration: fetch container.payload[B7:B5] (one byte), then alloc
    // a fresh 1-char TYPE_STR with that byte as the payload. The container is
    // RS-rooted so it survives any GC the alloc triggers. W2 is mutated as a
    // scratch ptr; not reused after the read.
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2              // W2 = container payload
    clc
    lda W2
    adc B5
    sta W2
    lda W2+1
    adc B7
    sta W2+1
    ldy #0
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

    // assign(target, RV) — handles single-name (TYPE_NAME → scope_set) and
    // tuple-LHS (TYPE_TUPLE → recursive arity-checked unpack) uniformly.
    // Target is at RS slot 1 (container is at slot 0).
    rs_peek_at(W0, 1)               // W0 = target (TYPE_NAME or TYPE_TUPLE)
    rs_push(W0)
    rs_push(RV)
    jsr assign                      // consumes 2

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
    bne !next+
    inc B7
!next:
    jmp _sfor_loop

_sfor_done:
    jsr lexer_drop                  // pop the active save
    lda B6
    bne _sfor_done_post_body        // we entered body → lexer past body
    jsr skip_suite                  // never entered → still at body start

_sfor_done_post_body:
    jmp postamble_return_none

// -----------------------------------------------------------------------------
// parse_for_target — parse a `for` loop's lvalue target. Recognizes
// comma-separated atoms; each atom is either TK_NAME or `( inner )`.
// Returns RV = TYPE_NAME (single) or TYPE_TUPLE (multi). Stops at TK_IN /
// TK_RPAREN / TK_COLON. Cannot reuse `expression` because TK_IN binds as a
// LED (membership test) at any usable rbp.
// V4'.
// -----------------------------------------------------------------------------
parse_for_target:
    preamble_args(0, 0)

    jsr parse_for_atom              // RV = first atom (NAME or nested TUPLE)
    rs_push(RV)
    lda #1
    sta B0                          // B0 = atom count

_pft_loop:
    lda LEX_TOKEN_KIND
    cmp #TK_COMMA
    bne _pft_done
    jsr lexer_next                  // consume `,`
    jsr parse_for_atom
    rs_push(RV)
    inc B0
    jmp _pft_loop

_pft_done:
    lda B0
    cmp #1
    bne _pft_build_tuple

    // Single atom — RV already holds it (last assignment from parse_for_atom).
    jmp postamble_peek_rv           // re-load (defensive: postamble preserves RV
                                    //  but rs_pop would shift RSP)

_pft_build_tuple:
    // Allocate a tuple of size B0 with the atoms as payload.
    lda B0
    ldx #TYPE_TUPLE
    jsr _array_alloc_init           // RV = tuple, payload zeroed
    rs_push(RV)                     // root for the fill loop
    lda RV
    sta W0
    lda RV+1
    sta W0+1

    lda #0
    sta B1
_pft_pack:
    lda B1
    cmp B0
    beq _pft_packed
    sec
    lda B0
    sbc B1                          // depth = N - i (tuple at depth 0)
    asl
    tay
    jsr rs_peek_at_w1               // W1 = atom[i]
    lda B1
    jsr tuple_set_leaf
    inc B1
    jmp _pft_pack
_pft_packed:
    // RV still = tuple; postamble preserves it and sweeps RS roots.
    jmp postamble

// -----------------------------------------------------------------------------
// parse_for_atom — single target atom: TK_NAME → TYPE_NAME, or `( inner )`
// → recursive parse_for_target inside parens.
// V4'.
// -----------------------------------------------------------------------------
parse_for_atom:
    preamble_args(0, 0)

    lda LEX_TOKEN_KIND
    cmp #TK_NAME
    beq _pfa_name
    cmp #TK_LPAREN
    beq _pfa_paren
    jmp _lh_recover

_pfa_name:
    jsr lexer_get_token_as_string   // RV = TYPE_STR (mutate to TYPE_NAME below)
    ldy #H_TYPE
    lda #TYPE_NAME
    sta (RV),y
    jmp _lex_next_post

_pfa_paren:
    jsr lexer_next                  // consume `(`
    jsr parse_for_target            // RV = inner target
    lda #TK_RPAREN
    jsr lexer_advance               // consume `)`
    jmp postamble

// -----------------------------------------------------------------------------
// stmt_cls — `cls` keyword. Clears the screen and homes the cursor; returns
// NONE. Same effect as `cls()` but without the no-op parens — chosen as a
// statement keyword (like `print`) because it's the most-used REPL command.
// -----------------------------------------------------------------------------
stmt_cls:
    preamble_args(0, 0)
    jsr lexer_next                  // consume `cls`
    jsr screen_clear
    jmp postamble_return_none

// -----------------------------------------------------------------------------
// stmt_print — `print [expr [, expr]*]`. Evaluates each comma-separated
// argument left-to-right, prints them with a single space between, then
// emits a trailing newline. Returns NONE. Mirrors DCPU's `std_print` shape
// (`print 1, 2` → "1 2") rather than printing the comma-built tuple's repr.
//
// Top-level commas are kept as loop separators by passing rbp = LBP_COMMA
// to expression(), which makes the comma LED stop binding (lbp == rbp →
// done). Parenthesized tuples like `print (1, 2)` are unaffected: nud_lparen
// handles the inner commas itself, so expression() returns one tuple value
// that we render via the normal tuple repr path.
// -----------------------------------------------------------------------------
stmt_print:
    preamble_args(0, 0)
    jsr lexer_next                  // consume `print`

_sp_loop:
    // End-of-statement → emit trailing newline and exit.
    lda LEX_TOKEN_KIND
    cmp #TK_NEWLINE
    beq _sp_done
    cmp #TK_EOF
    beq _sp_done

    // Parse + print one argument.
    lda #LBP_COMMA
    sta B7
    jsr expression                  // RV = lazy value
    rs_push(RV)
    jsr eval                        // RV = forced value
    rs_push(RV)
    jsr print_value                 // consumes 1 arg

    // Comma → emit a separator space and parse the next argument.
    lda LEX_TOKEN_KIND
    cmp #TK_COMMA
    bne _sp_done
    jsr lexer_next                  // consume `,`
    lda #$20                         // PETSCII space
    jsr screen_put_char
    jmp _sp_loop

_sp_done:
    lda #$0D
    jsr screen_put_char             // newline
    jmp postamble_return_none

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
    jmp panic_type

// -----------------------------------------------------------------------------
// cast_common_number_type_optional — like cast_common_number_type, but
// returns without modification (and without panicking) when either operand
// is non-numeric. Used by `<` `<=` `>` `>=` `==` `!=`: val_cmp can compare
// any pair of types (falling back to type-tag order on mismatch and to
// element-wise val_cmp on tuples/lists/dicts), so we only need the
// int↔float coercion when both sides are actually numeric.
// -----------------------------------------------------------------------------
cast_common_number_type_optional:
    rs_peek_at(W0, 1)
    rs_peek_at(W1, 0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq _ccnto_a_num
    cmp #TYPE_BOOL
    beq _ccnto_a_num
    cmp #TYPE_FLOAT
    beq _ccnto_a_num
    rts                          // a non-numeric → no cast, no panic
_ccnto_a_num:
    lda (W1),y
    cmp #TYPE_INT
    beq _ccnto_delegate
    cmp #TYPE_BOOL
    beq _ccnto_delegate
    cmp #TYPE_FLOAT
    beq _ccnto_delegate
    rts                          // a numeric, b non-numeric → leave as-is
_ccnto_delegate:
    jmp cast_common_number_type

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
    // Force LHS (lazy NAME/REF/SUB → value). eval is idempotent on values.
    jsr eval                          // consumes RS top (lazy LHS), RV = value
    rs_push(RV)                       // RS: [..., LHS_v]

    ldx LEX_TOKEN_KIND
    lda lbp_table,x
    sta B7                            // rbp for left-associative recursion
    jsr lexer_next                    // consume the operator token
    jsr expression                    // RV = RHS lazy handle (W/B preserved by V4')

    rs_push(RV)
    jsr eval                          // RV = RHS value
    rs_push(RV)                       // RS: [..., LHS_v, RHS_v]
    rts

// -----------------------------------------------------------------------------
// infixr_eval — right-associative variant. Parses the RHS at LBP - 1.
// Used by `**` (power) when it lands.
// -----------------------------------------------------------------------------
infixr_eval:
    jsr eval
    rs_push(RV)

    ldx LEX_TOKEN_KIND
    lda lbp_table,x
    sec
    sbc #1
    sta B7
    jsr lexer_next
    jsr expression

    rs_push(RV)
    jsr eval
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
    jsr cast_common_number_type_optional  // promote int↔float; pass through others
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
    jmp _lex_next_post

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
    jmp _lex_next_post

// -----------------------------------------------------------------------------
// Binary arithmetic LEDs — each is one macro line. infix_eval reads the
// per-token LBP, parses+evaluates the RHS, and leaves [LHS, RHS] on RS.
// `/` and `//` both currently map to integer division; when TYPE_FLOAT
// participates, `/` will switch to float division.
// -----------------------------------------------------------------------------
// led_plus dispatches by operand types:
//   - If EITHER side is STR, the result is STR concatenation. The non-STR
//     side (if any) is auto-coerced via builtin_str — this is the "anything
//     + str → str(anything) ++ str" rule, deliberately Option B (BASIC-style)
//     to keep user code short on a 64K box. Symmetric: STR + INT, INT + STR,
//     STR + LIST, LIST + STR all work.
//   - LIST + LIST and TUPLE + TUPLE go straight to array_merge.
//   - Numeric operands (INT/BOOL/FLOAT, any combination) take the
//     cast-and-arith path.
//   - Anything else surfaces as ERR_TYPE via array_merge or
//     cast_common_number_type.
led_plus:
    preamble_args(1, 0)
    jsr infix_eval                    // RS: [LHS, RHS]

    rs_peek_at(W0, 1)
    ldy #H_TYPE
    lda (W0),y
    sta B0                            // B0 = LHS type tag
    rs_peek(W0)
    ldy #H_TYPE                       // rs_peek clobbered Y — restore.
    lda (W0),y
    sta B1                            // B1 = RHS type tag

    // STR involved on either side?
    lda B0
    cmp #TYPE_STR
    beq _lp_lhs_str
    lda B1
    cmp #TYPE_STR
    beq _lp_rhs_str_only

    // Neither side is STR. LIST/TUPLE go straight to merge.
    lda B0
    cmp #TYPE_LIST
    beq _lp_merge
    cmp #TYPE_TUPLE
    beq _lp_merge

    // Numeric.
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

_lp_lhs_str:
    // LHS is STR. If RHS is too, fall through to byte-concat. Otherwise
    // coerce RHS in place via str(), then merge.
    lda B1
    cmp #TYPE_STR
    beq _lp_merge
    jsr _lp_coerce_rhs
    jmp _lp_merge
_lp_rhs_str_only:
    // RHS is STR but LHS isn't (we'd have taken _lp_lhs_str otherwise).
    jsr _lp_coerce_lhs
    jmp _lp_merge

_lp_merge:
    jsr array_merge
    jmp postamble


// _lp_coerce_rhs — RS [LHS, RHS_nonstr] → RS [LHS, str(RHS)].
// _lp_coerce_lhs — RS [LHS_nonstr, RHS] → RS [str(LHS), RHS].
//
// Both helpers leave RS net-shape unchanged (one slot replaced) and produce
// no return value of their own — caller falls through to array_merge.
//
// Leaf helpers, NOT V4'-wrapped — _str_w0 (in builtins.asm) IS V4'-wrapped
// and saves W/B around the recursive builtin_str. The few register reads
// here happen before that call so we don't depend on register survival.
_lp_coerce_rhs:
    rs_peek(W0)                       // W0 = RHS
    jsr _str_w0                       // RV = str(RHS); RS unchanged net
    rs_pop(W1)                        // discard old RHS handle
    rs_push(RV)                       // push coerced; RS: [LHS, str(RHS)]
    rts
_lp_coerce_lhs:
    rs_peek_at(W0, 1)                 // W0 = LHS
    jsr _str_w0                       // RV = str(LHS); RS unchanged net
    rs_pop(W1)                        // RHS off the top, hold in W1
    rs_pop(W0)                        // discard old LHS
    rs_push(RV)                       // push coerced LHS
    rs_push(W1)                       // restore RHS on top
    rts

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
    jsr eval                      // force lazy operand
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
    jmp panic_type
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
    jsr expression
    rs_push(RV)
    jsr eval                      // force lazy operand → value
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
    // Parse first expression at rbp=LBP_COMMA so the comma operator doesn't
    // bind here — we handle commas explicitly below. Elements are kept LAZY
    // (NAME / REF / SUB) so the resulting tuple can serve as either a value
    // (eval forces in-place via _ev_tuple) or an LHS pattern (assign recurses).
    lda #LBP_COMMA
    sta B7
    jsr expression                // RV = first element (lazy ok)
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
    lda #LBP_COMMA
    sta B7
    jsr expression                // RV = next element (lazy ok — see _nlp_first)
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
    jmp postamble_pop_rv

// -----------------------------------------------------------------------------
// nud_dict_lt — dict literal `<key: value, ...>`.  `<>` is an empty dict.
//
// We use angle brackets, NOT curly braces, because the C64 character ROM has
// no `{` `}` glyphs in either charset (PETSCII $7B and $7D map to graphic
// blocks). Source-level `{...}` is no longer accepted; `<...>` is THE dict
// syntax. Repr also emits `<...>`.
//
// Ambiguity with comparison `<` `>`: the parser dispatches based on
// position. In nud position (no left operand) `<` opens a dict literal; in
// led position `<` is the less-than comparison.
//
// To prevent `>` from being parsed as comparison while we're reading dict
// keys/values, we PATCH the lbp-table entries for TK_LT and TK_GT to
// LBP_TERM (=0) on entry, restore on exit. The original lbps are pushed on
// the HW stack so nested literals stack correctly — each level saves the
// value it overwrites and restores it when done. Comparisons inside a value
// (`<a: 1<2>`) need parens: `<a: (1<2)>`.
//
// Nested dicts: the lexer would otherwise greedily coalesce `>>` into
// TK_RSHIFT and `<<` into TK_LSHIFT. At each point in nud_dict_lt where we
// expect a `<` or `>`, we call _dict_split_lshift / _dict_split_rshift to
// split a paired token in place: replace TK_LSHIFT with TK_LT (or TK_RSHIFT
// with TK_GT) and back LEX_PTR up by 1 so the leftover char re-lexes on the
// next advance.
// -----------------------------------------------------------------------------
// _dict_split_rshift — if current token is TK_RSHIFT (`>>`), shrink it to a
// single TK_GT. LEX_PTR is reset to point at the second `>` so the next
// lexer_next picks it up. Preserves all registers; never panics.
_dict_split_rshift:
    lda LEX_TOKEN_KIND
    cmp #TK_RSHIFT
    bne !done+
    lda #TK_GT
    sta LEX_TOKEN_KIND
    clc
    lda LEX_TOKEN_START
    adc #1
    sta LEX_TOKEN_END
    sta LEX_PTR
    lda LEX_TOKEN_START+1
    adc #0
    sta LEX_TOKEN_END+1
    sta LEX_PTR+1
!done:
    rts

// _dict_split_lshift — same idea, TK_LSHIFT → TK_LT.
_dict_split_lshift:
    lda LEX_TOKEN_KIND
    cmp #TK_LSHIFT
    bne !done+
    lda #TK_LT
    sta LEX_TOKEN_KIND
    clc
    lda LEX_TOKEN_START
    adc #1
    sta LEX_TOKEN_END
    sta LEX_PTR
    lda LEX_TOKEN_START+1
    adc #0
    sta LEX_TOKEN_END+1
    sta LEX_PTR+1
!done:
    rts

nud_dict_lt:
    preamble_args(0, 0)

    // Save current lbp[TK_LT] / lbp[TK_GT] / lbp[TK_LSHIFT] / lbp[TK_RSHIFT]
    // on the HW stack so nested dict literals stack correctly. Patch all to
    // 0 so `<` / `>` don't bind as comparisons and `<<` / `>>` don't bind as
    // shift operators while reading dict keys/values. (Shift binding would
    // cause the expression parser to consume a closing `>>` as a shift
    // before nud_dict_lt's split logic gets a chance.)
    lda lbp_table + TK_LT
    pha
    lda lbp_table + TK_GT
    pha
    lda lbp_table + TK_LSHIFT
    pha
    lda lbp_table + TK_RSHIFT
    pha
    lda #LBP_TERM
    sta lbp_table + TK_LT
    sta lbp_table + TK_GT
    sta lbp_table + TK_LSHIFT
    sta lbp_table + TK_RSHIFT

    jsr lexer_next                // consume '<'
    jsr _skip_layout              // newlines OK after open
    jsr dict_alloc                // RV = empty dict
    rs_push(RV)                   // RS: [dict]

    jsr _dict_split_rshift        // `>>` → `>` if empty-dict close stuck
    lda LEX_TOKEN_KIND
    cmp #TK_GT
    bne _ndc_loop
    jsr lexer_next                // empty `<>`
    rs_pop(RV)
    jmp _ndc_restore_and_return

_ndc_loop:
    // Push a dict copy so dict_set's 3-arg consume leaves the persistent
    // reference (RS slot 1) intact for the next iteration.
    rs_peek(W0)
    rs_push(W0)                   // RS: [dict, dict_copy]

    // Parse key — rbp=LBP_COMMA so `,` doesn't bind here.
    lda #LBP_COMMA
    sta B7
    jsr expression                // RV = lazy key
    rs_push(RV)
    jsr eval                      // force key to value
    jsr _skip_layout              // newlines OK before `:`
    rs_push(RV)                   // RS: [dict, dict_copy, key]

    lda #TK_COLON
    jsr lexer_advance
    jsr _skip_layout              // newlines OK after `:`

    // Parse value.
    lda #LBP_COMMA
    sta B7
    jsr expression                // RV = lazy value
    rs_push(RV)
    jsr eval                      // force value
    jsr _skip_layout              // newlines OK before `,` / `>`
    rs_push(RV)                   // RS: [dict, dict_copy, key, value]

    jsr dict_set                  // consumes 3 → RS: [dict]

    jsr _dict_split_rshift        // `>>` after value → `>` close + leftover `>`
    lda LEX_TOKEN_KIND
    cmp #TK_COMMA
    bne _ndc_close
    jsr lexer_next                // consume ','
    jsr _skip_layout              // newlines OK after `,`
    jsr _dict_split_rshift        // `>>` after `,` → close
    // Trailing comma `<a: 1,>` is allowed.
    lda LEX_TOKEN_KIND
    cmp #TK_GT
    beq _ndc_close
    jmp _ndc_loop

_ndc_close:
    lda #TK_GT
    jsr lexer_advance
    rs_pop(RV)

_ndc_restore_and_return:
    // Restore lbps in reverse-push order. Postamble's HW-stack work is
    // balanced, so leaving the body with four extra HW-stack pops is correct.
    pla
    sta lbp_table + TK_RSHIFT
    pla
    sta lbp_table + TK_LSHIFT
    pla
    sta lbp_table + TK_GT
    pla
    sta lbp_table + TK_LT
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
    jmp _lex_next_post

nud_false:
    preamble_args(0, 0)
    lda #<FALSE
    sta RV
    lda #>FALSE
    sta RV+1
    jmp _lex_next_post

nud_none:
    preamble_args(0, 0)
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1
    jmp _lex_next_post

// -----------------------------------------------------------------------------
// nud_tilde — prefix bitwise NOT `~x`.
// -----------------------------------------------------------------------------
nud_tilde:
    preamble_args(0, 0)
    jsr lexer_next                // consume '~'
    lda #LBP_UNARY
    sta B7
    jsr expression                // RV = lazy operand
    rs_push(RV)
    jsr eval                      // RV = forced operand
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
    jsr expression                // RV = lazy operand
    rs_push(RV)
    jsr eval                      // RV = forced value
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    jsr val_truthy                // A = 1 / 0
    bne _nn_to_false
    // operand was falsy → result True
    jmp postamble_return_true
_nn_to_false:
    jmp postamble_return_false

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
    preamble_args(1, 0)               // LHS on RS (possibly lazy)
    jsr lexer_next                    // consume `and`

    // Force LHS in-place.
    jsr eval                          // consumes 1; RV = forced LHS
    rs_push(RV)                       // RS: [..., LHS_value]

    rs_peek(W0)                       // W0 = LHS value
    jsr val_truthy
    beq _land_short                   // LHS falsy → short-circuit

    // LHS truthy → eval RHS, return RHS.
    lda #LBP_AND
    sta B7
    jsr expression
    rs_push(RV)
    jsr eval                          // force RHS
    jmp postamble

_land_short:
    // LHS falsy → skip RHS, return LHS.
    lda #LBP_AND
    sta B7
    jsr skip_expression
    jmp postamble_peek_rv             // RV = LHS (still on RS)

led_or:
    preamble_args(1, 0)
    jsr lexer_next                    // consume `or`

    // Force LHS in-place.
    jsr eval
    rs_push(RV)

    rs_peek(W0)
    jsr val_truthy
    bne _lor_short                    // LHS truthy → short-circuit

    // LHS falsy → eval RHS, return RHS.
    lda #LBP_OR
    sta B7
    jsr expression
    rs_push(RV)
    jsr eval                          // force RHS
    jmp postamble

_lor_short:
    // LHS truthy → skip RHS, return LHS.
    lda #LBP_OR
    sta B7
    jsr skip_expression
    jmp postamble_peek_rv

// -----------------------------------------------------------------------------
// led_is — handle identity `a is b` and `a is not b`.
// Doesn't fit the led_binop / led_cmp shape because the `not` token after
// `is` is parser-level state, not part of the lexer's token stream.
// -----------------------------------------------------------------------------
led_is:
    preamble_args(1, 0)
    jsr lexer_next                    // consume `is`

    // Force LHS to a real handle (lazy NAME(a) handle != value handle).
    jsr eval
    rs_push(RV)

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
    jsr expression                    // RV = lazy RHS
    rs_push(RV)
    jsr eval                          // RV = forced RHS handle

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
    jmp postamble_return_true
_lis_to_false:
    jmp postamble_return_false

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
    jmp panic_type

_lin_str:
    // For STR membership the needle must also be a TYPE_STR. (Python rejects
    // `1 in "abc"` with TypeError; we follow.)
    rs_peek_at(W0, 1)
    ldy #H_TYPE                       // rs_peek_at clobbered Y
    lda (W0),y
    cmp #TYPE_STR
    beq !ok+
    jmp panic_type
!ok:
    // Full-range search: start=0:0, end=$FFFF (sentinel → haystack_len).
    lda #0
    sta B4
    sta B5
    lda #$FF
    sta B6
    sta B7
    jsr str_find_pos                  // RV = position word or $FFFF
    lda RV
    and RV+1
    cmp #$FF
    bne !found+
    lda #0
    jmp _lin_to_bool
!found:
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
    jmp postamble_return_true
_lin_false:
    jmp postamble_return_false

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
    jmp postamble_pop_rv

_nlb_loop:
    // Parse element expression at LBP_COMMA so `,` doesn't bind to led_comma.
    lda #LBP_COMMA
    sta B7
    jsr expression                    // RV = lazy element
    rs_push(RV)
    jsr eval                          // RV = element value
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
    jmp postamble_pop_rv              // RV = the assembled list

_nlb_recover:
    jmp _lh_recover_parser

// -----------------------------------------------------------------------------
// led_lparen — `(` as an LED, i.e. the LHS is a runtime *value* being called.
//
// Built-in functions and methods are NOT first-class values in admiral, so
// they never reach this routine — `nud_name` and `led_dot` peek for `(`
// after the name and dispatch directly via `_call_dispatch`. The only thing
// that is a callable runtime value is a TYPE_STR (lambda body re-lex'd in
// a fresh scope). Anything else under `(` is a type error.
// -----------------------------------------------------------------------------
led_lparen:
    preamble_args(1, 0)             // LHS on RS (callable: TYPE_NAME or TYPE_STR)

    // LHS dispatch:
    //   TYPE_NAME → free-function builtin (TST lookup in builtins table)
    //   TYPE_STR  → lambda body re-lex'd in a fresh scope
    //   anything else → ERR_TYPE
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_NAME
    beq _llp_name_call
    cmp #TYPE_STR
    beq _llp_str_prefix
    jmp panic_type

_llp_name_call:
    // Free-function builtin: try TST lookup. On hit, drop the name from RS
    // and tail into _call_dispatch (which handles `(`-paren-onward).
    jsr try_builtin_lookup          // A=1 hit (W3=impl_addr, name popped); A=0 miss
    cmp #0
    beq _llp_name_miss
    jsr _call_dispatch              // METHOD_RECEIVER == 0 → free function
    jmp postamble
_llp_name_miss:
    // Not a known builtin — try evaluating the name (in case the user bound
    // a TYPE_STR lambda to it via `f = "..."`). On a value, recurse-style.
    jsr eval                        // consumes 1; RV = bound value
    rs_push(RV)                     // RS: [..., value]
    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq _llp_str_prefix
    jmp panic_type

_llp_str_prefix:
    jsr lexer_next                  // consume `(`

    // Snapshot METHOD_RECEIVER (set by led_dot for `dict.attr(...)` where
    // attr is a user-stored TYPE_STR lambda). Push as me_or_0 root + clear ZP.
    lda METHOD_RECEIVER
    sta W0
    lda METHOD_RECEIVER+1
    sta W0+1
    rs_push(W0)                     // RS: [LHS, me]
    lda #0
    sta METHOD_RECEIVER
    sta METHOD_RECEIVER+1

    jmp _llp_str_call

// =============================================================================
// _call_dispatch — leaf helper invoked by `nud_name` (free-function builtins)
// and `led_dot` (method builtins) after either has resolved the name to an
// impl address. Caller is V4'-wrapped; we just clobber W's/B's freely.
//
//   in:  W3 = impl address.
//        METHOD_RECEIVER = obj for method calls, 0 for free functions.
//        Lexer positioned at TK_LPAREN.
//        RS = [...] (caller has already consumed the name and any obj LHS;
//                    no callable value sits on RS — _call_dispatch builds
//                    the args tuple and JSRs the impl directly).
//   out: RV = result of impl.
//        RS unchanged from entry.
//        FS unchanged from entry.
//        METHOD_RECEIVER cleared.
//
// Body parses positional args, packs them into a TYPE_TUPLE per V2 calling
// convention (with `me` prepended at slot 0 for methods), then SMC-JSRs to
// the impl. The impl is V4' and consumes the tuple via its own preamble.
//
// Nesting safety: the impl address is fs_push'd on entry so a nested
// `_call_dispatch` invocation (e.g. from a nested arg expression like
// `len(range(n))`) can run without disturbing our pending dispatch.
// =============================================================================
_call_dispatch:
    fs_push(W3)                     // survive nested arg-eval
    jsr lexer_next                  // consume `(`

    lda METHOD_RECEIVER
    sta W0
    lda METHOD_RECEIVER+1
    sta W0+1
    rs_push(W0)                     // RS: [..., me_or_0]
    lda #0
    sta METHOD_RECEIVER
    sta METHOD_RECEIVER+1

    lda #0
    sta B0                          // B0 = arg count

    lda LEX_TOKEN_KIND
    cmp #TK_RPAREN
    beq _cd_args_done

_cd_arg_loop:
    lda #LBP_COMMA                  // rbp=LBP_COMMA so `,` doesn't bind here
    sta B7
    jsr expression                  // RV = lazy arg
    rs_push(RV)
    jsr eval                        // RV = forced value
    rs_push(RV)
    inc B0

    lda LEX_TOKEN_KIND
    cmp #TK_COMMA
    bne _cd_args_done
    jsr lexer_next
    jmp _cd_arg_loop

_cd_args_done:
    lda #TK_RPAREN
    jsr lexer_advance

    // --- Pack args into TYPE_TUPLE -------------------------------------------
    // RS now: [..., me_or_0, arg1..argN]. me_or_0 at byte offset 2*B0 from RSP.

    // Read me_or_0 into B2:B3.
    lda B0
    asl
    tay
    lda (RSP),y
    sta B2
    iny
    lda (RSP),y
    sta B3

    // B1 = tuple size: B0 + 1 if method, else B0.
    lda B2
    ora B3
    beq _cd_no_me
    lda B0
    clc
    adc #1
    sta B1
    jmp _cd_have_size
_cd_no_me:
    lda B0
    sta B1

_cd_have_size:
    lda B1
    jsr tuple_alloc                 // RV = tuple
    rs_push(RV)                     // RS: [..., me, args, tuple]

    lda RV
    sta W0
    lda RV+1
    sta W0+1

    // For method calls, copy me into slot 0.
    lda B2
    ora B3
    beq _cd_no_me_copy
    lda B2
    sta W1
    lda B3
    sta W1+1
    lda #0
    jsr tuple_set_leaf
_cd_no_me_copy:

    // Copy args into tuple. B5 counts down from B0 to 1; src offset 2*B5
    // (above tuple), dest slot = B1 - B5.
    lda B0
    sta B5
    beq _cd_args_copied
_cd_arg_copy_loop:
    lda B5
    asl
    tay
    lda (RSP),y
    sta W1
    iny
    lda (RSP),y
    sta W1+1

    sec
    lda B1
    sbc B5
    jsr tuple_set_leaf

    dec B5
    bne _cd_arg_copy_loop
_cd_args_copied:

    // Collapse RS: pop tuple, drop (B0+1) words, push tuple.
    rs_pop(W1)
    lda B0
    clc
    adc #1
    asl
    clc
    adc RSP
    sta RSP
    bcc !skip+
    inc RSP+1
!skip:
    rs_push(W1)                     // RS: [..., tuple]

    // --- SMC JSR to impl ----------------------------------------------------
    fs_pop(W3)
    lda W3
    sta _cd_jsr+1
    lda W3+1
    sta _cd_jsr+2
_cd_jsr:
    jsr $0000                       // → impl (consumes tuple via its preamble)
    rts                              // RV = result; RS balanced

// --- TYPE_STR: kwargs, body re-lex in fresh scope ---------------------------
//
// Algorithm:
//   1. Save current CURRENT_SCOPE on RS (root).
//   2. Allocate new scope dict, set CURRENT_SCOPE.
//   3. Parse `(name=value, ...)`, scope_set each name→value (now into new scope).
//   4. Save outer lexer state on FS.
//   5. Push body string handle on RS, lexer_init on it.
//   6. Run statement loop until EOF or CTRL_RETURN.
//   7. If CTRL_RETURN, extract its payload as the call's result.
//   8. Pop body-handle copy. lexer_restore. Restore CURRENT_SCOPE.
//
// RS layout during body execution:
//   [..., LHS, old_scope, new_scope, body_handle_for_lexer]
_llp_str_call:
    // Save current scope onto RS for restoration after the call.
    lda CURRENT_SCOPE
    sta W0
    lda CURRENT_SCOPE+1
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

    // Parse kwargs in CALLER's scope (CURRENT_SCOPE unchanged), pushing each
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
    jmp panic_lex
_llp_s_have_name:
    jsr lexer_get_token_as_string   // RV = name TYPE_STR
    rs_push(RV)                     // RS: [..., new, ..., name]
    jsr lexer_next                  // consume name
    lda #TK_ASSIGN
    jsr lexer_advance               // consume `=`
    lda #LBP_COMMA                  // rbp=LBP_COMMA — `,` separates kwargs
    sta B7
    jsr expression                  // RV = lazy value (resolved in caller scope)
    rs_push(RV)
    jsr eval                        // force kwarg value
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

    // All kwargs evaluated. Switch CURRENT_SCOPE = new_scope. With B0 kwargs
    // (2 words each) plus the unchanged me push, new_scope is at slot index
    // 2*B0 from RS top; byte offset = 4*B0.
    lda B0
    asl
    asl
    tay
    lda (RSP),y
    sta CURRENT_SCOPE
    iny
    lda (RSP),y
    sta CURRENT_SCOPE+1

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
    jmp panic_lex

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

    // Pop new_scope, then old_scope into CURRENT_SCOPE.
    rs_drop(1)                       // discard new_scope
    rs_pop(W0)                       // W0 = old_scope
    lda W0
    sta CURRENT_SCOPE
    lda W0+1
    sta CURRENT_SCOPE+1

    jmp postamble                    // postamble cleans LHS off RS

// -----------------------------------------------------------------------------
// led_lbrack — subscription. Returns either:
//   - TYPE_SUB(container, index)  — for plain `a[i]` (assigned to via the
//     generic `assign` LED path; eval'd to a value when used as an rvalue).
//   - A new TYPE_LIST  — for slice form `a[start:stop]` (eager value).
//
// The unified TYPE_SUB representation lets `(a, lst[0]) = (...)` mixed-lvalue
// tuple unpack work uniformly with single-name and attribute LHSes.
// -----------------------------------------------------------------------------
led_lbrack:
    preamble_args(1, 0)               // LHS on RS (possibly lazy)

    // Force LHS in-place — `a[i]` requires a's container value.
    jsr eval                          // consumes 1; RV = forced container
    rs_push(RV)                       // RS: [..., container]

    jsr lexer_next                    // consume '['
    lda #LBP_COMMA                    // rbp = LBP_COMMA — disallow tuple here
    sta B7
    jsr expression                    // RV = lazy index/start
    rs_push(RV)
    jsr eval                          // RV = forced index

    // Slice form: `a[start:stop]`?
    lda LEX_TOKEN_KIND
    cmp #TK_COLON
    bne _llb_no_slice
    jmp _llb_slice
_llb_no_slice:

    lda #TK_RBRACK
    jsr lexer_advance                 // consume ']'

    // Build TYPE_SUB(container, index). RS already in alloc_sub's order
    // (container deeper, index on top once we push RV).
    rs_push(RV)                       // RS: [..., container, index]
    jsr alloc_sub                     // consumes 2; RV = SUB handle
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

    // B4 = start (inline int low byte; if negative, add len).
    rs_peek_at(W0, 1)
    ldy #0
    lda (W0),y
    bpl _slh_start_pos
    clc
    adc B6
_slh_start_pos:
    sta B4

    // B5 = stop (inline int low byte; normalize negative).
    rs_peek_at(W0, 0)
    ldy #0
    lda (W0),y
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
    // src = container.payload + B4 (in W3).
    rs_peek_at(W0, 2)
    jsr deref_W0_to_W3
    clc
    lda W3
    adc B4
    sta W3
    bcc !+
    inc W3+1
!:
    // dst = RV.payload (in W2).
    jsr deref_RV_to_W2

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
    preamble_args(1, 0)             // LHS on RS = the dict (possibly lazy)

    // Force LHS in-place — `a.b` requires a's value, not the lazy NAME(a).
    jsr eval                        // consumes 1; RV = forced LHS value
    rs_push(RV)                     // RS: [..., dict_value]

    jsr lexer_next                  // consume `.`

    lda LEX_TOKEN_KIND
    cmp #TK_NAME
    beq _ldot_have_name
    jmp panic_lex
_ldot_have_name:
    jsr lexer_get_token_as_string   // RV = name TYPE_STR
    rs_push(RV)                     // RS: [..., receiver, name]
    jsr lexer_next                  // consume name

    // Method call: `obj.name(args)`. Methods are not first-class values, so
    // we dispatch directly here; the alternative (returning a REF and letting
    // led_lparen do the lookup) would require a separate REF-aware call path.
    lda LEX_TOKEN_KIND
    cmp #TK_LPAREN
    bne !next+
    jmp _ldot_method_prefix
!next:

    // Otherwise build TYPE_REF(receiver, name) and let consumers eval (read)
    // or assign (LHS). This unifies single-attr assignment with mixed-lvalue
    // tuple-LHS unpacking, e.g. `(a, obj.x) = (1, 99)`.
    jsr alloc_ref                   // consumes 2; RV = REF handle
    jmp postamble

_ldot_method_prefix:
    // Set METHOD_RECEIVER = obj (slot 1; name on top). Used by both the
    // direct-dispatch path (free of values, for built-in methods) and the
    // dict-user-attribute fallback (where we return the user value as a
    // callable LHS for led_lparen → _llp_str_call).
    rs_peek_at(W0, 1)
    lda W0
    sta METHOD_RECEIVER
    lda W0+1
    sta METHOD_RECEIVER+1

    // Dispatch by receiver type:
    //   TYPE_DICT  → user-defined attributes win (prototype chain). On miss,
    //                fall back to dict_methods built-in table.
    //   TYPE_STR   → str_methods.
    //   TYPE_LIST/TUPLE → list_methods.
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
    jmp panic_type

_ldot_dict_method:
    // Try user attribute chain first. RS: [..., dict, name]. dict_get_proto
    // consumes 2; we save name in W1 first so we can re-stage for the
    // method-table fallback (W1 is preserved across the V4' subcall).
    rs_peek(W1)
    jsr dict_get_proto              // RV = value or NONE

    lda RV+1
    cmp #>NONE
    bne _ldot_dict_user_hit
    lda RV
    cmp #<NONE
    bne _ldot_dict_user_hit

    // Chain miss: fall back to the dict_methods built-in table. We hold W1=
    // name; RS = [...] (obj/name already consumed).
    lda #<dict_methods
    sta W0
    lda #>dict_methods
    sta W0+1
    jsr _method_lookup              // RV = impl_addr on hit (A=1)
    cmp #0
    beq _ldot_dict_no_method
    lda RV
    sta W3
    lda RV+1
    sta W3+1
    jsr _call_dispatch              // METHOD_RECEIVER already set above
    jmp postamble

_ldot_dict_user_hit:
    // RV = user attribute value. Return as a value via postamble; the parser
    // will push RV, see TK_LPAREN, and call led_lparen → _llp_str_call (if
    // the value is a TYPE_STR lambda) or panic ERR_TYPE (anything else).
    jmp postamble

_ldot_dict_no_method:
    jmp panic_lex

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
    // RS: [..., obj, name]. Pop name; _method_lookup uses W0=table, W1=name.
    rs_pop(W1)                      // pop name; RS: [..., obj]
    jsr _method_lookup              // RV = impl_addr on hit (A=1)
    cmp #0
    beq _ldot_method_miss
    rs_pop(W0)                      // pop obj; RS: [...]. METHOD_RECEIVER set above.
    lda RV
    sta W3
    lda RV+1
    sta W3+1
    jsr _call_dispatch
    jmp postamble
_ldot_method_miss:
    jmp panic_type

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
// nud_name — TK_NAME prefix. Admiral-style: returns a lazy TYPE_NAME handle.
// All dispatch (`=`, `(`, `+=`, etc.) happens via LEDs in the expression loop.
// `eval(TYPE_NAME)` deferreds to `scope_get`.
// -----------------------------------------------------------------------------
nud_name:
    preamble_args(0, 0)
    jsr lexer_get_token_as_string  // RV = TYPE_STR for the identifier span
    // Mutate H_TYPE → TYPE_NAME so `eval` routes to scope_get instead of
    // returning the bytes.
    ldy #H_TYPE
    lda #TYPE_NAME
    sta (RV),y
    jmp _lex_next_post

// -----------------------------------------------------------------------------
// led_assign — TK_ASSIGN binary LED. Right-associative.
//   in:  RS top = LHS (lazy: TYPE_NAME / TYPE_REF / TYPE_SUB / TYPE_TUPLE).
//        Lexer at TK_ASSIGN.
//   out: RV = NONE_HANDLE (assignment is a statement; produces no value).
//        Side effect: writes RHS value to LHS via `assign`.
// V4'.
// -----------------------------------------------------------------------------
led_assign:
    preamble_args(1, 0)             // RS: [..., LHS_lazy]

    jsr lexer_next                  // consume `=`
    lda #0
    sta B7                          // rbp = 0 — RHS picks up commas (tuple)
    jsr expression                  // RV = lazy RHS (single or tuple)

    rs_push(RV)
    jsr eval                        // RV = forced RHS value (in-place for TUPLE)

    rs_push(RV)                     // RS: [..., LHS_lazy, value]
    jsr assign                      // consumes 2; RV unspecified

    jmp postamble_return_none

// -----------------------------------------------------------------------------
// led_augass — TK_AUGASS_* (`+=`, `-=`, ...). Right-associative.
//   in:  RS top = LHS (lazy). Lexer at the augass token.
//   out: RV = NONE_HANDLE.
//
// Strategy:
//   1. Duplicate LHS_lazy onto RS so the binary-op LED can consume one copy.
//   2. SMC-JSR through augass_lo/hi to the matching led_<op> (e.g. led_plus).
//      led_<op>'s preamble consumes the dup, infix_eval evals it, parses RHS,
//      evals RHS, op_routine produces RV = result. RS top is back to LHS_lazy.
//   3. Push RV, jsr assign — writes result to the lazy target.
// V4'.
// -----------------------------------------------------------------------------
led_augass:
    preamble_args(1, 0)             // RS: [..., LHS_lazy]

    // SMC the trampoline before lexer_next consumes the augass token.
    ldx LEX_TOKEN_KIND
    lda augass_lo - TK_AUGASS_BASE,x
    sta _laa_jsr+1
    lda augass_hi - TK_AUGASS_BASE,x
    sta _laa_jsr+2

    rs_peek(W0)
    rs_push(W0)                     // RS: [..., LHS_lazy, LHS_lazy]
_laa_jsr:
    jsr $0000                       // → led_plus / led_minus / etc.
                                    // Consumes 1, parses RHS, RV = result.
                                    // RS now: [..., LHS_lazy].

    rs_push(RV)                     // RS: [..., LHS_lazy, result]
    jsr assign                      // consumes 2

    jmp postamble_return_none

// -----------------------------------------------------------------------------
// led_comma — TK_COMMA binary LED. Builds a TYPE_TUPLE of comma-separated
// items, starting from LHS (already on RS). Items are KEPT LAZY — they get
// evaluated by `eval(TYPE_TUPLE)` only when used as a value (e.g. RHS of
// assignment). As an LHS pattern, the lazy items are walked recursively by
// `assign`.
//
//   in:  RS top = first item (lazy). Lexer at TK_COMMA.
//   out: RV = TYPE_TUPLE handle. RS swept by V4' postamble.
//
// Trailing comma is allowed: `a, b,` ends the tuple at 2 items.
// Inside container literals (parens / brackets / braces) and call-arg lists
// the surrounding NUD/LED parses each item at rbp = LBP_COMMA, so this LED
// is bypassed there — only top-level statement commas reach this routine.
// V4'.
// -----------------------------------------------------------------------------
led_comma:
    preamble_args(1, 0)             // RS: [..., first_item]

    lda #1
    sta B0                          // B0 = item count

_lc_loop:
    jsr lexer_next                  // consume `,`

    // Trailing comma: if next token has no NUD, stop (e.g. `)`, `]`, EOF).
    ldx LEX_TOKEN_KIND
    lda nud_lo,x
    cmp #<nud_recover
    bne _lc_has_expr
    lda nud_hi,x
    cmp #>nud_recover
    beq _lc_break

_lc_has_expr:
    lda #LBP_COMMA                  // rbp = LBP_COMMA — next `,` won't recurse
    sta B7
    jsr expression                  // RV = next item (lazy)
    rs_push(RV)
    inc B0

    lda LEX_TOKEN_KIND
    cmp #TK_COMMA
    beq _lc_loop

_lc_break:
    // Allocate TYPE_TUPLE of size B0. _array_alloc_init may GC; items on RS
    // are roots (V4' frame + body's pushes).
    lda B0
    ldx #TYPE_TUPLE
    jsr _array_alloc_init           // RV = tuple handle, payload zeroed

    // Push tuple as root before touching its payload.
    rs_push(RV)                     // RS: [..., item0, .., itemN-1, tuple]
    lda RV
    sta W0
    lda RV+1
    sta W0+1

    // Fill tuple[i] = item[i]. item[i] sits at RS depth (B0 - i); top is tuple
    // at depth 0, RS[depth*2] = byte offset.
    lda #0
    sta B1                          // B1 = i

_lc_fill:
    lda B1
    cmp B0
    beq _lc_filled

    sec
    lda B0
    sbc B1                          // A = B0 - i (depth in words)
    asl                             // Y = byte offset
    tay
    jsr rs_peek_at_w1               // W1 = RS[depth] = item[i]

    lda B1
    jsr tuple_set_leaf              // W0=tuple, W1=item, A=index

    inc B1
    jmp _lc_fill

_lc_filled:
    // RV still = tuple (set by _array_alloc_init; postamble preserves RV).
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
    jmp panic_lex

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
.const TK_TABLE_SIZE = $4D    // TK_CLS + 1 = 77

// _lex_next_post — `jsr lexer_next ; jmp postamble` shortcut. Saves 3 bytes
// per use across the parser sites that consume one token then return.
_lex_next_post:                              // shared tail (do not inline)
    jsr lexer_next                           // [helper body — distinct comment]
    jmp postamble

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
    .byte <nud_recover                          // 14 TK_LCURLY (no longer dict — use `<...>`)
    .fill TK_PLUS - 15, <nud_recover            // 15..TK_PLUS-1
    .byte <nud_plus                             // 21 TK_PLUS
    .byte <nud_minus                            // 22 TK_MINUS
    .fill TK_TILDE - TK_MINUS - 1, <nud_recover // 23..32
    .byte <nud_tilde                            // 33 TK_TILDE
    .byte <nud_dict_lt                          // 34 TK_LT (dict literal `<...>`)
    .fill TK_NOT - TK_TILDE - 2, <nud_recover   // 35..69
    .byte <nud_not                              // TK_NOT (=$46 = 70)
    .byte <nud_recover                          // TK_IS — LED only
    .byte <nud_true                             // TK_TRUE
    .byte <nud_false                            // TK_FALSE
    .byte <nud_none                             // TK_NONE_KW
    .byte <nud_recover                          // TK_PRINT (statement only)
    .byte <nud_recover                          // TK_CLS (statement only)

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
    .byte >nud_recover                          // 14 TK_LCURLY (no longer dict)
    .fill TK_PLUS - 15, >nud_recover
    .byte >nud_plus
    .byte >nud_minus
    .fill TK_TILDE - TK_MINUS - 1, >nud_recover
    .byte >nud_tilde
    .byte >nud_dict_lt                          // 34 TK_LT
    .fill TK_NOT - TK_TILDE - 2, >nud_recover
    .byte >nud_not
    .byte >nud_recover
    .byte >nud_true
    .byte >nud_false
    .byte >nud_none
    .byte >nud_recover                          // TK_PRINT (statement only)
    .byte >nud_recover                          // TK_CLS (statement only)

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
    .byte <led_comma                               // 16 TK_COMMA
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
    .byte <led_assign                              // $28 TK_ASSIGN
    .fill TK_AUGASS_LAST - TK_AUGASS_BASE + 1, <led_augass // $29..$34 TK_AUGASS_*
    .fill TK_IN - TK_AUGASS_LAST - 1, <led_recover         // $35..$39 keywords (NUDs only)
    .byte <led_in                                  // $3A TK_IN (binary `in`)
    .fill TK_AND - TK_IN - 1, <led_recover         // $3B..$43
    .byte <led_and                                 // $44 TK_AND
    .byte <led_or                                  // 69 TK_OR
    .byte <led_recover                             // 70 TK_NOT (NUD only)
    .byte <led_is                                  // 71 TK_IS
    .fill TK_TABLE_SIZE - TK_IS - 1, <led_recover

led_hi:
    .fill TK_LPAREN, >led_recover
    .byte >led_lparen                              // 10 TK_LPAREN
    .byte >led_recover                             // 11 TK_RPAREN
    .byte >led_lbrack                              // 12 TK_LBRACK
    .byte >led_recover                             // 13 TK_RBRACK
    .byte >led_recover                             // 14 TK_LCURLY
    .byte >led_recover                             // 15 TK_RCURLY
    .byte >led_comma                               // 16 TK_COMMA
    .byte >led_recover                             // 17 TK_COLON
    .byte >led_recover                             // 18 TK_SEMICOLON
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
    .byte >led_assign                              // $28 TK_ASSIGN
    .fill TK_AUGASS_LAST - TK_AUGASS_BASE + 1, >led_augass // $29..$34 TK_AUGASS_*
    .fill TK_IN - TK_AUGASS_LAST - 1, >led_recover         // $35..$39 keywords (NUDs only)
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
    .byte LBP_COMMA                                // TK_COMMA — tuple ctor
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
    .byte LBP_ASSIGN                               // $28 TK_ASSIGN
    .fill TK_AUGASS_LAST - TK_AUGASS_BASE + 1, LBP_ASSIGN  // $29..$34 TK_AUGASS
    .fill TK_IN - TK_AUGASS_LAST - 1, LBP_TERM             // $35..$39 keywords
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
    .byte <(stmt_cls - 1)                           // $4C TK_CLS

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
    .byte >(stmt_cls - 1)                           // $4C TK_CLS
