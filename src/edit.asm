// -----------------------------------------------------------------------------
// edit.asm — full-screen gap-buffer text editor.
//
// One linear byte buffer, EDIT_BUF_SIZE bytes, allocated as a TYPE_STR for
// the editor's lifetime. Logical text is stored as
//     [buf_start .. gap_start)  ++  [gap_end .. buf_end)
// The range [gap_start, gap_end) is "the gap" — slack space. Insert/delete
// at gap_start is O(1). Cursor moves don't shift bytes; they only update
// `pos` (the cursor's physical address). On the next insert/delete, the gap
// is shifted to `pos` first via `edit_gap_move`.
//
// `pos` is always either equal to `gap_start` / `gap_end`, or somewhere in
// `[buf_start, gap_start) ∪ [gap_end, buf_end]` — never inside the gap.
// edit_key_left / edit_key_right (Phase C) skip across the gap when crossing
// the gap boundary.
//
// CRITICAL invariant: no allocation happens inside the editor's main loop.
// kbd_getchar / screen_put_char / wset / etc. don't allocate, so GC cannot
// trigger mid-edit and all pointers stay stable for the entire session.
// (The result-string alloc on Ctrl-X exit happens AFTER the loop terminates.)
//
// Mirrors Admiral's `edit2.dasm16`. Phase A here covers the gap-buffer
// primitives only — render and key dispatch land in later phases.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

.const EDIT_BUF_SIZE = 800

// --- editor state (static) --------------------------------------------------
// All 16-bit pointers are absolute addresses into the buffer's payload.
// Persistent across all editor sub-call invocations within a single edit()
// session; not part of any V4' frame.
edit_buf_start:    .word 0
edit_buf_end:      .word 0
edit_gap_start:    .word 0
edit_gap_end:      .word 0
edit_pos:          .word 0     // cursor's physical address
edit_line:         .word 0     // start of current line (pre-gap reads, post-gap reads)
edit_view_start:   .word 0     // top-left visible char (offset from buf_start)
edit_view_shift:   .byte 0     // horizontal scroll (column 0..SCREEN_COLS-1)
edit_scr_x:        .byte 0     // cursor on-screen column
edit_scr_y:        .byte 0     // cursor on-screen row
edit_dirty:        .byte 0     // bit 0 = current line dirty, bit 1 = full screen dirty
edit_clip_cut:     .byte 0     // 1 if last key was kill-line (for accumulating cuts)


// -----------------------------------------------------------------------------
// edit_init — populate state for a freshly allocated empty buffer.
//   in:  W0 = buffer base address (heap object payload pointer)
//        W2 = buffer size in bytes (typically EDIT_BUF_SIZE)
//   out: gap covers the whole buffer; cursor at start; all flags clear.
//   clobbers: A.
// -----------------------------------------------------------------------------
edit_init:
    lda W0
    sta edit_buf_start
    sta edit_gap_start
    sta edit_line
    sta edit_view_start
    lda W0+1
    sta edit_buf_start+1
    sta edit_gap_start+1
    sta edit_line+1
    sta edit_view_start+1

    clc
    lda W0
    adc W2
    sta edit_buf_end
    sta edit_gap_end
    sta edit_pos
    lda W0+1
    adc W2+1
    sta edit_buf_end+1
    sta edit_gap_end+1
    sta edit_pos+1

    lda #0
    sta edit_view_shift
    sta edit_scr_x
    sta edit_scr_y
    sta edit_dirty
    sta edit_clip_cut
    rts


// -----------------------------------------------------------------------------
// edit_gap_move — shift the gap so that pos is at the gap boundary. Either
// gap_end advances down to pos (gap moves right) or gap_start retreats up to
// pos (gap moves left). After return, pos == gap_end (caller's invariant for
// inserts) and the gap is at the cursor.
//
// Algorithm (6502 port of Admiral's edit__gap_move):
//   while NOT (gap_start == pos OR gap_end == pos):
//     if gap_end < pos:                  // pos is to the right of the gap
//       *gap_start = *gap_end; gap_start++; gap_end++
//     else if gap_start > pos:           // pos is to the left of the gap
//       gap_start--; gap_end--; *gap_end = *gap_start
//
//   clobbers: A, X, Y, W0, W1, W2.
// -----------------------------------------------------------------------------
edit_gap_move:
    // Load gap_start → W0, gap_end → W1, pos → W2 for fast indirect access
    // and compares.
    lda edit_gap_start
    sta W0
    lda edit_gap_start+1
    sta W0+1
    lda edit_gap_end
    sta W1
    lda edit_gap_end+1
    sta W1+1
    lda edit_pos
    sta W2
    lda edit_pos+1
    sta W2+1

_egm_loop:
    // Compare W1 (gap_end) vs W2 (pos). If W1 < W2 → move right.
    lda W1+1
    cmp W2+1
    bcc _egm_right
    bne _egm_check_left
    lda W1
    cmp W2
    bcc _egm_right
_egm_check_left:
    // Compare W0 (gap_start) vs W2 (pos). If W0 > W2 → move left.
    lda W0+1
    cmp W2+1
    bcc _egm_done
    bne _egm_left_yes
    lda W0
    cmp W2
    bcc _egm_done
    beq _egm_done
_egm_left_yes:
    // Move gap left: W0--; W1--; *W1 = *W0.
    lda W0
    bne !+
    dec W0+1
!:
    dec W0
    lda W1
    bne !+
    dec W1+1
!:
    dec W1
    ldy #0
    lda (W0),y
    sta (W1),y
    jmp _egm_loop

_egm_right:
    // *W0 = *W1; W0++; W1++.
    ldy #0
    lda (W1),y
    sta (W0),y
    inc W0
    bne !+
    inc W0+1
!:
    inc W1
    bne !+
    inc W1+1
!:
    jmp _egm_loop

_egm_done:
    // Write W0/W1 back; pos = W1 (= gap_end after move).
    lda W0
    sta edit_gap_start
    lda W0+1
    sta edit_gap_start+1
    lda W1
    sta edit_gap_end
    sta edit_pos
    lda W1+1
    sta edit_gap_end+1
    sta edit_pos+1
    rts


// -----------------------------------------------------------------------------
// edit_insert_char — insert one byte at cursor. Gap shrinks by 1.
//   in:  A = byte to insert
//   out: gap_start advanced by 1; pos = gap_end (still); buffer logical len += 1.
//        If gap is full (gap_start == gap_end), the call is a silent no-op
//        (matches Admiral's "buffer full" semantics).
//   clobbers: A, X, Y, W0, W1, W2.
// -----------------------------------------------------------------------------
edit_insert_char:
    pha                          // save char
    lda edit_gap_start
    cmp edit_gap_end
    bne _eic_have_room
    lda edit_gap_start+1
    cmp edit_gap_end+1
    bne _eic_have_room
    pla                          // discard saved char (buffer full)
    rts
_eic_have_room:
    jsr edit_gap_move

    // *gap_start = saved char; gap_start++.
    lda edit_gap_start
    sta W0
    lda edit_gap_start+1
    sta W0+1
    pla
    sta B0                       // save char (W0 deref might shadow A)
    ldy #0
    lda B0
    sta (W0),y

    // Mark current line dirty; mark whole screen dirty if char was newline.
    lda edit_dirty
    ora #$01
    sta edit_dirty
    lda B0
    cmp #$0D
    bne _eic_inc
    lda edit_dirty
    ora #$02
    sta edit_dirty
_eic_inc:
    inc edit_gap_start
    bne !+
    inc edit_gap_start+1
!:
    rts


// -----------------------------------------------------------------------------
// edit_remove_char — forward delete one byte at cursor (DEL key). Gap grows
// by 1. No-op if cursor is already at end-of-buffer.
//   clobbers: A, X, Y, W0, W1, W2.
// -----------------------------------------------------------------------------
edit_remove_char:
    // No-op if pos == buf_end (nothing to delete to the right).
    lda edit_pos
    cmp edit_buf_end
    bne _erc_proceed
    lda edit_pos+1
    cmp edit_buf_end+1
    beq _erc_done
_erc_proceed:
    jsr edit_gap_move
    // After move, pos == gap_end. Read the byte we're about to swallow into
    // the gap so we can detect newline → full-screen dirty.
    lda edit_gap_end
    sta W0
    lda edit_gap_end+1
    sta W0+1
    ldy #0
    lda (W0),y
    sta B0

    lda edit_dirty
    ora #$01
    sta edit_dirty
    lda B0
    cmp #$0D
    bne _erc_inc
    lda edit_dirty
    ora #$02
    sta edit_dirty
_erc_inc:
    inc edit_gap_end
    bne !+
    inc edit_gap_end+1
!:
    inc edit_pos
    bne !+
    inc edit_pos+1
!:
_erc_done:
    rts


// -----------------------------------------------------------------------------
// edit_bol — find the start of the line containing W0. Walks backward from
// W0 until either buf_start or a newline at W0[-1].
//   in:  W0 = pointer (somewhere in the buffer)
//   out: W0 = pointer to first char of that line (or buf_start if W0 was
//        already on the first line).
//   clobbers: A, X, Y, W2.
//
// Note: gap-aware. If W0 == gap_end, treat it as gap_start for the walk
// (i.e., the byte "before" gap_end is the byte before gap_start).
// -----------------------------------------------------------------------------
edit_bol:
    // If W0 == gap_end, jump to gap_start (cross the gap leftward).
    lda W0
    cmp edit_gap_end
    bne _ebol_walk
    lda W0+1
    cmp edit_gap_end+1
    bne _ebol_walk
    // W0 is at gap_end. If gap_start == buf_start, we're at line 0.
    lda edit_gap_start
    cmp edit_buf_start
    bne _ebol_to_gap_start
    lda edit_gap_start+1
    cmp edit_buf_start+1
    bne _ebol_to_gap_start
    // gap_start == buf_start: copy buf_start into W0 (already at it logically).
    lda edit_buf_start
    sta W0
    lda edit_buf_start+1
    sta W0+1
    rts
_ebol_to_gap_start:
    lda edit_gap_start
    sta W0
    lda edit_gap_start+1
    sta W0+1
_ebol_walk:
    // Gap-transparent: if W0 == gap_end, hop to gap_start. The byte just
    // before gap_start is the logical predecessor of the byte at gap_end;
    // without this hop the dec below walks INTO the gap and reads stale
    // bytes, producing a bogus line_ptr that _evf_window then chases
    // forever (BS-then-RIGHT hang).
    lda W0
    cmp edit_gap_end
    bne !+
    lda W0+1
    cmp edit_gap_end+1
    bne !+
    lda edit_gap_start
    sta W0
    lda edit_gap_start+1
    sta W0+1
!:
    // While W0 != buf_start AND *(W0-1) != '\n', W0--.
    lda W0
    cmp edit_buf_start
    bne _ebol_step
    lda W0+1
    cmp edit_buf_start+1
    beq _ebol_done
_ebol_step:
    // Decrement W0 by 1, then read *W0 (= the char that was at W0-1 before).
    lda W0
    bne !+
    dec W0+1
!:
    dec W0
    ldy #0
    lda (W0),y
    cmp #$0D
    bne _ebol_walk
    // *W0 is a newline → the line starts at W0+1. Step forward.
    inc W0
    bne !+
    inc W0+1
!:
    // If W0 == gap_start, jump to gap_end (cross the gap rightward).
    lda W0
    cmp edit_gap_start
    bne _ebol_done
    lda W0+1
    cmp edit_gap_start+1
    bne _ebol_done
    lda edit_gap_end
    sta W0
    lda edit_gap_end+1
    sta W0+1
_ebol_done:
    rts


// -----------------------------------------------------------------------------
// edit_eol — find the end of the line containing W0. Walks forward until
// either buf_end or *W0 == '\n'.
//   in:  W0 = pointer
//   out: W0 = pointer to the newline (or buf_end if line is the last and
//        unterminated).
//   clobbers: A, X, Y.
// -----------------------------------------------------------------------------
edit_eol:
    // If W0 == gap_start, jump to gap_end first.
    lda W0
    cmp edit_gap_start
    bne _eeol_loop
    lda W0+1
    cmp edit_gap_start+1
    bne _eeol_loop
    lda edit_gap_end
    sta W0
    lda edit_gap_end+1
    sta W0+1
_eeol_loop:
    // If W0 == buf_end, done.
    lda W0
    cmp edit_buf_end
    bne _eeol_step
    lda W0+1
    cmp edit_buf_end+1
    beq _eeol_done
_eeol_step:
    ldy #0
    lda (W0),y
    cmp #$0D
    beq _eeol_done
    inc W0
    bne !+
    inc W0+1
!:
    // After increment, if W0 == gap_start, jump to gap_end.
    lda W0
    cmp edit_gap_start
    bne _eeol_loop
    lda W0+1
    cmp edit_gap_start+1
    bne _eeol_loop
    lda edit_gap_end
    sta W0
    lda edit_gap_end+1
    sta W0+1
    jmp _eeol_loop
_eeol_done:
    rts


// -----------------------------------------------------------------------------
// edit_prevline — return start of the line *before* the line containing W0.
// If already on line 0, W0 is left at buf_start.
//   in:  W0 = pointer
//   out: W0 = previous line start (or buf_start)
// -----------------------------------------------------------------------------
edit_prevline:
    jsr edit_bol
    // If W0 == buf_start, we're at line 0 — done.
    lda W0
    cmp edit_buf_start
    bne _eprev_back
    lda W0+1
    cmp edit_buf_start+1
    beq _eprev_done
_eprev_back:
    // W0 currently points at a line-start. Step back over the newline that
    // ended the previous line, then bol() again.
    lda W0
    cmp edit_gap_end
    bne _eprev_dec
    // W0 == gap_end → cross the gap leftward.
    lda edit_gap_start
    sta W0
    lda edit_gap_start+1
    sta W0+1
_eprev_dec:
    lda W0
    bne !+
    dec W0+1
!:
    dec W0
    jsr edit_bol
_eprev_done:
    rts


// -----------------------------------------------------------------------------
// edit_nextline — return start of the line *after* the line containing W0.
// If already on the last line, W0 is left at buf_end.
//   in:  W0 = pointer
//   out: W0 = next line start (or buf_end)
// -----------------------------------------------------------------------------
edit_nextline:
    jsr edit_eol
    // If W0 == buf_end, no next line.
    lda W0
    cmp edit_buf_end
    bne _enext_step
    lda W0+1
    cmp edit_buf_end+1
    beq _enext_done
_enext_step:
    // *W0 is a newline (eol stops on '\n' or buf_end). Step past it.
    inc W0
    bne !+
    inc W0+1
!:
    // After step, if W0 == gap_start, cross the gap.
    lda W0
    cmp edit_gap_start
    bne _enext_done
    lda W0+1
    cmp edit_gap_start+1
    bne _enext_done
    lda edit_gap_end
    sta W0
    lda edit_gap_end+1
    sta W0+1
_enext_done:
    rts


// -----------------------------------------------------------------------------
// _edit_advance_w0 — increment W0 by 1, crossing the gap if W0 lands on
// gap_start. Internal helper used by render and key handlers.
//   in:  W0 = pointer
//   out: W0 advanced
//   clobbers: A. (Y/X preserved.)
// -----------------------------------------------------------------------------
_edit_advance_w0:
    inc W0
    bne !+
    inc W0+1
!:
    lda W0
    cmp edit_gap_start
    bne _eaw0_done
    lda W0+1
    cmp edit_gap_start+1
    bne _eaw0_done
    lda edit_gap_end
    sta W0
    lda edit_gap_end+1
    sta W0+1
_eaw0_done:
    rts


// -----------------------------------------------------------------------------
// edit_draw_line — render one logical line to a screen row.
//   in:  W0 = buffer pointer, start of line. May straddle the gap.
//        A  = screen row (0..SCREEN_ROWS-1).
//   out: W0 advanced past the trailing newline (or to buf_end if line was
//        unterminated).
//   clobbers: A, X, Y, W2, B0..B2.
//
// `edit_view_shift` is the horizontal-scroll offset: that many leading chars
// of the line are dropped. After drawing up to SCREEN_COLS chars, any
// further line content is skipped (long lines clip at the right edge).
// -----------------------------------------------------------------------------
edit_draw_line:
    jsr scr_row_offset_to_w2_a       // W2 = SCREEN_BASE + row*40

    // Phase 1: skip `view_shift` leading chars (or stop if line ends first).
    ldx edit_view_shift
_edl_skip:
    cpx #0
    beq _edl_draw_init
    jsr _edl_at_line_end
    bcs _edl_draw_init               // line shorter than shift → stop skipping
    jsr _edit_advance_w0
    dex
    jmp _edl_skip

_edl_draw_init:
    ldy #0                            // Y = current screen col

_edl_draw:
    cpy #SCREEN_COLS
    bcs _edl_skip_tail
    sty B0                            // stash screen col
    jsr _edl_at_line_end
    bcs _edl_blank
    ldy #0
    lda (W0),y
    jsr petscii_to_screen_code
    ldy B0
    sta (W2),y
    jsr _edit_advance_w0
    iny
    sty B0
    jmp _edl_draw
_edl_blank:
    ldy B0
_edl_blank_loop:
    cpy #SCREEN_COLS
    bcs _edl_skip_tail
    lda #$20
    sta (W2),y
    iny
    jmp _edl_blank_loop

_edl_skip_tail:
    // Walk W0 forward past the rest of the line and over the trailing
    // newline, leaving W0 at the start of the next line (or buf_end).
    jsr _edl_at_buf_end
    bcs _edl_done                    // already at buf_end
    ldy #0
    lda (W0),y
    cmp #$0D
    beq _edl_step_past_nl
    jsr _edit_advance_w0
    jmp _edl_skip_tail
_edl_step_past_nl:
    jsr _edit_advance_w0
_edl_done:
    rts


// _edl_at_line_end — Carry set if W0 is at end of line (buf_end or '\r').
//   in:  W0
//   out: C=1 if at line end, C=0 otherwise.
//   clobbers: A, Y.
_edl_at_line_end:
    lda W0
    cmp edit_buf_end
    bne _ell_check_nl
    lda W0+1
    cmp edit_buf_end+1
    beq _ell_yes
_ell_check_nl:
    ldy #0
    lda (W0),y
    cmp #$0D
    beq _ell_yes
    clc
    rts
_ell_yes:
    sec
    rts


// _edl_at_buf_end — Carry set if W0 == buf_end.
_edl_at_buf_end:
    lda W0
    cmp edit_buf_end
    bne _eabe_no
    lda W0+1
    cmp edit_buf_end+1
    bne _eabe_no
    sec
    rts
_eabe_no:
    clc
    rts


// -----------------------------------------------------------------------------
// edit_draw_screen — render `view_start` onward into the full 25 rows.
//   in:  edit_view_start, edit_view_shift, gap pointers.
//   out: dirty flags cleared.
//   clobbers: A, X, Y, W0, W2, B0..B2.
// -----------------------------------------------------------------------------
edit_draw_screen:
    lda edit_view_start
    sta W0
    lda edit_view_start+1
    sta W0+1
    // If W0 hits the gap, cross it.
    lda W0
    cmp edit_gap_start
    bne _eds_init
    lda W0+1
    cmp edit_gap_start+1
    bne _eds_init
    lda edit_gap_end
    sta W0
    lda edit_gap_end+1
    sta W0+1
_eds_init:
    ldx #0                            // X = current row
_eds_loop:
    cpx #SCREEN_ROWS
    bcs _eds_done
    stx B2
    txa
    jsr edit_draw_line
    ldx B2
    inx
    jmp _eds_loop
_eds_done:
    lda #0
    sta edit_dirty
    rts


// -----------------------------------------------------------------------------
// edit_draw_current_line — render only the line at edit_line, on row scr_y.
// -----------------------------------------------------------------------------
edit_draw_current_line:
    lda edit_line
    sta W0
    lda edit_line+1
    sta W0+1
    // If edit_line is at gap_start, hop W0 across to gap_end before drawing.
    // edit_view_focus only sets edit_line at line starts, but a newly-empty
    // buffer (after BS-to-empty) leaves edit_line == buf_start == gap_start,
    // so the renderer would otherwise read garbage gap bytes.
    lda W0
    cmp edit_gap_start
    bne _edcl_draw
    lda W0+1
    cmp edit_gap_start+1
    bne _edcl_draw
    lda edit_gap_end
    sta W0
    lda edit_gap_end+1
    sta W0+1
_edcl_draw:
    lda edit_scr_y
    jsr edit_draw_line
    lda #0
    sta edit_dirty
    rts


// -----------------------------------------------------------------------------
// edit_line_ptr_and_col_to_ptr — walk forward from line start by `col`
// chars, stopping early at newline or buf_end.
//   in:  W0 = line start, B0 = target column
//   out: W0 = pointer to the char at that column (or line/buf end)
//   clobbers: A, X, Y.
// -----------------------------------------------------------------------------
edit_line_ptr_and_col_to_ptr:
    ldx B0
_eltp_loop:
    cpx #0
    beq _eltp_done
    jsr _edl_at_line_end             // C=1 if at line end
    bcs _eltp_done
    jsr _edit_advance_w0
    dex
    jmp _eltp_loop
_eltp_done:
    rts


// -----------------------------------------------------------------------------
// edit_view_focus — recompute scr_x / scr_y / view_shift / view_start so the
// cursor is visible. Called after every key handler that moves edit_pos.
//
// Steps:
//   1. line_ptr = bol(pos)
//   2. col = chars from line_ptr to pos
//   3. Clamp view_shift so col is in [view_shift, view_shift + SCREEN_COLS).
//      scr_x = col - view_shift.
//   4. If line_ptr is before view_start: view_start = line_ptr, scr_y = 0.
//   5. Else walk view_start forward up to SCREEN_ROWS lines counting rows
//      until line_ptr is in the window; if not found, advance view_start
//      one line at a time and retry.
//
//   clobbers: A, X, Y, W0, W2, B0..B2.
// -----------------------------------------------------------------------------
edit_view_focus:
    // line_ptr = bol(pos)
    lda edit_pos
    sta W0
    lda edit_pos+1
    sta W0+1
    jsr edit_bol
    lda W0
    sta edit_line
    lda W0+1
    sta edit_line+1

    // For the col walk only: if W0 == gap_start, hop to gap_end. Same
    // logical position, but on the right side of the gap. Without this,
    // an empty buffer (or any line that starts at the gap boundary) makes
    // the col loop walk through gap bytes one at a time, giving
    // B0 = (buffer_size mod 256) and parking the cursor in nonsense
    // columns. We don't update edit_line here — _evf_window walks via
    // edit_nextline from view_start (which lives on the buf_start side
    // of the boundary), so edit_line must stay there to be findable.
    lda W0
    cmp edit_gap_start
    bne _evf_col_init
    lda W0+1
    cmp edit_gap_start+1
    bne _evf_col_init
    lda edit_gap_end
    sta W0
    lda edit_gap_end+1
    sta W0+1
_evf_col_init:
    // col = chars from line_ptr to pos, walking forward.
    lda #0
    sta B0
_evf_col_loop:
    lda W0
    cmp edit_pos
    bne _evf_col_step
    lda W0+1
    cmp edit_pos+1
    beq _evf_col_done
_evf_col_step:
    inc B0
    jsr _edit_advance_w0
    jmp _evf_col_loop
_evf_col_done:
    // Adjust view_shift so col is in [view_shift, view_shift + SCREEN_COLS).
    lda B0
    cmp edit_view_shift
    bcs _evf_check_right
    sta edit_view_shift              // col < view_shift → snap left
    jmp _evf_set_scr_x
_evf_check_right:
    sec
    lda B0
    sbc edit_view_shift
    cmp #SCREEN_COLS
    bcc _evf_set_scr_x
    sec
    lda B0
    sbc #SCREEN_COLS - 1
    sta edit_view_shift
_evf_set_scr_x:
    sec
    lda B0
    sbc edit_view_shift
    sta edit_scr_x

    // Vertical: if line_ptr < view_start, snap view_start = line_ptr.
    lda edit_line+1
    cmp edit_view_start+1
    bcc _evf_snap_up
    bne _evf_window
    lda edit_line
    cmp edit_view_start
    bcc _evf_snap_up
    jmp _evf_window
_evf_snap_up:
    lda edit_line
    sta edit_view_start
    lda edit_line+1
    sta edit_view_start+1
    lda #0
    sta edit_scr_y
    rts

_evf_window:
    // Walk view_start forward up to SCREEN_ROWS, looking for line_ptr.
    lda edit_view_start
    sta W0
    lda edit_view_start+1
    sta W0+1
    ldx #0
_evf_window_step:
    // If W0 == line_ptr, found.
    lda W0
    cmp edit_line
    bne _evf_window_next
    lda W0+1
    cmp edit_line+1
    beq _evf_window_found
_evf_window_next:
    cpx #SCREEN_ROWS - 1
    bcs _evf_advance_view            // not in window → scroll down 1
    jsr edit_nextline
    inx
    jmp _evf_window_step
_evf_window_found:
    stx edit_scr_y
    rts
_evf_advance_view:
    lda edit_view_start
    sta W0
    lda edit_view_start+1
    sta W0+1
    jsr edit_nextline
    lda W0
    sta edit_view_start
    lda W0+1
    sta edit_view_start+1
    jmp _evf_window


// -----------------------------------------------------------------------------
// edit_key_left — move cursor one byte left. Crosses gap and line breaks.
//   No-op if already at logical position 0. Returns C=1 if it moved, C=0 if
//   it didn't — edit_key_bs uses this to skip the trailing remove_char.
//
// At logical 0 means either (a) pos == buf_start, or (b) pos == gap_end AND
// gap_start == buf_start (the gap covers the whole prefix; cursor is on the
// right side of the gap but logically at position 0). In the no-move case
// we must NOT mutate pos — leaving it at gap_end vs flipping to gap_start
// both represent the same logical position, but downstream code reads pos
// directly and assumes its representation is stable across no-op moves.
// -----------------------------------------------------------------------------
edit_key_left:
    // Case (a): pos == buf_start → already at logical 0.
    lda edit_pos
    cmp edit_buf_start
    bne _ekl_check_post_gap
    lda edit_pos+1
    cmp edit_buf_start+1
    beq _ekl_no_move
_ekl_check_post_gap:
    // Case (b): pos == gap_end. Check whether anything sits before the gap.
    lda edit_pos
    cmp edit_gap_end
    bne _ekl_dec
    lda edit_pos+1
    cmp edit_gap_end+1
    bne _ekl_dec
    // pos == gap_end. If gap_start == buf_start, prefix is empty → logical 0.
    lda edit_gap_start
    cmp edit_buf_start
    bne _ekl_hop
    lda edit_gap_start+1
    cmp edit_buf_start+1
    beq _ekl_no_move
_ekl_hop:
    // pos at gap_end with non-empty prefix: hop to gap_start, then decrement.
    lda edit_gap_start
    sta edit_pos
    lda edit_gap_start+1
    sta edit_pos+1
_ekl_dec:
    lda edit_pos
    bne !+
    dec edit_pos+1
!:
    dec edit_pos
    sec
    rts
_ekl_no_move:
    clc
    rts


// -----------------------------------------------------------------------------
// edit_key_right — move cursor one byte right. Crosses gap and line breaks.
//   No-op if already at buf_end.
// -----------------------------------------------------------------------------
edit_key_right:
    lda edit_pos
    cmp edit_buf_end
    bne _ekr_proceed
    lda edit_pos+1
    cmp edit_buf_end+1
    beq _ekr_done
_ekr_proceed:
    // If pos == gap_start, jump to gap_end first.
    lda edit_pos
    cmp edit_gap_start
    bne _ekr_inc
    lda edit_pos+1
    cmp edit_gap_start+1
    bne _ekr_inc
    lda edit_gap_end
    sta edit_pos
    lda edit_gap_end+1
    sta edit_pos+1
_ekr_inc:
    inc edit_pos
    bne !+
    inc edit_pos+1
!:
    // After increment, if pos == gap_start, hop over the gap.
    lda edit_pos
    cmp edit_gap_start
    bne _ekr_done
    lda edit_pos+1
    cmp edit_gap_start+1
    bne _ekr_done
    lda edit_gap_end
    sta edit_pos
    lda edit_gap_end+1
    sta edit_pos+1
_ekr_done:
    rts


// -----------------------------------------------------------------------------
// edit_key_up — move cursor to the same column on the previous line, or
// clamp to end-of-prev-line if shorter. No-op if already on first line.
// -----------------------------------------------------------------------------
edit_key_up:
    // line_ptr = prevline(line_ptr)
    lda edit_line
    sta W0
    lda edit_line+1
    sta W0+1
    jsr edit_prevline
    lda W0
    sta edit_line
    lda W0+1
    sta edit_line+1

    // col = scr_x + view_shift; pos = line_ptr advanced by col chars.
    clc
    lda edit_scr_x
    adc edit_view_shift
    sta B0
    jsr edit_line_ptr_and_col_to_ptr
    lda W0
    sta edit_pos
    lda W0+1
    sta edit_pos+1
    rts


// -----------------------------------------------------------------------------
// edit_key_down — move cursor to next line. No-op if already on last line.
// -----------------------------------------------------------------------------
edit_key_down:
    // If eol(pos) == buf_end, we're on the last line — bail.
    lda edit_pos
    sta W0
    lda edit_pos+1
    sta W0+1
    jsr edit_eol
    lda W0
    cmp edit_buf_end
    bne _ekd_have_next
    lda W0+1
    cmp edit_buf_end+1
    beq _ekd_done
_ekd_have_next:
    lda edit_line
    sta W0
    lda edit_line+1
    sta W0+1
    jsr edit_nextline
    lda W0
    sta edit_line
    lda W0+1
    sta edit_line+1

    clc
    lda edit_scr_x
    adc edit_view_shift
    sta B0
    jsr edit_line_ptr_and_col_to_ptr
    lda W0
    sta edit_pos
    lda W0+1
    sta edit_pos+1
_ekd_done:
    rts


// -----------------------------------------------------------------------------
// edit_key_bs — backspace: move left, then forward-delete. If left was a
// no-op (we were already at logical 0) skip the delete — otherwise we'd
// remove the first character of the buffer.
// -----------------------------------------------------------------------------
edit_key_bs:
    jsr edit_key_left
    bcc _ekbs_done
    jsr edit_remove_char
_ekbs_done:
    rts


// -----------------------------------------------------------------------------
// Clipboard: 80-byte static buffer + length byte. Used by F5 (kill) and F7
// (yank). Static (not heap-allocated) so it survives across edit() calls
// without GC concerns.
// -----------------------------------------------------------------------------
.const EDIT_CLIP_CAP = 80
edit_clip_buf:    .fill EDIT_CLIP_CAP, 0
edit_clip_len:    .byte 0


// -----------------------------------------------------------------------------
// edit_key_kill — kill from cursor to end-of-line into the clipboard.
// Behavior:
//   - If `edit_clip_cut` is 0, the clipboard is overwritten (fresh kill).
//   - If 1 (set on the previous keypress that was also a kill), the new
//     content is appended to the clipboard.
//   - If the cursor is already at end-of-line, kill the trailing newline.
//   - Sets `edit_clip_cut = 1` on the way out so the next kill appends.
//
// Caller is responsible for marking edit_clip_cut = 0 on any non-kill key
// (the main dispatcher does this).
// -----------------------------------------------------------------------------
edit_key_kill:
    // If edit_clip_cut == 0, reset clip length first.
    lda edit_clip_cut
    bne _ekk_have_clip
    lda #0
    sta edit_clip_len
_ekk_have_clip:
    // Find EOL of current line. W0 = pos initially.
    lda edit_pos
    sta W0
    lda edit_pos+1
    sta W0+1
    jsr edit_eol
    // If pos == eol → kill the newline char (1 byte) instead.
    lda W0
    cmp edit_pos
    bne _ekk_walk
    lda W0+1
    cmp edit_pos+1
    bne _ekk_walk
    // pos == eol: at end of line. Kill the '\r' (or no-op if at buf_end).
    lda edit_pos
    cmp edit_buf_end
    bne _ekk_kill_nl
    lda edit_pos+1
    cmp edit_buf_end+1
    beq _ekk_done
_ekk_kill_nl:
    // Append '\r' to clip then remove_char.
    ldx edit_clip_len
    cpx #EDIT_CLIP_CAP
    bcs _ekk_skip_clip_nl
    lda #$0D
    sta edit_clip_buf,x
    inc edit_clip_len
_ekk_skip_clip_nl:
    jsr edit_remove_char
    jmp _ekk_set_flag

_ekk_walk:
    // Walk: while pos < eol, append *pos to clip and remove_char.
    // Save eol's pointer in B0:B1 (it might shift relative to the gap as
    // remove_char fires, but actually remove_char only changes gap_end
    // forward — the post-gap shrinks by 1 each call, but the LOGICAL
    // content "to the right of cursor" changes too. So eol may need to
    // be recomputed each iteration. Easiest: just check at-line-end each
    // iteration.
_ekk_loop:
    // If at-line-end → done.
    lda edit_pos
    sta W0
    lda edit_pos+1
    sta W0+1
    jsr _edl_at_line_end
    bcs _ekk_done_walk
    // Read char at pos (cross gap if needed).
    lda edit_pos
    cmp edit_gap_start
    bne _ekk_read
    lda edit_pos+1
    cmp edit_gap_start+1
    bne _ekk_read
    // pos is at gap_start: actual byte is at gap_end.
    lda edit_gap_end
    sta W0
    lda edit_gap_end+1
    sta W0+1
    jmp _ekk_read_w0
_ekk_read:
    lda edit_pos
    sta W0
    lda edit_pos+1
    sta W0+1
_ekk_read_w0:
    ldy #0
    lda (W0),y
    // Append to clip if room.
    ldx edit_clip_len
    cpx #EDIT_CLIP_CAP
    bcs _ekk_skip_append
    sta edit_clip_buf,x
    inc edit_clip_len
_ekk_skip_append:
    jsr edit_remove_char
    jmp _ekk_loop
_ekk_done_walk:
_ekk_set_flag:
    lda #1
    sta edit_clip_cut
_ekk_done:
    rts


// -----------------------------------------------------------------------------
// edit_key_newline — insert '\r' at cursor and copy the leading whitespace of
// the previous line as auto-indent.
//
// After edit_insert_char('\r'), edit_line still references the OLD line in
// pre-gap. We walk it forward, copying spaces until we hit gap_start (which
// now holds the just-inserted '\r' at gap_start - 1) or a non-space byte.
//
// Edge case: when the cursor was at column 0 of a line that lives in
// post-gap, edit_line == gap_end. The line "above" the new cursor is then
// the freshly-inserted empty line, so we skip auto-indent entirely.
// -----------------------------------------------------------------------------
edit_key_newline:
    lda #$0D
    jsr edit_insert_char             // clobbers W0..W2

    // Skip if edit_line is in post-gap (cursor was at column 0).
    lda edit_line
    cmp edit_gap_end
    bne _eknl_walk_init
    lda edit_line+1
    cmp edit_gap_end+1
    beq _eknl_done
_eknl_walk_init:
    lda edit_line
    sta W0
    lda edit_line+1
    sta W0+1
_eknl_loop:
    // Stop if W0 reaches gap_start (the '\r' we just inserted lives at
    // gap_start - 1, so stepping further would cross into gap content).
    lda W0
    cmp edit_gap_start
    bne _eknl_check
    lda W0+1
    cmp edit_gap_start+1
    beq _eknl_done
_eknl_check:
    ldy #0
    lda (W0),y
    cmp #$20
    bne _eknl_done
    // *W0 is a space. Save W0 across edit_insert_char (which clobbers it),
    // insert ' ', restore W0, advance.
    lda W0
    pha
    lda W0+1
    pha
    lda #$20
    jsr edit_insert_char
    pla
    sta W0+1
    pla
    sta W0
    inc W0
    bne _eknl_loop
    inc W0+1
    jmp _eknl_loop
_eknl_done:
    rts


// -----------------------------------------------------------------------------
// edit_key_yank — insert the clipboard contents at cursor.
//   No-op if clip is empty.
// -----------------------------------------------------------------------------
edit_key_yank:
    lda edit_clip_len
    beq _eky_done
    ldx #0
_eky_loop:
    cpx edit_clip_len
    bcs _eky_done
    txa
    pha                              // save loop counter (insert clobbers X)
    lda edit_clip_buf,x
    jsr edit_insert_char
    pla
    tax
    inx
    jmp _eky_loop
_eky_done:
    rts
