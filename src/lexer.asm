// -----------------------------------------------------------------------------
// Lexer — pull-model tokenizer over a TYPE_STR source.
//
// One current token in ZP (LEX_TOKEN_KIND + LEX_TOKEN_START..END), parser
// drives via `lexer_advance`. Token = span: kind + (start, end) absolute
// pointers into the source-string payload. Materialization (TYPE_STR for a
// TK_NAME / TK_STR span, big-int for TK_INT, etc.) is deferred to the parser
// via `lexer_get_token_as_string`.
//
// Source rooting: caller keeps the source-string handle on RS for the
// duration of lexing. LEX_SRC_HANDLE is a ZP cache of that handle.
//
// Pointer staleness across `gc_compact`: `LEX_PTR / LEX_END / LEX_TOKEN_*`
// are absolute pointers into the source's heap payload. Any allocation
// (anywhere in the program — not just inside the lexer) can move that
// payload. The lexer keeps these pointers valid via two mechanisms:
//
//   (1) `gc_collect` brackets `gc_compact` with `_lex_to_offsets`/
//       `_lex_from_offsets` (see gc.asm). This rebases the active ZP state
//       on every collection, transparent to all callers.
//
//   (2) `lexer_save` / `lexer_restore` snapshot pointers as OFFSETS from the
//       source payload base (plus LEX_SRC_HANDLE), so saved snapshots
//       survive a compact between save and restore. (Used by `while`/`for`
//       body re-evaluation and `_llp_str_call` outer-state preservation.)
//
//   (3) `lexer_get_token_as_string` does its own pre-/post-alloc rebase
//       through the same `_lex_to_offsets`/`_lex_from_offsets` helpers,
//       since `str_alloc` may compact mid-routine.
//
// Char dispatch: single dispatch site at `_lex_dispatch_char`. Per-char
// handler table is 256 bytes (lo+hi parallel, 128 entries each — bytes
// $80..$FF route to `_lh_recover` via a high-bit check before lookup).
// Dispatch uses the rts trick: push (handler-1) hi/lo, rts → handler.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

// -----------------------------------------------------------------------------
// lexer_init — initialize lexer state from a source TYPE_STR handle.
//   in:   RS top = source string handle. Caller keeps it on RS as a GC root.
//   out:  LEX_* state populated; first token already lexed.
// V4' wrapper. **preamble_args(0, 0) — does NOT consume the source arg.**
// LEX_SRC_HANDLE in ZP is a cache; only RS-rooting keeps the source alive
// across the GC compactions that subsequent allocations may trigger.
// -----------------------------------------------------------------------------
lexer_init:
    preamble_args(0, 0)

    // Cache source handle pointer in ZP. Caller holds the rooting promise.
    rs_peek(W0)
    lda W0
    sta LEX_SRC_HANDLE
    lda W0+1
    sta LEX_SRC_HANDLE+1

    // W2 = heap-object base = (W0).H_PTR.
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1

    // 16-bit length is at (W2+O_LEN..O_LEN+1). Stash to W1.
    ldy #O_LEN
    lda (W2),y
    sta W1
    iny
    lda (W2),y
    sta W1+1

    // LEX_PTR = W2 + O_HEADER (skip past length header → first payload byte).
    clc
    lda W2
    adc #O_HEADER
    sta LEX_PTR
    lda W2+1
    adc #0
    sta LEX_PTR+1

    // LEX_END = LEX_PTR + length.
    clc
    lda LEX_PTR
    adc W1
    sta LEX_END
    lda LEX_PTR+1
    adc W1+1
    sta LEX_END+1

    // Reset indent state. The stack starts with one entry: stack[0] = 0
    // (top level). Both target and current depth = 0.
    lda #0
    sta LEX_INDENT_TARGET
    sta LEX_INDENT_CURRENT
    sta indent_depth
    sta indent_stack         // stack[0] = 0

    // Lex first token before returning.
    jsr lexer_next

    jmp postamble

// -----------------------------------------------------------------------------
// lexer_advance — assert current kind matches A, then advance.
//   in:   A = expected TK_*  (panic if mismatch)
//   out:  LEX_TOKEN_* updated to next token.
// V4' wrapper.
// -----------------------------------------------------------------------------
lexer_advance:
    cmp LEX_TOKEN_KIND
    beq !ok+
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler
!ok:
    jmp lexer_next

// -----------------------------------------------------------------------------
// lexer_next — scan the next token. Updates LEX_TOKEN_KIND/START/END.
// V4' wrapper.
// -----------------------------------------------------------------------------
lexer_next:
    preamble_args(0, 0)

    // Phase 0: if cursor is already at EOF, force indent target = 0 and
    // flush the indent stack. The next phase will drain any DEDENTs;
    // when current == target, _ln_match emits TK_EOF.
    jsr _lex_at_end
    bne !not_eof+
    lda #0
    sta LEX_INDENT_TARGET
    sta indent_depth
!not_eof:

    // Phase 1: drain any pending INDENT/DEDENT bursts.
    lda LEX_INDENT_CURRENT
    cmp LEX_INDENT_TARGET
    beq _ln_match
    bcs _ln_dedent
    inc LEX_INDENT_CURRENT
    lda #TK_INDENT
    jmp _ln_emit_empty
_ln_dedent:
    dec LEX_INDENT_CURRENT
    lda #TK_DEDENT
_ln_emit_empty:
    sta LEX_TOKEN_KIND
    lda LEX_PTR
    sta LEX_TOKEN_START
    sta LEX_TOKEN_END
    lda LEX_PTR+1
    sta LEX_TOKEN_START+1
    sta LEX_TOKEN_END+1
    jmp postamble

_ln_match:
    // Phase 2: skip leading spaces, mark token start, dispatch.
    jsr _lex_skip_spaces
    lda LEX_PTR
    sta LEX_TOKEN_START
    lda LEX_PTR+1
    sta LEX_TOKEN_START+1

    // EOF check (LEX_PTR == LEX_END).
    jsr _lex_at_end
    bne _ln_dispatch
    lda #TK_EOF
    sta LEX_TOKEN_KIND
    lda #0
    sta LEX_INDENT_TARGET    // unwind any open blocks via DEDENTs on next calls
    sta indent_depth         // also flush the stack so future re-entries start clean
    lda LEX_PTR
    sta LEX_TOKEN_END
    lda LEX_PTR+1
    sta LEX_TOKEN_END+1
    jmp postamble

_ln_dispatch:
    jsr _lex_dispatch_char   // handler returns via rts (see _lex_finish)
    jmp postamble

// -----------------------------------------------------------------------------
// _lex_dispatch_char — single dispatch site.
// Reads byte at LEX_PTR, jumps to its handler via rts trick (handler entries
// in the table are stored as `label - 1`).
// -----------------------------------------------------------------------------
_lex_dispatch_char:
    ldy #0
    lda (LEX_PTR),y
    bmi _lh_recover          // bytes ≥ $80 are illegal in source
    tax
    lda lex_jmp_hi,x
    pha
    lda lex_jmp_lo,x
    pha
    rts                      // → handler

// -----------------------------------------------------------------------------
// _lex_skip_spaces — advance LEX_PTR past run of spaces ($20). Tabs ($09)
// are intentionally not handled here; they fall through to dispatch and hit
// _lh_recover (matches DCPU's no-tabs policy).
// -----------------------------------------------------------------------------
_lex_skip_spaces:
!loop:
    jsr _lex_at_end
    beq !done+
    ldy #0
    lda (LEX_PTR),y
    cmp #' '
    bne !done+
    jsr _lex_advance_ptr
    jmp !loop-
!done:
    rts

// -----------------------------------------------------------------------------
// _lex_advance_ptr — LEX_PTR += 1.
// -----------------------------------------------------------------------------
_lex_advance_ptr:
    inc LEX_PTR
    bne !+
    inc LEX_PTR+1
!:
    rts

// -----------------------------------------------------------------------------
// _lex_at_end — Z=1 iff LEX_PTR == LEX_END (i.e. cursor is past last byte).
// Clobbers A.
// -----------------------------------------------------------------------------
_lex_at_end:
    lda LEX_PTR
    cmp LEX_END
    bne !no+
    lda LEX_PTR+1
    cmp LEX_END+1
!no:
    rts

// -----------------------------------------------------------------------------
// _lex_finish_advance — LEX_PTR += 1; fall through to _lex_finish.
// _lex_finish — LEX_TOKEN_END = LEX_PTR; rts.
// -----------------------------------------------------------------------------
_lex_finish_advance:
    jsr _lex_advance_ptr
_lex_finish:
    lda LEX_PTR
    sta LEX_TOKEN_END
    lda LEX_PTR+1
    sta LEX_TOKEN_END+1
    rts

// -----------------------------------------------------------------------------
// _lex_peek_next — peek the byte at LEX_PTR+1 (one past current cursor).
// Returns char in A, $00 if past end-of-buffer.
// Caller may invoke this without first advancing.
// -----------------------------------------------------------------------------
_lex_peek_next:
    // W3 = LEX_PTR + 1.
    clc
    lda LEX_PTR
    adc #1
    sta W3
    lda LEX_PTR+1
    adc #0
    sta W3+1
    // EOF check.
    lda W3
    cmp LEX_END
    bne !go+
    lda W3+1
    cmp LEX_END+1
    bne !go+
    lda #0
    rts
!go:
    ldy #0
    lda (W3),y
    rts

// -----------------------------------------------------------------------------
// _lh_recover — generic lex panic. Sets ERR_LEX in ERROR_CODE and jumps to
// error_handler. Used for illegal chars, unterminated strings, etc.
// -----------------------------------------------------------------------------
_lh_recover:
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler

// -----------------------------------------------------------------------------
// _lh_eof — NUL byte at LEX_PTR. Set kind = TK_EOF, force indent target = 0.
// (The EOF branch above already handles LEX_PTR == LEX_END; this fires when
// a NUL appears mid-buffer before LEX_END.)
// -----------------------------------------------------------------------------
_lh_eof:
    lda #TK_EOF
    sta LEX_TOKEN_KIND
    lda #0
    sta LEX_INDENT_TARGET
    jmp _lex_finish

// -----------------------------------------------------------------------------
// Punctuation single-char handlers — uniform shape.
// -----------------------------------------------------------------------------
_lh_lparen:
    lda #TK_LPAREN
    jmp _lh_punct1
_lh_rparen:
    lda #TK_RPAREN
    jmp _lh_punct1
_lh_lbrack:
    lda #TK_LBRACK
    jmp _lh_punct1
_lh_rbrack:
    lda #TK_RBRACK
    jmp _lh_punct1
_lh_lcurly:
    lda #TK_LCURLY
    jmp _lh_punct1
_lh_rcurly:
    lda #TK_RCURLY
    jmp _lh_punct1
_lh_comma:
    lda #TK_COMMA
    jmp _lh_punct1
_lh_colon:
    lda #TK_COLON
    jmp _lh_punct1
_lh_semicolon:
    lda #TK_SEMICOLON
    jmp _lh_punct1
_lh_at:
    lda #TK_AT
    jmp _lh_punct1
_lh_tilde:
    lda #TK_TILDE
    jmp _lh_punct1

_lh_punct1:
    sta LEX_TOKEN_KIND
    jmp _lex_finish_advance

// -----------------------------------------------------------------------------
// _lh_dot — '.' followed by digit → float; otherwise → TK_DOT.
// -----------------------------------------------------------------------------
_lh_dot:
    jsr _lex_peek_next
    cmp #'0'
    bcc !plain+
    cmp #'9'+1
    bcs !plain+
    // '.<digit>' — float literal starting with the dot.
    jmp _lh_float_from_dot
!plain:
    lda #TK_DOT
    sta LEX_TOKEN_KIND
    jmp _lex_finish_advance

// -----------------------------------------------------------------------------
// Augmented-assign helpers
// -----------------------------------------------------------------------------
// _lh_simple_augass_dispatch — the operator's plain kind is in A, the
// augass kind is in B0. Always sets LEX_TOKEN_KIND from A first, then peeks
// at the *next* byte. If '=', overwrites kind with B0 and consumes both.
//
// Pattern shared by + - % & | ^ — single-char operators with no alternate
// double form. Multi-char operators (* / < > = !) have bespoke handlers.
// -----------------------------------------------------------------------------
_lh_simple_augass:
    sta LEX_TOKEN_KIND
    jsr _lex_advance_ptr     // consume the operator char
    // EOF? then no augass.
    jsr _lex_at_end
    bne !go+
    jmp _lex_finish
!go:
    ldy #0
    lda (LEX_PTR),y
    cmp #'='
    beq !aug+
    jmp _lex_finish
!aug:
    lda B0                   // upgrade to augass kind
    sta LEX_TOKEN_KIND
    jmp _lex_finish_advance

_lh_plus:
    ldx #TK_PLUSEQ
    lda #TK_PLUS
    stx B0
    jmp _lh_simple_augass

_lh_minus:
    ldx #TK_MINUSEQ
    lda #TK_MINUS
    stx B0
    jmp _lh_simple_augass

_lh_percent:
    ldx #TK_PERCENTEQ
    lda #TK_PERCENT
    stx B0
    jmp _lh_simple_augass

_lh_amp:
    ldx #TK_AMPEQ
    lda #TK_AMP
    stx B0
    jmp _lh_simple_augass

_lh_pipe:
    ldx #TK_PIPEEQ
    lda #TK_PIPE
    stx B0
    jmp _lh_simple_augass

_lh_caret:
    ldx #TK_CARETEQ
    lda #TK_CARET
    stx B0
    jmp _lh_simple_augass

// -----------------------------------------------------------------------------
// _lh_star / _lh_slash / _lh_less / _lh_greater — paired-operator handlers.
// Each is a 4-way decision tree: bare op (e.g. `*`), op-with-equals (`*=`),
// doubled (`**`), and doubled-with-equals (`**=`). Bodies are byte-identical
// modulo five 1-byte parameters per op (the second-char to match + 4 token
// IDs), so they share a single body and table-driven dispatch.
//
// Entry is via a 5-byte thunk that loads the table index into X.
// -----------------------------------------------------------------------------
_lh_star:
    ldx #0
    jmp _lh_paired
_lh_slash:
    ldx #1
    jmp _lh_paired
_lh_less:
    ldx #2
    jmp _lh_paired
_lh_greater:
    ldx #3
    // fall through

_lh_paired:
    jsr _lex_advance_ptr         // consume the leading op char
    jsr _lex_at_end
    beq _lhp_plain
    ldy #0
    lda (LEX_PTR),y
    cmp #'='
    beq _lhp_eq
    cmp _paired_chars,x
    beq _lhp_dbl
_lhp_plain:
    lda _paired_tk_plain,x
    sta LEX_TOKEN_KIND
    jmp _lex_finish
_lhp_eq:
    lda _paired_tk_eq,x
    sta LEX_TOKEN_KIND
    jmp _lex_finish_advance
_lhp_dbl:
    jsr _lex_advance_ptr         // consume second op char
    jsr _lex_at_end
    beq _lhp_plain_dbl
    ldy #0
    lda (LEX_PTR),y
    cmp #'='
    bne _lhp_plain_dbl
    lda _paired_tk_dbleq,x
    sta LEX_TOKEN_KIND
    jmp _lex_finish_advance
_lhp_plain_dbl:
    lda _paired_tk_dbl,x
    sta LEX_TOKEN_KIND
    jmp _lex_finish

// Per-op parameter tables. Index x = 0 (*), 1 (/), 2 (<), 3 (>).
_paired_chars:    .byte '*',         '/',          '<',         '>'
_paired_tk_plain: .byte TK_STAR,     TK_SLASH,     TK_LT,       TK_GT
_paired_tk_eq:    .byte TK_STAREQ,   TK_SLASHEQ,   TK_LE,       TK_GE
_paired_tk_dbl:   .byte TK_POWER,    TK_DSLASH,    TK_LSHIFT,   TK_RSHIFT
_paired_tk_dbleq: .byte TK_POWEREQ,  TK_DSLASHEQ,  TK_LSHIFTEQ, TK_RSHIFTEQ

// -----------------------------------------------------------------------------
// _lh_equal — '=' or '=='.
// -----------------------------------------------------------------------------
_lh_equal:
    jsr _lex_advance_ptr
    jsr _lex_at_end
    beq !plain+
    ldy #0
    lda (LEX_PTR),y
    cmp #'='
    bne !plain+
    lda #TK_EQ
    sta LEX_TOKEN_KIND
    jmp _lex_finish_advance
!plain:
    lda #TK_ASSIGN
    sta LEX_TOKEN_KIND
    jmp _lex_finish

// -----------------------------------------------------------------------------
// _lh_bang — '!' must be followed by '=' (TK_NEQ); otherwise recover.
// -----------------------------------------------------------------------------
_lh_bang:
    jsr _lex_advance_ptr
    jsr _lex_at_end
    bne !go+
    jmp _lh_recover
!go:
    ldy #0
    lda (LEX_PTR),y
    cmp #'='
    beq !ok+
    jmp _lh_recover
!ok:
    lda #TK_NEQ
    sta LEX_TOKEN_KIND
    jmp _lex_finish_advance

// -----------------------------------------------------------------------------
// _lh_comment — '#' starts a comment to end-of-line. Skip past LF/CR/EOF
// then fall through to the newline handler so we still emit TK_NEWLINE and
// re-scan indent.
// -----------------------------------------------------------------------------
_lh_comment:
    jsr _lex_advance_ptr     // consume '#'
!loop:
    jsr _lex_at_end
    beq !at_end+
    ldy #0
    lda (LEX_PTR),y
    cmp #$0A
    beq _lh_newline
    cmp #$0D
    beq _lh_newline
    jsr _lex_advance_ptr
    jmp !loop-
!at_end:
    // Comment ran to EOF without LF. Synthesize a NEWLINE so block structure
    // unwinds cleanly.
    lda #TK_NEWLINE
    sta LEX_TOKEN_KIND
    lda #0
    sta LEX_INDENT_TARGET
    sta indent_depth
    jmp _lex_finish

// -----------------------------------------------------------------------------
// _lh_newline — emit TK_NEWLINE, then scan following bytes counting leading
// spaces to determine the next line's indent. Blank/comment-only lines are
// transparent: we keep scanning until a non-blank, non-comment line is
// found, and only then set LEX_INDENT_TARGET. EOF-before-content forces
// LEX_INDENT_TARGET = 0 so blocks unwind.
//
// LEX_TOKEN_KIND is set to TK_NEWLINE; the "span" of the newline is the LF
// byte itself. Cursor lands on the first non-blank char of the next line
// (or LEX_END at EOF).
// -----------------------------------------------------------------------------
_lh_newline:
    jsr _lex_advance_ptr     // consume the LF/CR
    // CRLF: if we just consumed CR and the next byte is LF, eat the LF too.
    // (We can't tell what we consumed from here, so we just look — if the
    // next byte is LF, drop it. If we'd just consumed LF and the next byte
    // is also LF that's a genuine blank line and we'll re-enter this handler
    // through the loop below.)
    jsr _lex_at_end
    beq !done_consume+
    ldy #0
    lda (LEX_PTR),y
    cmp #$0A
    bne !done_consume+
    // We need to distinguish "just ate CR, this is the LF of a CRLF" from
    // "just ate LF, this is the LF of a blank line". Look one byte back.
    // (LEX_PTR-1) was the byte we just consumed.
    sec
    lda LEX_PTR
    sbc #1
    sta W3
    lda LEX_PTR+1
    sbc #0
    sta W3+1
    ldy #0
    lda (W3),y
    cmp #$0D
    bne !done_consume+        // wasn't CR — leave the LF for the blank-line loop
    jsr _lex_advance_ptr      // consume LF half of CRLF
!done_consume:

_ln_scan_indent:
    // Count leading spaces on the next line into B1.
    lda #0
    sta B1
!count:
    jsr _lex_at_end
    beq !at_eof+
    ldy #0
    lda (LEX_PTR),y
    cmp #' '
    bne !done+
    inc B1
    jsr _lex_advance_ptr
    jmp !count-
!done:
    // Now look at the first non-space char.
    cmp #$0A
    beq !blank+
    cmp #$0D
    beq !blank+
    cmp #'#'
    beq !comment+
    // Real content. Translate column count B1 to a depth via the indent
    // stack: walk down popping levels whose column count > B1, then if the
    // top is < B1 push a new level. Final depth → LEX_INDENT_TARGET.
    jsr _lex_set_indent_target
    lda #TK_NEWLINE
    sta LEX_TOKEN_KIND
    jmp _lex_finish
!blank:
    // Eat the LF/CR (and possibly its CRLF partner).
    jsr _lex_advance_ptr
    // CRLF detection identical to above.
    jsr _lex_at_end
    beq _ln_scan_indent
    ldy #0
    lda (LEX_PTR),y
    cmp #$0A
    bne _ln_scan_indent
    sec
    lda LEX_PTR
    sbc #1
    sta W3
    lda LEX_PTR+1
    sbc #0
    sta W3+1
    ldy #0
    lda (W3),y
    cmp #$0D
    bne _ln_scan_indent
    jsr _lex_advance_ptr
    jmp _ln_scan_indent
!comment:
    // Skip comment to LF/CR/EOF; then re-enter scan loop.
    jsr _lex_advance_ptr     // consume '#'
!cloop:
    jsr _lex_at_end
    beq !at_eof+
    ldy #0
    lda (LEX_PTR),y
    cmp #$0A
    beq !blank-
    cmp #$0D
    beq !blank-
    jsr _lex_advance_ptr
    jmp !cloop-
!at_eof:
    // Hit EOF while skipping blanks/comments. Force depth back to 0 (drains
    // the stack); emit NEWLINE — drain pending DEDENTs on subsequent calls.
    lda #0
    sta LEX_INDENT_TARGET
    sta indent_depth
    lda #TK_NEWLINE
    sta LEX_TOKEN_KIND
    jmp _lex_finish

// -----------------------------------------------------------------------------
// _lh_digit — decimal/hex/bin/float distinguished after first 1..2 chars.
//
// Cases:
//   '0x' or '0X' followed by hex digit → TK_HEX, scan until non-hex
//   '0b' or '0B' followed by 0|1       → TK_BIN, scan until non-binary
//   first char is digit, run until non-digit, then peek:
//     '.' or 'e'/'E'                   → TK_FLOAT (delegate to float FSM)
//     otherwise                        → TK_INT
// -----------------------------------------------------------------------------
_lh_digit:
    // Check for 0x / 0b prefix.
    ldy #0
    lda (LEX_PTR),y
    cmp #'0'
    bne _ldig_dec_start
    jsr _lex_peek_next
    cmp #$78                 // 'x'
    beq _ldig_hex_pfx
    cmp #$58                 // 'X'
    beq _ldig_hex_pfx
    cmp #$62                 // 'b'
    beq _ldig_bin_pfx
    cmp #$42                 // 'B'
    beq _ldig_bin_pfx
    // Plain decimal starting with '0'.

_ldig_dec_start:
_ldig_dec_loop:
    jsr _lex_advance_ptr
    jsr _lex_at_end
    beq _ldig_dec_done
    ldy #0
    lda (LEX_PTR),y
    cmp #'.'
    beq _ldig_dec_float_jmp
    cmp #$65                 // 'e'
    beq _ldig_dec_float_jmp
    cmp #$45                 // 'E'
    beq _ldig_dec_float_jmp
    cmp #'0'
    bcc _ldig_dec_done
    cmp #'9'+1
    bcs _ldig_dec_done
    jmp _ldig_dec_loop
_ldig_dec_float_jmp:
    jmp _ldig_to_float
_ldig_dec_done:
    lda #TK_INT
    sta LEX_TOKEN_KIND
    jmp _lex_finish

_ldig_hex_pfx:
    jsr _lex_advance_ptr     // consume '0'
    jsr _lex_advance_ptr     // consume 'x'/'X'
_ldig_hex_loop:
    jsr _lex_at_end
    beq _ldig_hex_done
    ldy #0
    lda (LEX_PTR),y
    cmp #'0'
    bcc _ldig_hex_done
    cmp #'9'+1
    bcc _ldig_hex_next
    cmp #$41                 // 'A'
    bcc _ldig_hex_done
    cmp #$47                 // 'F'+1
    bcc _ldig_hex_next
    cmp #$61                 // 'a'
    bcc _ldig_hex_done
    cmp #$67                 // 'f'+1
    bcc _ldig_hex_next
    jmp _ldig_hex_done
_ldig_hex_next:
    jsr _lex_advance_ptr
    jmp _ldig_hex_loop
_ldig_hex_done:
    lda #TK_HEX
    sta LEX_TOKEN_KIND
    jmp _lex_finish

_ldig_bin_pfx:
    jsr _lex_advance_ptr     // consume '0'
    jsr _lex_advance_ptr     // consume 'b'/'B'
_ldig_bin_loop:
    jsr _lex_at_end
    beq _ldig_bin_done
    ldy #0
    lda (LEX_PTR),y
    cmp #'0'
    beq !ok+
    cmp #'1'
    bne _ldig_bin_done
!ok:
    jsr _lex_advance_ptr
    jmp _ldig_bin_loop
_ldig_bin_done:
    lda #TK_BIN
    sta LEX_TOKEN_KIND
    jmp _lex_finish

// -----------------------------------------------------------------------------
// Float scanner — entered from _lh_digit when '.' or 'e'/'E' appears mid-
// integer, OR from _lh_dot when '.' is followed by a digit.
// LEX_TOKEN_START already points to the start of the literal.
// LEX_PTR may be anywhere in the literal — rewind to LEX_TOKEN_START and
// run the FSM from there.
// -----------------------------------------------------------------------------
.const FP_START   = $01
.const FP_DIGIT_W = $02     // digit-whole (integer part)
.const FP_DOT     = $04     // just saw '.'
.const FP_DIGIT_F = $08     // digit-fraction
.const FP_E       = $10     // just saw 'e'/'E'
.const FP_EXP_SGN = $20     // just saw '+'/'-' after 'e'
.const FP_EXP_D   = $40     // exponent digit

_ldig_to_float:
_lh_float_from_dot:
    // Rewind LEX_PTR to LEX_TOKEN_START so the FSM scans the whole literal.
    lda LEX_TOKEN_START
    sta LEX_PTR
    lda LEX_TOKEN_START+1
    sta LEX_PTR+1
    lda #FP_START
    sta B1                   // FSM state

_lflt_loop:
    // EOF?
    jsr _lex_at_end
    beq _lflt_finish
    ldy #0
    lda (LEX_PTR),y

    // Digit?
    cmp #'0'
    bcc !nondigit+
    cmp #'9'+1
    bcs !nondigit+
    // Digit handling depends on state.
    lda B1
    and #(FP_E | FP_EXP_SGN)
    beq !try_frac+
    lda #FP_EXP_D
    sta B1
    jmp !consume+
!try_frac:
    lda B1
    and #(FP_DOT | FP_DIGIT_F)
    beq !try_whole+
    lda #FP_DIGIT_F
    sta B1
    jmp !consume+
!try_whole:
    lda B1
    and #(FP_START | FP_DIGIT_W)
    beq _lflt_finish         // wrong state — emit what we have
    lda #FP_DIGIT_W
    sta B1
!consume:
    jsr _lex_advance_ptr
    jmp _lflt_loop

!nondigit:
    cmp #'.'
    beq _lflt_dot
    cmp #$65                 // 'e'
    beq _lflt_e
    cmp #$45                 // 'E'
    beq _lflt_e
    cmp #'+'
    beq _lflt_sign
    cmp #'-'
    beq _lflt_sign
    jmp _lflt_finish

_lflt_dot:
    lda B1
    and #(FP_START | FP_DIGIT_W)
    beq _lflt_finish
    lda #FP_DOT
    sta B1
    jsr _lex_advance_ptr
    jmp _lflt_loop

_lflt_e:
    lda B1
    and #(FP_DIGIT_W | FP_DIGIT_F)
    beq _lflt_finish
    lda #FP_E
    sta B1
    jsr _lex_advance_ptr
    jmp _lflt_loop

_lflt_sign:
    lda B1
    cmp #FP_E
    bne _lflt_finish
    lda #FP_EXP_SGN
    sta B1
    jsr _lex_advance_ptr
    jmp _lflt_loop

_lflt_finish:
    // Validity: must end in DIGIT_W (e.g. "1"), DIGIT_F ("1.5"), DOT ("1.")
    // or EXP_D ("1e5"). Malformed: FP_START, FP_E ("1e"), FP_EXP_SGN ("1e+").
    lda B1
    and #(FP_DIGIT_W | FP_DIGIT_F | FP_DOT | FP_EXP_D)
    bne !ok+
    jmp _lh_recover
!ok:
    lda #TK_FLOAT_LIT
    sta LEX_TOKEN_KIND
    jmp _lex_finish

// Trampoline used by string handlers below where _lh_recover is too far
// for a relative branch. 3 bytes; saves ~22 across the handlers.
_lh_recover_far:
    jmp _lh_recover

// -----------------------------------------------------------------------------
// _lh_string — string literal between matching " or '.
// LEX_TOKEN_START points to the OPENING quote (before consume). After this
// handler, LEX_TOKEN_START is advanced past the open quote so the span
// excludes both quotes; cursor lands past the closing quote.
//
// Escapes are recognized but not decoded (decode happens in
// lexer_get_token_as_string). Allowed escapes: \n \t \r \\ \" \' \0 \xNN.
// -----------------------------------------------------------------------------
_lh_string:
    // Stash quote char in B0.
    ldy #0
    lda (LEX_PTR),y
    sta B0
    jsr _lex_advance_ptr     // consume opening quote
    // Bump TOKEN_START past the opening quote so the span excludes it.
    lda LEX_PTR
    sta LEX_TOKEN_START
    lda LEX_PTR+1
    sta LEX_TOKEN_START+1
_lstr_loop:
    jsr _lex_at_end
    beq _lh_recover_far      // unterminated string
    ldy #0
    lda (LEX_PTR),y
    cmp #$0A
    beq _lh_recover_far      // no multiline strings
    cmp #$0D
    beq _lh_recover_far
    cmp #$5C                 // '\'
    beq _lstr_escape
    cmp B0
    beq _lstr_close
    jsr _lex_advance_ptr
    jmp _lstr_loop

_lstr_escape:
    // Validate the escape char (decode is deferred).
    jsr _lex_advance_ptr     // past '\\'
    jsr _lex_at_end
    beq _lh_recover_far
    ldy #0
    lda (LEX_PTR),y
    cmp #$6E                 // 'n'
    beq _lstr_esc_ok
    cmp #$74                 // 't'
    beq _lstr_esc_ok
    cmp #$72                 // 'r'
    beq _lstr_esc_ok
    cmp #$5C                 // '\'
    beq _lstr_esc_ok
    cmp #'"'
    beq _lstr_esc_ok
    cmp #'\''
    beq _lstr_esc_ok
    cmp #'0'
    beq _lstr_esc_ok
    cmp #$78                 // 'x'
    beq _lstr_esc_hex
    jmp _lh_recover
_lstr_esc_ok:
    jsr _lex_advance_ptr
    jmp _lstr_loop
_lstr_esc_hex:
    jsr _lex_advance_ptr     // past 'x'
    // need 2 hex digits
    jsr _lstr_eat_hex
    jsr _lstr_eat_hex
    jmp _lstr_loop

// Local trampoline for the hex-eat routine — the main _lh_recover is too
// far for the byte-class checks below.
_lh_recover_far2:
    jmp _lh_recover

_lstr_eat_hex:
    jsr _lex_at_end
    beq _lh_recover_far2
    ldy #0
    lda (LEX_PTR),y
    cmp #'0'
    bcc _lh_recover_far2
    cmp #'9'+1
    bcc !ok+
    cmp #$41                 // 'A'
    bcc _lh_recover_far2
    cmp #$47                 // 'F'+1
    bcc !ok+
    cmp #$61                 // 'a'
    bcc _lh_recover_far2
    cmp #$67                 // 'f'+1
    bcc !ok+
    jmp _lh_recover
!ok:
    jmp _lex_advance_ptr     // tail-jump (rts'es to caller)

_lstr_close:
    // LEX_TOKEN_END = LEX_PTR (excludes closing quote); cursor advances past it.
    lda LEX_PTR
    sta LEX_TOKEN_END
    lda LEX_PTR+1
    sta LEX_TOKEN_END+1
    jsr _lex_advance_ptr
    lda #TK_STR
    sta LEX_TOKEN_KIND
    rts

// -----------------------------------------------------------------------------
// _lh_letter — identifier scanner. Greedy span of [_A-Za-z0-9]. After the
// span, length-bucketed keyword match: if length 2..8, look up in the
// per-length bucket; else (length 1, or > 8) → TK_NAME.
// -----------------------------------------------------------------------------
_lh_letter:
_llet_loop:
    jsr _lex_advance_ptr
    jsr _lex_at_end
    beq _llet_done
    ldy #0
    lda (LEX_PTR),y
    // Letter / digit / underscore?
    cmp #$5F                 // '_'
    beq _llet_loop
    cmp #'0'
    bcc _llet_done
    cmp #'9'+1
    bcc _llet_loop
    cmp #$41                 // 'A'
    bcc _llet_done
    cmp #$5B                 // 'Z'+1
    bcc _llet_loop
    cmp #$61                 // 'a'
    bcc _llet_done
    cmp #$7B                 // 'z'+1
    bcc _llet_loop
_llet_done:
    // LEX_TOKEN_END = LEX_PTR (write now so keyword match can read length).
    lda LEX_PTR
    sta LEX_TOKEN_END
    lda LEX_PTR+1
    sta LEX_TOKEN_END+1

    // length = LEX_TOKEN_END - LEX_TOKEN_START (8-bit suffices: identifiers
    // longer than 255 chars aren't going to fit in our world). B1 = length.
    sec
    lda LEX_TOKEN_END
    sbc LEX_TOKEN_START
    sta B1
    lda LEX_TOKEN_END+1
    sbc LEX_TOKEN_START+1
    bne _llet_too_long       // hi byte non-zero → way over 8

    lda B1
    cmp #2
    bcc _llet_name           // length 0 or 1 → no keyword
    cmp #9
    bcs _llet_too_long       // length > 8 → no keyword

    // Look up bucket pointer (length-1 indexed; bucket_2 lives at index 1).
    sec
    sbc #1                   // X = length - 1; valid range 1..7
    tax
    lda kw_bucket_lo,x
    sta W2
    lda kw_bucket_hi,x
    sta W2+1

    // Walk bucket: each record is `length × char_byte` then `kind_byte`;
    // sentinel = $00 byte (no keyword starts with NUL).
    //
    // Inner loop uses two indirect-y loads with different bases:
    //   bucket char: (W2),y  with Y = record_start + chars_matched
    //   token char : (LEX_TOKEN_START),y  with Y = chars_matched
    // We swap Y between the two via B2 (saved record_start) + X (chars_matched).
    ldy #0
_llet_match_record:
    lda (W2),y
    beq _llet_name           // sentinel → no keyword match in bucket
    sty B2                   // remember record start for skip-on-mismatch
    ldx #0                   // X = chars matched within this record
_llet_match_char:
    lda (W2),y               // bucket char
    sta B3
    txa
    tay
    lda (LEX_TOKEN_START),y  // token char at offset X
    cmp B3
    bne _llet_skip_record
    inx
    cpx B1
    beq _llet_match_full
    txa
    clc
    adc B2                   // bucket Y = record_start + chars_matched
    tay
    jmp _llet_match_char
_llet_match_full:
    // All chars matched — kind byte is at bucket offset B2 + B1.
    lda B2
    clc
    adc B1
    tay
    lda (W2),y
    sta LEX_TOKEN_KIND
    rts
_llet_skip_record:
    // Skip past remaining chars of this record + kind byte: Y = B2 + B1 + 1.
    lda B2
    clc
    adc B1
    tay
    iny
    jmp _llet_match_record

_llet_too_long:
_llet_name:
    lda #TK_NAME
    sta LEX_TOKEN_KIND
    rts

// -----------------------------------------------------------------------------
// Char dispatch table — parallel low/high-byte tables, 128 entries each.
// Entries hold (handler_label - 1) so the rts dispatcher lands on the
// handler.
// -----------------------------------------------------------------------------
lex_jmp_lo:
    .byte <(_lh_eof - 1)            //  $00 NUL
    .byte <(_lh_recover - 1)        //  $01
    .byte <(_lh_recover - 1)        //  $02
    .byte <(_lh_recover - 1)        //  $03
    .byte <(_lh_recover - 1)        //  $04
    .byte <(_lh_recover - 1)        //  $05
    .byte <(_lh_recover - 1)        //  $06
    .byte <(_lh_recover - 1)        //  $07 BEL
    .byte <(_lh_recover - 1)        //  $08 BS
    .byte <(_lh_recover - 1)        //  $09 HT (tab — not allowed)
    .byte <(_lh_newline - 1)        //  $0A LF
    .byte <(_lh_recover - 1)        //  $0B
    .byte <(_lh_recover - 1)        //  $0C
    .byte <(_lh_newline - 1)        //  $0D CR
    .byte <(_lh_recover - 1)        //  $0E
    .byte <(_lh_recover - 1)        //  $0F
    .byte <(_lh_recover - 1)        //  $10
    .byte <(_lh_recover - 1)        //  $11
    .byte <(_lh_recover - 1)        //  $12
    .byte <(_lh_recover - 1)        //  $13
    .byte <(_lh_recover - 1)        //  $14
    .byte <(_lh_recover - 1)        //  $15
    .byte <(_lh_recover - 1)        //  $16
    .byte <(_lh_recover - 1)        //  $17
    .byte <(_lh_recover - 1)        //  $18
    .byte <(_lh_recover - 1)        //  $19
    .byte <(_lh_recover - 1)        //  $1A
    .byte <(_lh_recover - 1)        //  $1B ESC
    .byte <(_lh_recover - 1)        //  $1C
    .byte <(_lh_recover - 1)        //  $1D
    .byte <(_lh_recover - 1)        //  $1E
    .byte <(_lh_recover - 1)        //  $1F
    .byte <(_lh_recover - 1)        //  $20 ' ' (skipped pre-dispatch)
    .byte <(_lh_bang - 1)           //  $21 !
    .byte <(_lh_string - 1)         //  $22 "
    .byte <(_lh_comment - 1)        //  $23 #
    .byte <(_lh_recover - 1)        //  $24 $
    .byte <(_lh_percent - 1)        //  $25 %
    .byte <(_lh_amp - 1)            //  $26 &
    .byte <(_lh_string - 1)         //  $27 '
    .byte <(_lh_lparen - 1)         //  $28 (
    .byte <(_lh_rparen - 1)         //  $29 )
    .byte <(_lh_star - 1)           //  $2A *
    .byte <(_lh_plus - 1)           //  $2B +
    .byte <(_lh_comma - 1)          //  $2C ,
    .byte <(_lh_minus - 1)          //  $2D -
    .byte <(_lh_dot - 1)            //  $2E .
    .byte <(_lh_slash - 1)          //  $2F /
    .byte <(_lh_digit - 1)          //  $30 0
    .byte <(_lh_digit - 1)          //  $31 1
    .byte <(_lh_digit - 1)          //  $32 2
    .byte <(_lh_digit - 1)          //  $33 3
    .byte <(_lh_digit - 1)          //  $34 4
    .byte <(_lh_digit - 1)          //  $35 5
    .byte <(_lh_digit - 1)          //  $36 6
    .byte <(_lh_digit - 1)          //  $37 7
    .byte <(_lh_digit - 1)          //  $38 8
    .byte <(_lh_digit - 1)          //  $39 9
    .byte <(_lh_colon - 1)          //  $3A :
    .byte <(_lh_semicolon - 1)      //  $3B ;
    .byte <(_lh_less - 1)           //  $3C <
    .byte <(_lh_equal - 1)          //  $3D =
    .byte <(_lh_greater - 1)        //  $3E >
    .byte <(_lh_recover - 1)        //  $3F ?
    .byte <(_lh_at - 1)             //  $40 @
    .byte <(_lh_letter - 1)         //  $41 A
    .byte <(_lh_letter - 1)         //  $42 B
    .byte <(_lh_letter - 1)         //  $43 C
    .byte <(_lh_letter - 1)         //  $44 D
    .byte <(_lh_letter - 1)         //  $45 E
    .byte <(_lh_letter - 1)         //  $46 F
    .byte <(_lh_letter - 1)         //  $47 G
    .byte <(_lh_letter - 1)         //  $48 H
    .byte <(_lh_letter - 1)         //  $49 I
    .byte <(_lh_letter - 1)         //  $4A J
    .byte <(_lh_letter - 1)         //  $4B K
    .byte <(_lh_letter - 1)         //  $4C L
    .byte <(_lh_letter - 1)         //  $4D M
    .byte <(_lh_letter - 1)         //  $4E N
    .byte <(_lh_letter - 1)         //  $4F O
    .byte <(_lh_letter - 1)         //  $50 P
    .byte <(_lh_letter - 1)         //  $51 Q
    .byte <(_lh_letter - 1)         //  $52 R
    .byte <(_lh_letter - 1)         //  $53 S
    .byte <(_lh_letter - 1)         //  $54 T
    .byte <(_lh_letter - 1)         //  $55 U
    .byte <(_lh_letter - 1)         //  $56 V
    .byte <(_lh_letter - 1)         //  $57 W
    .byte <(_lh_letter - 1)         //  $58 X
    .byte <(_lh_letter - 1)         //  $59 Y
    .byte <(_lh_letter - 1)         //  $5A Z
    .byte <(_lh_lbrack - 1)         //  $5B [
    .byte <(_lh_recover - 1)        //  $5C \
    .byte <(_lh_rbrack - 1)         //  $5D ]
    .byte <(_lh_caret - 1)          //  $5E ^
    .byte <(_lh_letter - 1)         //  $5F _
    .byte <(_lh_recover - 1)        //  $60 `
    .byte <(_lh_letter - 1)         //  $61 a
    .byte <(_lh_letter - 1)         //  $62 b
    .byte <(_lh_letter - 1)         //  $63 c
    .byte <(_lh_letter - 1)         //  $64 d
    .byte <(_lh_letter - 1)         //  $65 e
    .byte <(_lh_letter - 1)         //  $66 f
    .byte <(_lh_letter - 1)         //  $67 g
    .byte <(_lh_letter - 1)         //  $68 h
    .byte <(_lh_letter - 1)         //  $69 i
    .byte <(_lh_letter - 1)         //  $6A j
    .byte <(_lh_letter - 1)         //  $6B k
    .byte <(_lh_letter - 1)         //  $6C l
    .byte <(_lh_letter - 1)         //  $6D m
    .byte <(_lh_letter - 1)         //  $6E n
    .byte <(_lh_letter - 1)         //  $6F o
    .byte <(_lh_letter - 1)         //  $70 p
    .byte <(_lh_letter - 1)         //  $71 q
    .byte <(_lh_letter - 1)         //  $72 r
    .byte <(_lh_letter - 1)         //  $73 s
    .byte <(_lh_letter - 1)         //  $74 t
    .byte <(_lh_letter - 1)         //  $75 u
    .byte <(_lh_letter - 1)         //  $76 v
    .byte <(_lh_letter - 1)         //  $77 w
    .byte <(_lh_letter - 1)         //  $78 x
    .byte <(_lh_letter - 1)         //  $79 y
    .byte <(_lh_letter - 1)         //  $7A z
    .byte <(_lh_lcurly - 1)         //  $7B {
    .byte <(_lh_pipe - 1)           //  $7C |
    .byte <(_lh_rcurly - 1)         //  $7D }
    .byte <(_lh_tilde - 1)          //  $7E ~
    .byte <(_lh_recover - 1)        //  $7F DEL

lex_jmp_hi:
    .byte >(_lh_eof - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_newline - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_newline - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_bang - 1)
    .byte >(_lh_string - 1)
    .byte >(_lh_comment - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_percent - 1)
    .byte >(_lh_amp - 1)
    .byte >(_lh_string - 1)
    .byte >(_lh_lparen - 1)
    .byte >(_lh_rparen - 1)
    .byte >(_lh_star - 1)
    .byte >(_lh_plus - 1)
    .byte >(_lh_comma - 1)
    .byte >(_lh_minus - 1)
    .byte >(_lh_dot - 1)
    .byte >(_lh_slash - 1)
    .byte >(_lh_digit - 1)
    .byte >(_lh_digit - 1)
    .byte >(_lh_digit - 1)
    .byte >(_lh_digit - 1)
    .byte >(_lh_digit - 1)
    .byte >(_lh_digit - 1)
    .byte >(_lh_digit - 1)
    .byte >(_lh_digit - 1)
    .byte >(_lh_digit - 1)
    .byte >(_lh_digit - 1)
    .byte >(_lh_colon - 1)
    .byte >(_lh_semicolon - 1)
    .byte >(_lh_less - 1)
    .byte >(_lh_equal - 1)
    .byte >(_lh_greater - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_at - 1)
    .byte >(_lh_letter - 1)         // A
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_lbrack - 1)
    .byte >(_lh_recover - 1)
    .byte >(_lh_rbrack - 1)
    .byte >(_lh_caret - 1)
    .byte >(_lh_letter - 1)         // _
    .byte >(_lh_recover - 1)
    .byte >(_lh_letter - 1)         // a
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_letter - 1)
    .byte >(_lh_lcurly - 1)
    .byte >(_lh_pipe - 1)
    .byte >(_lh_rcurly - 1)
    .byte >(_lh_tilde - 1)
    .byte >(_lh_recover - 1)

// -----------------------------------------------------------------------------
// lexer_get_token_as_string — materialize the current token's span as a
// fresh TYPE_STR.
//
//   in:  no args. Reads LEX_TOKEN_START..LEX_TOKEN_END (and LEX_SRC_HANDLE
//        for re-derefs after alloc).
//   out: RV = TYPE_STR handle whose payload is a byte-for-byte copy of the
//        token span. For TK_STR tokens the span excludes the surrounding
//        quotes (set up by `_lh_string`) but ESCAPE SEQUENCES ARE NOT YET
//        DECODED — the raw `\\n` etc. survive in the result. (Stage 8 will
//        layer a decode pass on top once it cares.)
//
// V4' wrapper. `str_alloc` may trigger gc_compact and relocate the source
// payload; LEX_PTR / LEX_END / LEX_TOKEN_* are kept valid by the `gc_collect`
// hook (gc.asm), so this routine no longer needs per-call offset bookkeeping.
// Token length must be < 256 bytes (asserted by the size-fits-in-byte check);
// longer tokens will be truncated by the copy loop today — fix when needed.
// -----------------------------------------------------------------------------
lexer_get_token_as_string:
    preamble_args(0, 0)

    // ALLOC_SIZE = LEX_TOKEN_END - LEX_TOKEN_START (span byte length). The
    // pointer subtraction is invariant under gc_compact (both pointers shift
    // by the same delta), so we compute it once up front.
    sec
    lda LEX_TOKEN_END
    sbc LEX_TOKEN_START
    sta ALLOC_SIZE
    lda LEX_TOKEN_END+1
    sbc LEX_TOKEN_START+1
    sta ALLOC_SIZE+1

    // Allocate the result string. The gc_collect hook in gc.asm handles
    // any payload relocation: by the time str_alloc returns, LEX_PTR /
    // LEX_END / LEX_TOKEN_* have been rebased against the (post-compact)
    // source payload base. No per-routine offset bookkeeping needed.
    jsr str_alloc                // RV = handle to fresh TYPE_STR
    rs_push(RV)                  // root through subsequent derefs

    // Copy span into the new TYPE_STR's payload. For TK_STR, decode escape
    // sequences into raw bytes; for other kinds (NAME / INT / HEX / BIN /
    // FLOAT_LIT) we copy verbatim — the parser re-scans those spans for
    // value extraction.
    lda LEX_TOKEN_START
    sta W3
    lda LEX_TOKEN_START+1
    sta W3+1

    rs_peek(W0)                  // W0 = new TYPE_STR handle (still on RS)
    jsr deref_W0_to_W2           // W2 = new payload base

    lda LEX_TOKEN_KIND
    cmp #TK_STR
    beq _lgts_decode

    // Raw copy for non-string kinds. 16-bit count via ALLOC_SIZE word.
    lda ALLOC_SIZE
    sta B0
    lda ALLOC_SIZE+1
    sta B1
!cloop:
    lda B0
    ora B1
    beq !cdone+
    ldy #0
    lda (W3),y
    sta (W2),y
    jsr inc_w2_w
    jsr inc_w3_w
    jsr dec_b01_w
    jmp !cloop-
!cdone:
    jmp postamble

// --- TK_STR: decode escape sequences ---------------------------------------
// W3 = src ptr (advances per byte read), W2 = dst ptr (advances per byte
// written). B0:B1 = decoded length counter (word). B2:B3 = remaining input
// bytes (word, decremented as we consume the source).
//
// Decoded length ≤ source length (each escape collapses 2-4 bytes → 1).
// We over-allocated based on source length; after decoding, patch the
// heap object's O_LEN to the actual count.
_lgts_decode:
    lda ALLOC_SIZE
    sta B2
    lda ALLOC_SIZE+1
    sta B3                       // B2:B3 = source bytes remaining (word)
    lda #0
    sta B0
    sta B1                       // B0:B1 = decoded byte count (word)

_lgts_dec_loop:
    lda B2
    ora B3
    bne !go+
    jmp _lgts_dec_done
!go:
    ldy #0
    lda (W3),y                   // c = *src
    jsr _lgts_advance_src        // src++; B2:B3--
    cmp #$5C                     // '\'
    beq _lgts_dec_escape

_lgts_emit:
    // Store A at *dst, advance dst, count (word).
    ldy #0
    sta (W2),y
    jsr inc_w2_w
    inc B0
    bne !sk+
    inc B1
!sk:
    jmp _lgts_dec_loop

_lgts_dec_escape:
    // Read the escape kind from src[next].
    lda B2
    ora B3
    beq _lgts_dec_done            // truncated — shouldn't happen (lexer validated)
    ldy #0
    lda (W3),y
    jsr _lgts_advance_src

    cmp #$6E                      // 'n'
    bne !x+
    lda #$0A
    jmp _lgts_emit
!x:
    cmp #$74                      // 't'
    bne !x+
    lda #$09
    jmp _lgts_emit
!x:
    cmp #$72                      // 'r'
    bne !x+
    lda #$0D
    jmp _lgts_emit
!x:
    cmp #$5C                      // '\'
    bne !x+
    lda #$5C
    jmp _lgts_emit
!x:
    cmp #$22                      // '"'
    bne !x+
    lda #$22
    jmp _lgts_emit
!x:
    cmp #$27                      // "'"
    bne !x+
    lda #$27
    jmp _lgts_emit
!x:
    cmp #$30                      // '0'
    bne !x+
    lda #$00
    jmp _lgts_emit
!x:
    cmp #$78                      // 'x'
    beq _lgts_hex_escape
    // Should be unreachable — lexer validated all escapes already.
    jmp _lh_recover

_lgts_hex_escape:
    // Two hex digits → byte.
    jsr _lgts_read_hex_nibble    // A = high nibble (0..15)
    asl
    asl
    asl
    asl
    sta B4                        // high nibble shifted into upper 4 bits
    jsr _lgts_read_hex_nibble    // A = low nibble
    ora B4
    jmp _lgts_emit

_lgts_dec_done:
    // Patch the heap object's O_LEN to the actual decoded byte count (word).
    rs_peek(W0)
    ldy #H_PTR
    lda (W0),y
    sta W3
    iny
    lda (W0),y
    sta W3+1
    ldy #O_LEN
    lda B0
    sta (W3),y
    iny
    lda B1
    sta (W3),y
    jmp postamble

// Helper: advance W3 by 1, decrement source-remaining word B2:B3.
// Caller relies on A being preserved (holds the just-read source byte).
_lgts_advance_src:
    pha
    jsr inc_w3_w
    lda B2
    bne !sk+
    dec B3
!sk:
    dec B2
    pla
    rts

// Helper: read one hex digit at *src, decode 0..15, advance src.
_lgts_read_hex_nibble:
    ldy #0
    lda (W3),y
    pha
    jsr _lgts_advance_src
    pla
    cmp #$3A                      // '9'+1
    bcs _lgts_alpha
    sec
    sbc #$30                      // '0'
    rts
_lgts_alpha:
    cmp #$61                      // 'a'
    bcc _lgts_upper
    sec
    sbc #$61                      // 'a'
    clc
    adc #10
    rts
_lgts_upper:
    sec
    sbc #$41                      // 'A'
    clc
    adc #10
    rts

// -----------------------------------------------------------------------------
// _lex_load_base — _lex_base = (LEX_SRC_HANDLE).H_PTR.
// Caller is responsible for guarding against LEX_SRC_HANDLE == 0; this
// routine just reads the H_PTR slot via indirect-Y.
//
// Clobbers: A, Y.
// -----------------------------------------------------------------------------
_lex_load_base:
    ldy #H_PTR
    lda (LEX_SRC_HANDLE),y
    sta _lex_base
    iny
    lda (LEX_SRC_HANDLE),y
    sta _lex_base+1
    rts

// _lex_to_offsets / _lex_from_offsets — bidirectional rebase of the four
// LEX_PTR / LEX_END / LEX_TOKEN_START / LEX_TOKEN_END payload pointers.
//
// _lex_to_offsets: each LEX_* -= _lex_base, leaving offsets in the same ZP
// cells (cells temporarily hold offsets, not absolute addresses).
// _lex_from_offsets: each LEX_* += _lex_base, restoring absolute addresses.
//
// Used in three places:
//   • gc_collect: _lex_to_offsets pre-compact, _lex_from_offsets post-compact.
//   • lexer_save / lexer_restore: snapshots store offsets so they survive
//     a compact between save and restore.
//   • lexer_get_token_as_string: rebase across str_alloc.
//
// Clobbers: A.
// -----------------------------------------------------------------------------
_lex_to_offsets:
    sec
    lda LEX_PTR
    sbc _lex_base
    sta LEX_PTR
    lda LEX_PTR+1
    sbc _lex_base+1
    sta LEX_PTR+1
    sec
    lda LEX_END
    sbc _lex_base
    sta LEX_END
    lda LEX_END+1
    sbc _lex_base+1
    sta LEX_END+1
    sec
    lda LEX_TOKEN_START
    sbc _lex_base
    sta LEX_TOKEN_START
    lda LEX_TOKEN_START+1
    sbc _lex_base+1
    sta LEX_TOKEN_START+1
    sec
    lda LEX_TOKEN_END
    sbc _lex_base
    sta LEX_TOKEN_END
    lda LEX_TOKEN_END+1
    sbc _lex_base+1
    sta LEX_TOKEN_END+1
    rts

_lex_from_offsets:
    clc
    lda LEX_PTR
    adc _lex_base
    sta LEX_PTR
    lda LEX_PTR+1
    adc _lex_base+1
    sta LEX_PTR+1
    clc
    lda LEX_END
    adc _lex_base
    sta LEX_END
    lda LEX_END+1
    adc _lex_base+1
    sta LEX_END+1
    clc
    lda LEX_TOKEN_START
    adc _lex_base
    sta LEX_TOKEN_START
    lda LEX_TOKEN_START+1
    adc _lex_base+1
    sta LEX_TOKEN_START+1
    clc
    lda LEX_TOKEN_END
    adc _lex_base
    sta LEX_TOKEN_END
    lda LEX_TOKEN_END+1
    adc _lex_base+1
    sta LEX_TOKEN_END+1
    rts

// 2-byte payload-base scratch shared by the three rebase clients above.
// Loaded by _lex_load_base; consumed by _lex_to_offsets/_lex_from_offsets.
_lex_base:
    .byte 0, 0

// -----------------------------------------------------------------------------
// lexer_save / lexer_restore — snapshot the lexer's full state so callers
// (chiefly `while`/`for` body re-evaluation, plus `_llp_str_call`) can rewind
// to a point — even across a `gc_compact` that moves the source payload.
//
// State saved (matches what `lexer_next` reads/writes):
//   LEX_PTR / LEX_END / LEX_TOKEN_START / LEX_TOKEN_END (4 words, stored as
//     OFFSETS from the source payload base — survive payload relocation),
//   LEX_TOKEN_KIND, LEX_INDENT_TARGET, LEX_INDENT_CURRENT, indent_depth (4
//     bytes), indent_stack (16 bytes), LEX_SRC_HANDLE (2 bytes — popped
//     first on restore so we know which payload base to add the offsets to).
// Total: 30 bytes.
//
// Saved onto FS as a contiguous block. For nested `while` loops, FS just
// stacks the snapshots.
//
// Both routines are leaf helpers (no V4' wrapper) so the FS pushes survive
// across the call boundary into caller's frame.
// -----------------------------------------------------------------------------
lexer_save:
    // Push 16-byte indent_stack first (sits at the bottom of the snapshot).
    ldx #15
_lsv_stack_loop:
    lda indent_stack,x
    jsr fs_push_byte_call
    dex
    bpl _lsv_stack_loop

    // Push the four single-byte fields.
    lda indent_depth
    jsr fs_push_byte_call
    lda LEX_INDENT_CURRENT
    jsr fs_push_byte_call
    lda LEX_INDENT_TARGET
    jsr fs_push_byte_call
    lda LEX_TOKEN_KIND
    jsr fs_push_byte_call

    // Convert the four pointer fields to offsets, push them, restore the
    // ZP cells so the active lexer continues working with absolute pointers.
    jsr _lex_load_base
    jsr _lex_to_offsets

    lda LEX_TOKEN_END+1
    jsr fs_push_byte_call
    lda LEX_TOKEN_END
    jsr fs_push_byte_call
    lda LEX_TOKEN_START+1
    jsr fs_push_byte_call
    lda LEX_TOKEN_START
    jsr fs_push_byte_call
    lda LEX_END+1
    jsr fs_push_byte_call
    lda LEX_END
    jsr fs_push_byte_call
    lda LEX_PTR+1
    jsr fs_push_byte_call
    lda LEX_PTR
    jsr fs_push_byte_call

    jsr _lex_from_offsets

    // Push LEX_SRC_HANDLE last → top of snapshot, popped first on restore.
    lda LEX_SRC_HANDLE+1
    jsr fs_push_byte_call
    lda LEX_SRC_HANDLE
    jsr fs_push_byte_call
    rts

lexer_restore:
    // LEX_SRC_HANDLE first — needed as base for offset → absolute conversion.
    jsr fs_pop_byte_call
    sta LEX_SRC_HANDLE
    jsr fs_pop_byte_call
    sta LEX_SRC_HANDLE+1

    // Pop the four pointer offsets directly into the LEX_* cells. The cells
    // hold offsets at this point; we'll rebase below.
    jsr fs_pop_byte_call
    sta LEX_PTR
    jsr fs_pop_byte_call
    sta LEX_PTR+1
    jsr fs_pop_byte_call
    sta LEX_END
    jsr fs_pop_byte_call
    sta LEX_END+1
    jsr fs_pop_byte_call
    sta LEX_TOKEN_START
    jsr fs_pop_byte_call
    sta LEX_TOKEN_START+1
    jsr fs_pop_byte_call
    sta LEX_TOKEN_END
    jsr fs_pop_byte_call
    sta LEX_TOKEN_END+1

    // Rebase: add the (possibly post-compact) payload base to each offset.
    jsr _lex_load_base
    jsr _lex_from_offsets

    // Pop the four byte fields.
    jsr fs_pop_byte_call
    sta LEX_TOKEN_KIND
    jsr fs_pop_byte_call
    sta LEX_INDENT_TARGET
    jsr fs_pop_byte_call
    sta LEX_INDENT_CURRENT
    jsr fs_pop_byte_call
    sta indent_depth

    // Pop the 16-byte indent_stack.
    ldx #0
_lrs_stack_loop:
    jsr fs_pop_byte_call
    sta indent_stack,x
    inx
    cpx #16
    bne _lrs_stack_loop
    rts

// lexer_drop — discard a saved state (advance FSP by 30 bytes). Used by
// `while` when the loop exits without running another iteration.
lexer_drop:
    clc
    lda FSP
    adc #30
    sta FSP
    bcc !+
    inc FSP+1
!:
    rts

// -----------------------------------------------------------------------------
// _lex_set_indent_target — translate a column count (B1) into a target depth.
// Walks the indent stack: while stack[depth] > col, depth-- (DEDENT will be
// emitted on next lexer_next call). If the resulting top is < col, push col
// (an INDENT will be emitted). Stores final depth → LEX_INDENT_TARGET.
//
// On indent overflow (pushing past INDENT_STACK_MAX), panics with ERR_LEX.
// On inconsistent indent (col falls between two stack entries — i.e., we
// dedent past stack[depth] but it's not equal), we currently just continue;
// Stage 8 may want to panic instead.
// -----------------------------------------------------------------------------
.const INDENT_STACK_MAX = 16

_lex_set_indent_target:
    // Pop levels whose column > B1.
!walk_down:
    ldx indent_depth
    lda indent_stack,x
    cmp B1
    bcc !done_walk+          // stack[depth] < col — stop
    beq !done_walk+          // stack[depth] == col — exact match, stop
    dec indent_depth
    jmp !walk_down-
!done_walk:
    ldx indent_depth
    lda indent_stack,x
    cmp B1
    beq !no_push+            // exact match — no INDENT needed
    // col > stack[depth]: push a new level.
    inc indent_depth
    lda indent_depth
    cmp #INDENT_STACK_MAX
    bcs _li_overflow
    ldx indent_depth
    lda B1
    sta indent_stack,x
!no_push:
    lda indent_depth
    sta LEX_INDENT_TARGET
    rts
_li_overflow:
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler

// -----------------------------------------------------------------------------
// Keyword bucket pointer table — index by (length - 1).
// Bucket 0 (length 1) and bucket 6 (length 7) have no keywords; their
// "buckets" are just sentinels.
// -----------------------------------------------------------------------------
kw_bucket_lo:
    .byte <kw_bucket_1, <kw_bucket_2, <kw_bucket_3, <kw_bucket_4
    .byte <kw_bucket_5, <kw_bucket_6, <kw_bucket_7, <kw_bucket_8
kw_bucket_hi:
    .byte >kw_bucket_1, >kw_bucket_2, >kw_bucket_3, >kw_bucket_4
    .byte >kw_bucket_5, >kw_bucket_6, >kw_bucket_7, >kw_bucket_8

// Per-length keyword tables. Each record = `length × char_byte` then
// `kind_byte`. Sentinel = $00 byte (a `length`-byte keyword can't start
// with NUL since identifiers begin with letter/underscore).
//
// Length implicit per bucket — caller already knows it from the bucket
// index, no need to store it again.

// Keyword bytes are written as raw ASCII hex because Kick Assembler's char
// literals run through its current encoding (screen codes by default), and
// none of the available encodings match ASCII for the lowercase range. The
// inline ASCII spelling appears in the trailing comment for readability.
kw_bucket_1:
    .byte 0                          // no 1-char keywords

kw_bucket_2:
    .byte $69,$66, TK_IF             // "if"
    .byte $6F,$72, TK_OR             // "or"
    .byte $69,$73, TK_IS             // "is"
    .byte $69,$6E, TK_IN             // "in"
    .byte 0

kw_bucket_3:
    .byte $61,$6E,$64, TK_AND        // "and"
    .byte $6E,$6F,$74, TK_NOT        // "not"
    .byte $66,$6F,$72, TK_FOR        // "for"
    .byte $64,$65,$6C, TK_DEL        // "del"
    .byte $74,$72,$79, TK_TRY        // "try"
    .byte $63,$6C,$73, TK_CLS        // "cls"
    .byte 0

kw_bucket_4:
    .byte $65,$6C,$69,$66, TK_ELIF      // "elif"
    .byte $65,$6C,$73,$65, TK_ELSE      // "else"
    .byte $70,$61,$73,$73, TK_PASS      // "pass"
    .byte $54,$72,$75,$65, TK_TRUE      // "True"
    .byte $4E,$6F,$6E,$65, TK_NONE_KW   // "None"
    .byte 0

kw_bucket_5:
    .byte $46,$61,$6C,$73,$65, TK_FALSE  // "False"
    .byte $77,$68,$69,$6C,$65, TK_WHILE  // "while"
    .byte $62,$72,$65,$61,$6B, TK_BREAK  // "break"
    .byte $72,$61,$69,$73,$65, TK_RAISE  // "raise"
    .byte $70,$72,$69,$6E,$74, TK_PRINT  // "print"
    .byte 0

kw_bucket_6:
    .byte $72,$65,$74,$75,$72,$6E, TK_RETURN  // "return"
    .byte $65,$78,$63,$65,$70,$74, TK_EXCEPT  // "except"
    .byte 0

kw_bucket_7:
    .byte $66,$69,$6E,$61,$6C,$6C,$79, TK_FINALLY  // "finally"
    .byte 0

kw_bucket_8:
    .byte $63,$6F,$6E,$74,$69,$6E,$75,$65, TK_CONTINUE  // "continue"
    .byte 0

// -----------------------------------------------------------------------------
// Indent stack — column count at each indent level. indent_stack[0] is
// always 0 (top-level). Pushed/popped by _lex_set_indent_target. Capped at
// INDENT_STACK_MAX levels (16) — overflow is an ERR_LEX panic.
//
// indent_depth points to the topmost valid entry: indent_depth==0 means
// "only stack[0] is live" (top level).
// -----------------------------------------------------------------------------
indent_stack:
    .fill INDENT_STACK_MAX, 0
indent_depth:
    .byte 0
