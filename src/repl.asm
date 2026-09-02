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

.const REPL_LINE_CAP = 64           // longer than the row: the editor
                                    // horizontally scrolls (repl_view_shift)
.const REPL_HIST_SLOTS = 2
.const REPL_HIST_SLOT_SZ = 1 + REPL_LINE_CAP   // 1 length byte + chars

// --- static state -----------------------------------------------------------
// repl_line_buf and repl_hist_slots live in the unused datasette buffer
// region ($033C-$03FD, 194 bytes). We don't drive tape, so this RAM is
// otherwise idle. Reads are always preceded by a write (line buf) or gated
// by repl_hist_count (slots), so no init needed.
// Layout: line 64 ($033C-$037B) + 2 history slots x 65 ($037C-$03FD).
.label repl_line_buf   = $033C       // 64 bytes  — ends at $037B
.label repl_hist_slots = $033C + REPL_LINE_CAP // 130 bytes — ends at $03FD

repl_line_len:    .byte 0
repl_line_pos:    .byte 0           // cursor index within line, 0..len
repl_view_shift:  .byte 0           // leftmost visible buffer index (h-scroll)
repl_base_col:    .byte 0           // screen column where editable text starts
                                    //  (past the prompt); captured at entry
repl_prompt_last: .byte 0           // screencode shown at base_col-1 when NOT
                                    //  scrolled (the prompt's last cell)
repl_scroll_tmp:  .byte 0           // h-scroll math scratch
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
    sta CURRENT_SCOPE
    sta ROOT_SCOPE
    sta W0
    lda RV+1
    sta CURRENT_SCOPE+1
    sta ROOT_SCOPE+1
    sta W0+1
    rs_push(W0)                      // permanent root — never popped

    lda #0
    sta METHOD_RECEIVER
    sta METHOD_RECEIVER+1
    sta PAUSE_BLOCKED                // ensure NMI banner enabled at boot
    sta NMI_PAUSED                   // 0 = no banner showing

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

    jsr rs_push_rv                   // source string (= old RV) for parser_exec

    jsr parser_exec                  // consumes source on return; RV = result

    // After parser_exec: if RV != NONE, both auto-print the value (Python-REPL
    // style; assignments and statements return NONE and stay quiet) and bind
    // `_` to it in ROOT_SCOPE. The same None check gates both so we don't
    // poison `_` (scope_get can't distinguish NONE from missing) and don't
    // spam the screen with phantom "None" lines after every statement.
    //
    // RS layout: push RV THREE times — once for print_value (consumed last),
    // once for the "_" name slot and once for the scope_set value (consumed
    // together first). scope_set leaves the bottom RV intact for print_value.
    jsr repl_bind_print

    jmp repl_loop


// -----------------------------------------------------------------------------
// repl_bind_print — REPL result semantics for the value in RV: if it isn't
// NONE, bind it to `_` in the current scope and auto-print it. Shared by the
// kernel REPL loop and builtin_exec (EXEC gives user shells the same
// semantics). Caller context: callable from both V4' frames and the REPL's
// flat loop — only V4' sub-calls inside.
//   in:  RV = statement/turn result.   clobbers: A,X,Y, W's via sub-calls.
// -----------------------------------------------------------------------------
repl_bind_print:
    lda RV
    cmp #<NONE
    bne !bind+
    lda RV+1
    cmp #>NONE
    beq _rbp_skip
!bind:
    jsr rs_push_rv                   // bottom: RV for print_value
    rs_push_const(STR_UNDERSCORE)
    jsr rs_push_rv
    jsr scope_set                    // pops UNDERSCORE+RV; bottom RV stays
    jsr print_value                  // pops the bottom RV, prints it
    lda #$0D
    jsr screen_put_char
_rbp_skip:
    rts

// -----------------------------------------------------------------------------
// repl_try_shell — panic-recovery hook: if the global SHELL exists, restart
// it by executing the constant source "SHELL()". Guarded by
// repl_shell_retry: set before the attempt, cleared by kbd_getchar once the
// shell reaches an interactive wait — a shell that panics BEFORE reading a
// key is broken, and a second panic falls through to the kernel REPL
// instead of looping.
//   Called from error_handler with freshly reset stacks; returns to caller
//   (which falls into repl_loop) when there is no shell / the guard trips /
//   the shell RETURNs deliberately.
// -----------------------------------------------------------------------------
repl_try_shell:
    lda repl_shell_retry
    bne _rts_give_up                 // previous restart never got to a key
    // SHELL bound in ROOT_SCOPE?
    lda ROOT_SCOPE
    sta W0
    lda ROOT_SCOPE+1
    sta W0+1
    rs_push(W0)
    rs_push_const(STR_SHELL_NAME)
    jsr dict_get                     // RV = value or NONE
    lda RV
    cmp #<NONE
    bne !have+
    lda RV+1
    cmp #>NONE
    beq _rts_no_shell
!have:
    lda #1
    sta repl_shell_retry
    rs_push_const(STR_SHELL_CALL)
    jsr parser_exec                  // runs "SHELL()"; returns if it RETURNs
_rts_no_shell:
_rts_give_up:
    lda #0
    sta repl_shell_retry
    rts

repl_shell_retry: .byte 0

// "SHELL" (the global name) and "SHELL()" (the restart source).
STR_SHELL_NAME:
    .word STR_SHELL_NAME_OBJ
    .word 7
    .word 0
    .byte TYPE_STR
    .byte 0
STR_SHELL_NAME_OBJ:
    .word 5
    .text "SHELL"

STR_SHELL_CALL:
    .word STR_SHELL_CALL_OBJ
    .word 9
    .word 0
    .byte TYPE_STR
    .byte 0
STR_SHELL_CALL_OBJ:
    .word 7
    .text "SHELL()"

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
    // Text starts at the current cursor column (caller printed the prompt);
    // capture it and the char sitting just left of it (restored as the
    // non-scrolled indicator cell). Generalizes the old hardcoded 1-col '>'
    // prompt so INPUT can pass an arbitrary prompt string.
    lda SCREEN_COL
    sta repl_base_col
    beq _rrl_no_prompt
    lda repl_line_anchor_row
    sta SCREEN_ROW
    jsr scr_row_offset_to_w2
    ldy repl_base_col
    dey
    lda (W2),y
    sta repl_prompt_last
_rrl_no_prompt:
    lda #0
    sta repl_line_len
    sta repl_line_pos
    sta repl_view_shift
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
    jsr _rpl_redraw                  // handles h-scroll + cursor
    jmp _rrl_key_loop

_rrl_right:
    lda repl_line_pos
    cmp repl_line_len
    bcs _rrl_back_to_top             // pos already at end
    inc repl_line_pos
    jsr _rpl_redraw
    jmp _rrl_key_loop

_rrl_home:
    lda #0
    sta repl_line_pos
    jsr _rpl_redraw
    jmp _rrl_key_loop

_rrl_end:
    lda repl_line_len
    sta repl_line_pos
    jsr _rpl_redraw                  // handles h-scroll + cursor
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
    // Park the screen cursor at end-of-line (clamped to the target width —
    // the caller's $0D newline doesn't care, but the cell must be inside
    // the window).
    lda repl_line_len
    sec
    sbc repl_view_shift
    clc
    adc repl_base_col
    cmp wm_w
    bcc !+
    lda wm_w
    sec
    sbc #1
!:
    sta SCREEN_COL
    rts


// -----------------------------------------------------------------------------
// _rpl_redraw — repaint repl_line_buf on its anchor row + position the screen
// cursor at (anchor_row, 1 + pos). After painting `len` chars we blank every
// cell from column `1 + len` through the right edge of the row. That clears
// stale glyphs left behind when the new line is shorter than the previous one
// (a backspace, or a history recall onto a now-shorter buffer).
//
// Cells are written through _scr_write_cell so the WM write-through mirrors
// them to the screen, and every column bound comes from the current target's
// width (wm_w = 40 at boot → byte-identical to the old fullscreen behavior).
// In a window narrower than the line, the tail beyond the last visible
// column is simply not shown (the line buffer still holds it) — the REPL
// has no horizontal scroll. Known limitation; use a wide window for the
// REPL.
//   clobbers: A, X, Y, W2 (+ WM row ptrs).
// -----------------------------------------------------------------------------
_rpl_redraw:
    lda repl_line_anchor_row
    sta SCREEN_ROW
    jsr scr_row_offset_to_w2         // W2 = target row base (+ WM ptrs)

    // Horizontal scroll: keep the cursor inside the text columns
    // [base_col .. wm_w). textwidth = wm_w - base_col.
    lda repl_view_shift
    cmp repl_line_pos
    bcc !+
    beq !+
    lda repl_line_pos                // shift > pos → shift = pos
    sta repl_view_shift
!:
    lda wm_w
    sec
    sbc repl_base_col
    sta repl_scroll_tmp              // textwidth
    lda repl_line_pos
    sec
    sbc repl_view_shift              // A = cursor's visible offset
    cmp repl_scroll_tmp
    bcc !+                           // offset < textwidth → visible
    // offset >= textwidth → shift = pos - textwidth + 1
    lda repl_line_pos
    sec
    sbc repl_scroll_tmp
    clc
    adc #1
    sta repl_view_shift
!:

    // Indicator cell at base_col-1: the prompt's last char normally, '<'
    // when text is scrolled off to the left. Skipped when base_col == 0.
    lda repl_base_col
    beq _rrd_after_ind
    tay
    dey                              // y = base_col - 1
    lda repl_view_shift
    beq _rrd_ind_prompt
    lda #$3C                         // '<'  ($3C: petscii == screencode)
    jmp _rrd_ind_write
_rrd_ind_prompt:
    lda repl_prompt_last             // restore the prompt's last cell
_rrd_ind_write:
    jsr _scr_write_cell
_rrd_after_ind:

    ldx repl_view_shift
_rrd_loop:
    cpx repl_line_len
    bcs _rrd_pad
    lda repl_line_buf,x
    jsr petscii_to_screen_code       // X preserved, Y clobbered
    pha
    txa
    sec
    sbc repl_view_shift
    clc
    adc repl_base_col                // y = base_col + (x - shift)
    tay
    cpy wm_w
    bcs _rrd_clip                    // ran off the window's right edge
    pla
    jsr _scr_write_cell              // mirrors to screen when owned
    inx
    jmp _rrd_loop
_rrd_clip:
    pla                              // balance the stash; stop painting
_rrd_pad:
    // Erase every cell from the first unpainted column through the target's
    // right edge so a shrinking line doesn't leave a stale tail visible.
    txa                              // x = last painted buffer index
    sec
    sbc repl_view_shift
    clc
    adc repl_base_col                // y = first cell to clear
    tay
    lda #$20                         // screen-code space
_rrd_pad_loop:
    cpy wm_w
    bcs _rrd_pad_done
    jsr _scr_write_cell
    iny
    bne _rrd_pad_loop                // never wraps to 0 (wm_w <= 40)
_rrd_pad_done:

    // Cursor at base_col + (pos - shift); the clamp above guarantees it fits.
    lda repl_line_pos
    sec
    sbc repl_view_shift
    clc
    adc repl_base_col
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
