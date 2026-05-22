// -----------------------------------------------------------------------------
// gc.asm — mark-sweep-compact garbage collector.
//
// Root set: every word on RS, exclusively. RS is the only GC-visible stack,
// so marking is a single linear walk from RSP to RS_END.
//
// Live handles live on the RESERVED list (appended at tail by alloc, in
// H_PTR-ascending order). Both sweep and compact walk this list in O(N).
// Dead handles live on FREE_HEAD. gc_sweep moves unmarked handles from
// RESERVED to FREE in a single pass.
//
// Transitive marking for containers uses a tri-color invariant:
//   white = !MARKED            (unreachable so far)
//   gray  =  MARKED |  GRAY    (reachable, children not yet traced)
//   black =  MARKED & !GRAY    (reachable, children traced)
//
// Phase 1 walks RS and turns roots gray. Phase 2 scans the RESERVED list,
// turning gray container handles black and pushing children gray. Phase 2
// repeats until a full scan finds no gray — fixed-point on the GRAY bit.
// O(N²) worst case, fine for our handle counts.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"

// -----------------------------------------------------------------------------
// gc_mark — transitive mark of every reachable handle from the RS root set.
//
// Phase 1: walk RS, OR FLAG_MARKED|FLAG_GRAY into each root's H_FLAGS.
// Phase 2: scan the RESERVED list. For each GRAY handle, clear GRAY (black);
//          if it's a container, OR MARKED|GRAY into each child that isn't
//          already MARKED. Repeat until a clean pass finds zero gray handles.
//
// At exit, every reachable handle on RESERVED has FLAG_MARKED set and
// FLAG_GRAY clear. Static handles (off RESERVED) may retain FLAG_GRAY — that's
// harmless because no other code reads it.
//
// Leaf helper contract:
//   in:  RSP, RESERVED_HEAD, handle topology.
//   out: All reachable RESERVED handles end up in the black state (MARKED set,
//        GRAY clear). Other flag bits preserved.
//   clobbers: A, X, Y, W0-W3, B0. No allocation, no V4' sub-calls.
// -----------------------------------------------------------------------------
gc_mark:
    // --- Phase 1: roots → gray. ------------------------------------
    lda RSP
    sta W0
    lda RSP+1
    sta W0+1

gc_mark_root_loop:
    sec
    lda W0
    sbc #<RS_END
    lda W0+1
    sbc #>RS_END
    bcs gc_mark_phase2

    ldy #0
    lda (W0),y
    sta W1
    iny
    lda (W0),y
    sta W1+1

    // Null roots are valid placeholders (e.g. _llp_str_call pushes a 0 in
    // the `me` slot for non-method calls). Skip them — without this guard,
    // `STA (W1),y` with W1=0 and Y=7 lands on ZP $07 (= FP+1) and silently
    // corrupts the frame pointer mid-execution.
    lda W1
    ora W1+1
    beq gc_mark_root_skip

    ldy #H_FLAGS
    lda (W1),y
    ora #FLAG_MARKED|FLAG_GRAY
    sta (W1),y

gc_mark_root_skip:
    clc
    lda W0
    adc #2
    sta W0
    bcc gc_mark_root_loop
    inc W0+1
    jmp gc_mark_root_loop

    // --- Phase 2: drain gray → black, propagating to children. -----
gc_mark_phase2:
    lda #0
    sta B0                       // saw_gray flag for this pass

    lda RESERVED_HEAD
    sta W0
    lda RESERVED_HEAD+1
    sta W0+1

gc_mark_p2_loop:
    lda W0
    ora W0+1
    beq gc_mark_p2_pass_done

    ldy #H_FLAGS
    lda (W0),y
    and #FLAG_GRAY
    beq gc_mark_p2_advance       // not gray → skip

    inc B0                       // record that we did work
    ldy #H_FLAGS
    lda (W0),y
    and #FLAG_GRAY ^ $FF         // clear GRAY (gray → black)
    sta (W0),y

    // Type dispatch: container types carry handle children. Tuples and lists
    // share the "N consecutive 16-bit handles" payload shape, so a single
    // tracer (`_gc_trace_array`) handles both. When TYPE_DICT lands it'll need
    // its own tracer because of the differing layout.
    //
    // Leaf types (TYPE_INT, TYPE_STR, TYPE_BOOL, TYPE_NONE, TYPE_FLOAT) skip
    // tracing — they have no child handles. The mark bit is already set above.
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_TUPLE
    beq _gc_mark_trace_array
    cmp #TYPE_LIST
    beq _gc_mark_trace_array
    cmp #TYPE_DICT
    beq _gc_mark_trace_array
    cmp #TYPE_REF
    beq _gc_mark_trace_array
    cmp #TYPE_SUB
    bne gc_mark_p2_advance
_gc_mark_trace_array:
    jsr _gc_trace_array

gc_mark_p2_advance:
    ldy #H_NEXT
    lda (W0),y
    sta W1
    iny
    lda (W0),y
    sta W0+1
    lda W1
    sta W0
    jmp gc_mark_p2_loop

gc_mark_p2_pass_done:
    lda B0
    bne gc_mark_phase2           // saw gray → repeat from top of RESERVED
    rts

// -----------------------------------------------------------------------------
// _gc_trace_array — for each child handle in the sequence container at W0, OR
// MARKED|GRAY into the child's H_FLAGS (unless already MARKED). Null slots
// are skipped. Generic over TYPE_TUPLE and TYPE_LIST — they share a payload
// shape (N consecutive 16-bit handles).
//
// Leaf-helper contract:
//   in:  W0 = container handle. Caller has already cleared its GRAY bit.
//   clobbers: A, X, Y, W2, W3 (W0 / W1 preserved).
// -----------------------------------------------------------------------------
_gc_trace_array:
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1

    // 16-bit element count in B6:B7. (B0..B5 belong to gc_mark_phase2 /
    // its callers — `inc B0` is its saw_gray flag and must not be touched.)
    ldy #O_LEN
    lda (W2),y
    sta B6
    iny
    lda (W2),y
    sta B7
    ora B6
    beq _gtt_done

    clc
    lda W2
    adc #O_HEADER
    sta W2
    bcc !+
    inc W2+1
!:

_gtt_loop:
    ldy #0
    lda (W2),y
    sta W3
    iny
    lda (W2),y
    sta W3+1

    // Skip null slots.
    lda W3
    ora W3+1
    beq _gtt_advance

    // If already marked, leave it alone (cycle break).
    ldy #H_FLAGS
    lda (W3),y
    and #FLAG_MARKED
    bne _gtt_advance

    ldy #H_FLAGS
    lda (W3),y
    ora #FLAG_MARKED|FLAG_GRAY
    sta (W3),y

_gtt_advance:
    clc
    lda W2
    adc #2
    sta W2
    bcc !+
    inc W2+1
!:
    // 16-bit dec on B6:B7; loop while non-zero.
    lda B6
    bne !+
    dec B7
!:
    dec B6
    lda B6
    ora B7
    bne _gtt_loop
_gtt_done:
    rts

// -----------------------------------------------------------------------------
// gc_sweep — walk the reserved list once, splitting into survivors and garbage.
//
// For each handle:
//   - FLAG_MARKED set → clear the mark bit, keep in reserved list.
//   - FLAG_MARKED clear → prepend onto FREE_HEAD.
//
// The reserved list is rebuilt in place via a "previous survivor" pointer
// (W1). Garbage handles are unlinked by simply not being linked from the
// previous survivor. After the walk, the last survivor (W1) gets H_NEXT=0
// as the new tail terminator.
//
// Data payloads are NOT reclaimed here — compact does that.
//
// Leaf helper contract:
//   in:  RESERVED_HEAD, handle mark bits.
//   out: RESERVED_HEAD/TAIL point to the survivor list (or 0/0 if none).
//        FREE_HEAD has unmarked handles prepended.
//        Survivors' FLAG_MARKED cleared; other flag bits preserved.
//   clobbers: A, Y, W0-W3. No allocation, no V4' sub-calls.
// -----------------------------------------------------------------------------
gc_sweep:
    // W0 = iterator, starts at RESERVED_HEAD.
    // W1 = previous survivor (0 means "no survivor yet").
    // W2 = first survivor (buffered for RESERVED_HEAD write at end).
    lda RESERVED_HEAD
    sta W0
    lda RESERVED_HEAD+1
    sta W0+1
    lda #0
    sta W1
    sta W1+1
    sta W2
    sta W2+1

gc_sweep_loop:
    // If iterator is null → done.
    lda W0
    ora W0+1
    beq gc_sweep_done

    // Save next = W0.H_NEXT into W3 before we possibly mutate it.
    ldy #H_NEXT
    lda (W0),y
    sta W3
    iny
    lda (W0),y
    sta W3+1

    // Inspect FLAG_MARKED.
    ldy #H_FLAGS
    lda (W0),y
    bpl gc_sweep_free            // bit 7 clear → unmarked → free it

    // Survivor: clear mark bit, preserve others.
    and #FLAG_MARKED ^ $FF       // ≡ #$7F
    sta (W0),y

    // Link into rebuilt reserved list.
    lda W1
    ora W1+1
    bne gc_sweep_have_prev
    // First survivor — remember for RESERVED_HEAD.
    lda W0
    sta W2
    lda W0+1
    sta W2+1
    jmp gc_sweep_set_prev
gc_sweep_have_prev:
    // W1.H_NEXT = W0
    ldy #H_NEXT
    lda W0
    sta (W1),y
    iny
    lda W0+1
    sta (W1),y
gc_sweep_set_prev:
    lda W0
    sta W1
    lda W0+1
    sta W1+1
    jmp gc_sweep_advance

gc_sweep_free:
    // Garbage — prepend onto FREE_HEAD.
    // W0.H_NEXT = FREE_HEAD
    ldy #H_NEXT
    lda FREE_HEAD
    sta (W0),y
    iny
    lda FREE_HEAD+1
    sta (W0),y
    // FREE_HEAD = W0
    lda W0
    sta FREE_HEAD
    lda W0+1
    sta FREE_HEAD+1

gc_sweep_advance:
    lda W3
    sta W0
    lda W3+1
    sta W0+1
    jmp gc_sweep_loop

gc_sweep_done:
    // RESERVED_HEAD = first survivor (W2; 0 if no survivors).
    lda W2
    sta RESERVED_HEAD
    lda W2+1
    sta RESERVED_HEAD+1
    // RESERVED_TAIL = last survivor (W1; 0 if no survivors).
    lda W1
    sta RESERVED_TAIL
    lda W1+1
    sta RESERVED_TAIL+1
    // Terminate rebuilt list: W1.H_NEXT = 0 (only if we had at least one).
    lda W1
    ora W1+1
    beq !+
    lda #0
    ldy #H_NEXT
    sta (W1),y
    iny
    sta (W1),y
!:
    rts

// -----------------------------------------------------------------------------
// gc_compact — slide live heap data down to eliminate gaps from freed objects.
//
// Walks the reserved list (already in H_PTR-ascending order). For each handle:
// copy H_SIZE bytes from H_PTR down to GC_DEST, update H_PTR, advance GC_DEST.
// Finally NEXT_DATA = GC_DEST.
//
// O(N) — no sort, no find-min. Relies on the alloc-appends-to-tail invariant
// that keeps the list in H_PTR order.
//
// Leaf helper contract:
//   in:  RESERVED_HEAD.
//   out: Live handles' H_PTR points into packed region starting at
//        HEAP_DATA_START; NEXT_DATA = end of packed region.
//   clobbers: A, Y, W0-W3, GC_DEST. No alloc, no V4' sub-calls.
// -----------------------------------------------------------------------------
gc_compact:
    lda #<HEAP_DATA_START
    sta GC_DEST
    lda #>HEAP_DATA_START
    sta GC_DEST+1

    lda RESERVED_HEAD
    sta W0
    lda RESERVED_HEAD+1
    sta W0+1

gc_compact_loop:
    lda W0
    ora W0+1
    beq gc_compact_done

    // Inline ints (TYPE_INT) carry their 32-bit value in H_PTR+H_SIZE and own
    // no heap payload — skip them entirely (no copy, no GC_DEST advance, no
    // H_PTR rewrite, which would corrupt the value).
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_INT
    beq gc_compact_advance

    // W2 = source = W0.H_PTR
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1

    // W3 = size = W0.H_SIZE
    ldy #H_SIZE
    lda (W0),y
    sta W3
    iny
    lda (W0),y
    sta W3+1

    // W0.H_PTR = GC_DEST (new position)
    ldy #H_PTR
    lda GC_DEST
    sta (W0),y
    iny
    lda GC_DEST+1
    sta (W0),y

    // Shortcut: source == dest → no bytes to move, just bump GC_DEST.
    lda W2
    cmp GC_DEST
    bne gc_compact_do_move
    lda W2+1
    cmp GC_DEST+1
    bne gc_compact_do_move

    clc
    lda GC_DEST
    adc W3
    sta GC_DEST
    lda GC_DEST+1
    adc W3+1
    sta GC_DEST+1
    jmp gc_compact_advance

gc_compact_do_move:
    jsr mem_copy_down            // mutates W2, GC_DEST forward; W3 → 0

gc_compact_advance:
    // W0 = W0.H_NEXT (reuse W1 as scratch for the byte transpose).
    ldy #H_NEXT
    lda (W0),y
    sta W1
    iny
    lda (W0),y
    sta W0+1
    lda W1
    sta W0
    jmp gc_compact_loop

gc_compact_done:
    lda GC_DEST
    sta NEXT_DATA
    lda GC_DEST+1
    sta NEXT_DATA+1
    rts

// -----------------------------------------------------------------------------
// mem_copy_down — forward copy of W3 bytes from (W2) to (GC_DEST). Shared
// primitive: used by `gc_compact` (where it slides live data down to close
// gaps) and by `screen_scroll_up` (where it slides 24 rows up by one row,
// also a downward-address copy in screen RAM).
//
// Page-loop pattern: Y indexes within the current 256-byte page; X counts
// whole pages (W3+1), then remainder (W3). Only the high bytes of the
// pointers get bumped (once per page).
//
// Forward copy is safe ONLY when source > dest (no aliasing of unread
// bytes). Both current callers satisfy this — there is no general "memmove"
// here; the name reflects the direction.
//
// Side effects:
//   - GC_DEST is advanced to dest + W3 (caller's next-iteration anchor).
//   - W2's low byte is unchanged, W2+1 is advanced by (W3+1). Since compact
//     reloads W2 from the next handle, this is harmless.
//   - W3 is PRESERVED (read-only). Better register discipline than the
//     previous implementation.
// -----------------------------------------------------------------------------
mem_copy_down:
    ldy #0
    ldx W3+1                 // page count
    beq _gmm_tail
_gmm_page:
    lda (W2),y
    sta (GC_DEST),y
    iny
    bne _gmm_page            // Y wraps 0→0 exits the page
    inc W2+1
    inc GC_DEST+1
    dex
    bne _gmm_page
_gmm_tail:
    ldx W3                   // remainder (low byte)
    beq _gmm_fixup
_gmm_tail_loop:
    lda (W2),y
    sta (GC_DEST),y
    iny
    dex
    bne _gmm_tail_loop
_gmm_fixup:
    // Advance GC_DEST low byte by Y (the tail index). Pages already bumped
    // GC_DEST+1 one step per page, so we only add the in-page offset here.
    tya
    clc
    adc GC_DEST
    sta GC_DEST
    bcc !+
    inc GC_DEST+1
!:
    rts

// -----------------------------------------------------------------------------
// gc_collect — full mark + sweep + compact cycle.
//
// Around `gc_compact` we bracket with `_lex_to_offsets` / `_lex_from_offsets`
// so the active lexer state survives a payload relocation. The pointer
// fields LEX_PTR / LEX_END / LEX_TOKEN_* are the only program state that
// holds raw addresses into a heap payload; every other pointer in the
// program is either a handle (which never moves) or accessed via H_PTR
// re-deref on demand. If LEX_SRC_HANDLE is null (no active lex, or the
// fixture-style place_str source not in the GC'd heap) we skip the rebase —
// it's a no-op.
// -----------------------------------------------------------------------------
gc_collect:
    jsr gc_mark
    jsr gc_sweep

    lda LEX_SRC_HANDLE
    ora LEX_SRC_HANDLE+1
    beq _gcc_no_lex_pre
    jsr _lex_load_base
    jsr _lex_to_offsets
_gcc_no_lex_pre:

    jsr gc_compact

    lda LEX_SRC_HANDLE
    ora LEX_SRC_HANDLE+1
    beq _gcc_no_lex_post
    jsr _lex_load_base
    jsr _lex_from_offsets
_gcc_no_lex_post:
    rts
