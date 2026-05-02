// -----------------------------------------------------------------------------
// repl.asm — interactive top-level loop with line editing and history.
//
// Layout:
//   repl_main       — one-time init: persistent root scope + error-recovery
//                     snapshot, then drop into repl_loop. Never returns.
//   repl_loop       — print prompt, capture anchor row, jsr _rpl_read_line,
//                     emit newline, dispatch the line through parser_exec.
//                     Forever.
//   _rpl_read_line  — read one editable line into repl_line_buf. Movable
//                     cursor (LEFT/RIGHT/HOME/SHIFT-HOME), insert/delete,
//                     UP/DOWN history. Returns when RETURN is pressed with
//                     SCREEN_COL parked at end-of-line so the caller's $0D
//                     advances correctly.
//   _rpl_redraw     — repaint the line on its anchor row + place the screen
//                     cursor at (anchor_row, 1 + pos). Single-row only —
//                     REPL_LINE_CAP is sized so the prompt + line + cursor
//                     fit on one 40-col row, no wrap math required.
//   _rpl_hist_save  — push current line onto the history ring. Empty lines
//                     are skipped; full ring rotates oldest out.
//   _rpl_hist_load  — copy history slot[head - (view-1)] back into the
//                     buffer. pos lands at end-of-line (= len), as in any
//                     conventional shell history recall.
//
// Editing keys (PETSCII):
//     $1D right  $9D left  $13 home  $93 shift-home (= end)
//     $14 del    $94 ins
//     $11 down   $91 up   (history)
//     $0D return
// Lowercase ASCII letters are folded before being stored, so a typed-uppercase
// PRINT matches the lexer's lowercase-only keyword table; the screen still
// echoes the original PETSCII so glyphs render naturally in the unshifted
// charset.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

.const REPL_LINE_CAP = 38           // prompt(1) + line(38) + cursor(1) = 40 cols
.const REPL_HIST_SLOTS = 4
.const REPL_HIST_SLOT_SZ = 1 + REPL_LINE_CAP   // 1 length byte + chars

// --- static state -----------------------------------------------------------
// repl_line_buf and repl_hist_slots live in the unused datasette buffer
// region ($033C-$03FD). Saves 194 bytes from the code segment. We don't
// drive tape, so this RAM is otherwise idle. Reads are always preceded by
// a write (line buf) or gated by repl_hist_count (slots), so no init needed.
.label repl_hist_slots = $033C       // 156 bytes — ends at $03D7
.label repl_line_buf   = $03D8       // 38 bytes  — ends at $03FD

repl_line_len:    .byte 0
repl_line_pos:    .byte 0           // cursor index within line, 0..len
repl_line_anchor_row: .byte 0       // screen row the prompt lives on

// History ring. `head` is the index of the newest stored entry; `count`
// caps at REPL_HIST_SLOTS. `view` walks the recall depth: 0 = the current
// (in-progress) line, 1..count = history depths back from newest.
repl_hist_count:  .byte 0
repl_hist_head:   .byte 0
repl_hist_view:   .byte 0

// Recovery snapshot — captured ONCE at repl_main entry, after the root scope
// is allocated and rs_push'd. error_handler restores from these to undo any
// stack growth a panicking parser_exec did, then jumps back to repl_loop.
// The scope handle stays rooted because RSP recovers to just-past-scope.
repl_rec_s:       .byte 0
repl_rec_rsp:     .word 0
repl_rec_fsp:     .word 0
repl_rec_fp:      .word 0


// -----------------------------------------------------------------------------
// repl_main — boot entry. Allocates the persistent root scope, snapshots
// stack pointers for error recovery, then falls through to repl_loop.
// Never returns under normal operation.
// -----------------------------------------------------------------------------
repl_main:
    jsr dict_alloc                   // RV = empty dict handle

    lda RV
    sta GLOBAL_SCOPE
    sta ROOT_SCOPE
    sta W0
    lda RV+1
    sta GLOBAL_SCOPE+1
    sta ROOT_SCOPE+1
    sta W0+1
    rs_push(W0)                      // permanent root — never popped

    lda #0
    sta METHOD_RECEIVER
    sta METHOD_RECEIVER+1

    tsx
    stx repl_rec_s
    lda RSP
    sta repl_rec_rsp
    lda RSP+1
    sta repl_rec_rsp+1
    lda FSP
    sta repl_rec_fsp
    lda FSP+1
    sta repl_rec_fsp+1
    lda FP
    sta repl_rec_fp
    lda FP+1
    sta repl_rec_fp+1

    // fall through

// -----------------------------------------------------------------------------
// repl_loop — print prompt, read line, dispatch, repeat.
// -----------------------------------------------------------------------------
repl_loop:
    // Prompt: '>' at column 0 of whichever row we're on. A single-char
    // prompt on a 40-col row never wraps, so SCREEN_COL = 1 after this and
    // SCREEN_ROW is the row we'll use as the line's edit anchor.
    lda #$3E                         // '>'
    jsr screen_put_char

    lda SCREEN_ROW
    sta repl_line_anchor_row

    jsr _rpl_read_line               // returns with SCREEN_COL = 1 + len

    // Newline so the dispatched line's output starts on a fresh row.
    lda #$0D
    jsr screen_put_char

    // Empty submission → just reprompt.
    lda repl_line_len
    beq repl_loop

    // Save before dispatching so a panicking parser_exec doesn't lose the
    // line from history (error_handler recovery path lands us back here).
    jsr _rpl_hist_save

    // Allocate TYPE_STR of repl_line_len bytes; copy the buffer in.
    lda repl_line_len
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr str_alloc                    // RV = new TYPE_STR handle

    jsr deref_RV_to_W2               // W2 = payload base
    ldy #0
_rpl_copy:
    cpy repl_line_len
    bcs _rpl_copy_done
    lda repl_line_buf,y
    sta (W2),y
    iny
    jmp _rpl_copy
_rpl_copy_done:

    lda RV
    sta W0
    lda RV+1
    sta W0+1
    rs_push(W0)

    jsr parser_exec                  // consumes source on return; RV = result

    // Bind `_` in ROOT_SCOPE to the last expression result. The scope-walk
    // type check in scope_get keeps this from poisoning parent-link lookups.
    rs_push_const(STR_UNDERSCORE)
    jsr rs_push_rv
    jsr scope_set

    jmp repl_loop


// -----------------------------------------------------------------------------
// _rpl_read_line — read one editable line from the keyboard.
//
//   in:  repl_line_anchor_row holds the row the prompt was printed on.
//        Screen cursor is at (anchor_row, 1) — i.e. just past the prompt.
//   out: repl_line_buf / _len populated with the user-submitted line.
//        repl_line_pos is unspecified (might be mid-line if the user moved
//        the cursor before pressing RETURN). SCREEN_COL = 1 + repl_line_len
//        so the caller's `$0D` puts the newline past everything typed.
//
// Side effects: writes to repl_hist_view (resets to 0 at entry, walked by
// UP/DOWN). Calls into screen / kbd routines. No allocation.
// -----------------------------------------------------------------------------
_rpl_read_line:
    lda #0
    sta repl_line_len
    sta repl_line_pos
    sta repl_hist_view               // each new line resets history walk

_rrl_key_loop:
    jsr screen_show_cursor
    jsr kbd_getchar                  // A = PETSCII byte (blocking)
    pha
    jsr screen_hide_cursor
    pla

    cmp #$0D                         // RETURN
    bne !nfin+
    jmp _rrl_finish
!nfin:
    cmp #$1D                         // CRSR RIGHT
    bne !nrr+
    jmp _rrl_right
!nrr:
    cmp #$9D                         // SHIFT-CRSR-RIGHT = LEFT
    bne !nlr+
    jmp _rrl_left
!nlr:
    cmp #$13                         // HOME
    bne !nh+
    jmp _rrl_home
!nh:
    cmp #$93                         // SHIFT-HOME → end-of-line
    bne !ne+
    jmp _rrl_end
!ne:
    cmp #$11                         // CRSR DOWN
    bne !ndn+
    jmp _rrl_hist_down
!ndn:
    cmp #$91                         // SHIFT-CRSR-DOWN = UP
    bne !nup+
    jmp _rrl_hist_up
!nup:
    cmp #$14                         // INST/DEL → backspace-style delete
    bne !nbs+
    jmp _rrl_delete
!nbs:
    cmp #$94                         // SHIFT-INST → insert blank
    bne !nin+
    jmp _rrl_insert_blank
!nin:

    // Normalize shift-space ($A0) to plain space.
    cmp #$A0
    bne _rrl_not_shift_space
    lda #$20
_rrl_not_shift_space:

    // Filter to printable ASCII range.
    cmp #$20
    bcc _rrl_key_loop
    cmp #$7F
    bcs _rrl_key_loop

    // Buffer-full guard.
    ldy repl_line_len
    cpy #REPL_LINE_CAP
    bcs _rrl_key_loop

    // Lowercase fold for ASCII A-Z so typed `PRINT` matches the lexer's
    // lowercase keyword table.
    cmp #$41
    bcc _rrl_insert_char
    cmp #$5B
    bcs _rrl_insert_char
    clc
    adc #$20

_rrl_insert_char:
    // Insert (A) at repl_line_pos, shifting buf[pos..len-1] right by one.
    pha
    ldx repl_line_pos
    cpx repl_line_len
    beq _rrl_insert_at_end           // pos == len → just append

    ldy repl_line_len
    dey                              // y = len - 1 (last existing char)
_rrl_shift_right:
    lda repl_line_buf,y
    sta repl_line_buf+1,y
    cpy repl_line_pos
    beq _rrl_insert_at_end           // shifted everything from pos onward
    dey
    jmp _rrl_shift_right
_rrl_insert_at_end:
    pla
    ldx repl_line_pos
    sta repl_line_buf,x
    inc repl_line_len
    inc repl_line_pos
    jsr _rpl_redraw
    jmp _rrl_key_loop

// --- navigation -------------------------------------------------------------
// Many of the handlers below want to bail back to _rrl_key_loop on a no-op
// (cursor at edge, buffer empty/full). The dispatcher at the top is now
// > 128 bytes away, so a direct `beq _rrl_key_loop` doesn't fit a branch
// — they go through this trampoline instead.
_rrl_back_to_top:
    jmp _rrl_key_loop

_rrl_left:
    lda repl_line_pos
    beq _rrl_back_to_top
    dec repl_line_pos
    dec SCREEN_COL
    jmp _rrl_key_loop

_rrl_right:
    lda repl_line_pos
    cmp repl_line_len
    bcs _rrl_back_to_top             // pos already at end
    inc repl_line_pos
    inc SCREEN_COL
    jmp _rrl_key_loop

_rrl_home:
    lda #0
    sta repl_line_pos
    lda #1                           // just past the '>' prompt
    sta SCREEN_COL
    jmp _rrl_key_loop

_rrl_end:
    lda repl_line_len
    sta repl_line_pos
    clc
    adc #1
    sta SCREEN_COL
    jmp _rrl_key_loop

// --- delete / insert-blank --------------------------------------------------
_rrl_delete:
    // Backspace: delete char left of cursor; shift tail left by one.
    lda repl_line_pos
    beq _rrl_back_to_top
    dec repl_line_pos
    ldx repl_line_pos
_rrl_del_loop:
    cpx repl_line_len
    bcs _rrl_del_done
    lda repl_line_buf+1,x
    sta repl_line_buf,x
    inx
    jmp _rrl_del_loop
_rrl_del_done:
    dec repl_line_len
    jsr _rpl_redraw
    jmp _rrl_key_loop

_rrl_insert_blank:
    // SHIFT-INST: insert a space at cursor; shift tail right; pos stays put
    // (matches C64 BASIC INST behavior — opens up a hole at the cursor).
    ldy repl_line_len
    cpy #REPL_LINE_CAP
    bcs _rrl_back_to_top             // full → drop

    ldx repl_line_pos
    cpx repl_line_len
    beq _rrl_blank_at_end

    ldy repl_line_len
    dey
_rrl_blank_shift:
    lda repl_line_buf,y
    sta repl_line_buf+1,y
    cpy repl_line_pos
    beq _rrl_blank_at_end
    dey
    jmp _rrl_blank_shift
_rrl_blank_at_end:
    ldx repl_line_pos
    lda #$20
    sta repl_line_buf,x
    inc repl_line_len
    jsr _rpl_redraw
    jmp _rrl_key_loop

// --- history walk -----------------------------------------------------------
// Second trampoline — the first one near `_rrl_left` is now also too far for
// branches in this section.
_rrl_back_to_top2:
    jmp _rrl_key_loop

_rrl_hist_up:
    lda repl_hist_view
    cmp repl_hist_count
    bcs _rrl_back_to_top2            // already at the oldest entry
    inc repl_hist_view
    jsr _rpl_hist_load
    jsr _rpl_redraw
    jmp _rrl_key_loop

_rrl_hist_down:
    lda repl_hist_view
    beq _rrl_back_to_top2            // at the in-progress slot
    dec repl_hist_view
    bne _rrl_hist_down_load
    // view dropped to 0 → empty the line.
    lda #0
    sta repl_line_len
    sta repl_line_pos
    jsr _rpl_redraw
    jmp _rrl_key_loop
_rrl_hist_down_load:
    jsr _rpl_hist_load
    jsr _rpl_redraw
    jmp _rrl_key_loop

// --- finish -----------------------------------------------------------------
_rrl_finish:
    // Park the screen cursor at end-of-line so the caller's $0D advances
    // past everything typed (not from wherever the user left the cursor).
    lda repl_line_len
    clc
    adc #1
    sta SCREEN_COL
    rts


// -----------------------------------------------------------------------------
// _rpl_redraw — repaint repl_line_buf on its anchor row + position the screen
// cursor at (anchor_row, 1 + pos). After painting `len` chars we blank every
// cell from column `1 + len` through the right edge of the row. That clears
// stale glyphs left behind when the new line is shorter than the previous one
// (a backspace, or a history recall onto a now-shorter buffer).
//
// Direct screen-RAM writes — REPL_LINE_CAP is single-row, so no scroll/wrap.
//   clobbers: A, X, Y, W2.
// -----------------------------------------------------------------------------
_rpl_redraw:
    lda repl_line_anchor_row
    sta SCREEN_ROW
    jsr scr_row_offset_to_w2         // W2 = SCREEN_BASE + anchor_row*40

    ldx #0
_rrd_loop:
    cpx repl_line_len
    bcs _rrd_pad
    lda repl_line_buf,x
    jsr petscii_to_screen_code       // X preserved, Y clobbered
    pha
    txa
    tay
    iny                              // y = x + 1 (skip prompt cell)
    pla
    sta (W2),y
    inx
    jmp _rrd_loop
_rrd_pad:
    // Erase every cell from col `1 + len` through col SCREEN_COLS - 1 so a
    // shrinking line doesn't leave the previous line's tail visible. SCREEN_COLS
    // is 40, the row's full width.
    txa                              // x = len
    tay
    iny                              // y = 1 + len, the first cell to clear
    lda #$20                         // screen-code space
_rrd_pad_loop:
    cpy #SCREEN_COLS
    bcs _rrd_pad_done
    sta (W2),y
    iny
    bne _rrd_pad_loop                // y < 40, never wraps to 0
_rrd_pad_done:

    lda repl_line_pos
    clc
    adc #1
    sta SCREEN_COL
    rts


// -----------------------------------------------------------------------------
// _rpl_hist_save — push current line onto the history ring.
//
// Empty lines are skipped (BASIC-style: pressing RETURN on an empty line
// shouldn't pollute history). Otherwise: head = (head+1) mod SLOTS; count
// saturates at SLOTS; slot[head] = (len byte, content).
//   clobbers: A, X, Y, W2.
// -----------------------------------------------------------------------------
_rpl_hist_save:
    lda repl_line_len
    bne !+
    rts                              // empty → no-op
!:
    // head = (head + 1) mod SLOTS.
    lda repl_hist_head
    clc
    adc #1
    cmp #REPL_HIST_SLOTS
    bcc !+
    lda #0
!:
    sta repl_hist_head

    // count = min(count + 1, SLOTS).
    lda repl_hist_count
    cmp #REPL_HIST_SLOTS
    bcs _rhs_count_done
    clc
    adc #1
    sta repl_hist_count
_rhs_count_done:

    jsr _rpl_hist_addr               // W2 = &slot[head]

    // slot[0] = len; slot[1..len] = buffer.
    lda repl_line_len
    ldy #0
    sta (W2),y
    jsr inc_w2_w
    ldy #0
_rhs_copy:
    cpy repl_line_len
    bcs _rhs_copy_done
    lda repl_line_buf,y
    sta (W2),y
    iny
    jmp _rhs_copy
_rhs_copy_done:
    rts


// -----------------------------------------------------------------------------
// _rpl_hist_load — copy history slot at depth `view` into repl_line_buf.
// view 1 = newest (slot[head]); view 2 = one older; up to view = count.
// Caller guarantees 1 <= view <= count (UP/DOWN handlers gate this).
//
// pos lands at len so the cursor sits at end-of-recalled-line, the conventional
// shell-history behavior.
//   clobbers: A, X, Y, W2.
// -----------------------------------------------------------------------------
_rpl_hist_load:
    // idx = (head - (view - 1) + SLOTS) mod SLOTS.
    lda repl_hist_view
    sec
    sbc #1
    sta B0                           // B0 = view - 1 (steps back from head)
    lda repl_hist_head
    sec
    sbc B0
    bpl _rhl_have_idx
    clc
    adc #REPL_HIST_SLOTS
_rhl_have_idx:
    sta B0                           // B0 = slot index

    jsr _rpl_hist_addr_b0            // W2 = &slot[B0]

    // Read len, then payload.
    ldy #0
    lda (W2),y
    sta repl_line_len
    sta repl_line_pos                // cursor lands at end-of-line
    jsr inc_w2_w
    ldy #0
_rhl_copy:
    cpy repl_line_len
    bcs _rhl_copy_done
    lda (W2),y
    sta repl_line_buf,y
    iny
    jmp _rhl_copy
_rhl_copy_done:
    rts


// -----------------------------------------------------------------------------
// _rpl_hist_addr      — W2 = &repl_hist_slots[repl_hist_head].
// _rpl_hist_addr_b0   — W2 = &repl_hist_slots[B0].
// SLOT_SZ is 39 so we just add the constant `head` times — at most 3 adds.
// Cheaper than a multiply for a 4-slot ring.
//   clobbers: A, X. W2 written.
// -----------------------------------------------------------------------------
_rpl_hist_addr:
    ldx repl_hist_head
    jmp _rha_compute
_rpl_hist_addr_b0:
    ldx B0
_rha_compute:
    lda #<repl_hist_slots
    sta W2
    lda #>repl_hist_slots
    sta W2+1
    cpx #0
    beq _rha_done
_rha_loop:
    clc
    lda W2
    adc #REPL_HIST_SLOT_SZ
    sta W2
    bcc !+
    inc W2+1
!:
    dex
    bne _rha_loop
_rha_done:
    rts
