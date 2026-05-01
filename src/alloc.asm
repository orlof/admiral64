// -----------------------------------------------------------------------------
// Bump-and-free allocator with live + free handle lists.
//
// Handle table grows DOWN from HEAP_HANDLE_START.
// Data heap   grows UP   from HEAP_DATA_START.
//
// Each allocated handle is on exactly one list:
//   - RESERVED list (live) — chained via H_NEXT, head RESERVED_HEAD, tail
//     RESERVED_TAIL. Alloc appends new/reused handles at the tail, so the
//     list is always in H_PTR-ascending order (data grows up monotonically).
//     gc_sweep and gc_compact both walk this list in O(N).
//   - FREE_HEAD list — chained via H_NEXT, LIFO. Unallocated handles.
//
// Calling convention (V4'):
//   - Caller presets ALLOC_SIZE (word) and ALLOC_TYPE (byte) in ZP, then JSRs
//     alloc. No register args. Write ALLOC_SIZE/ALLOC_TYPE immediately before
//     the JSR — an intervening JSR could overwrite them via its own alloc.
//   - Returns new handle address in RV. ALWAYS a valid handle — OOM is a
//     fatal panic, not a soft failure, so callers can assume success.
//   - alloc_int is a thin wrapper: presets ALLOC_TYPE = TYPE_INT, then JMP alloc.
//
// OOM-triggered GC retry: on the first failed OOM check within a single alloc
// call, we invoke gc_collect once and re-run the check. If the second check
// also fails, we store ERR_OOM in ERROR_CODE and jump to error_handler —
// alloc never returns on OOM.
//
// OOM policy: before advancing any state, verify that the heap can fit the
// requested payload, plus a handle slot if one must be carved:
//     need_data   = ALLOC_SIZE + O_HEADER
//     need_handle = SIZEOF_HANDLE if FREE_HEAD == 0 else 0
//     need        = need_data + need_handle
//     NEXT_HANDLE - NEXT_DATA  >=  need
// If any of the 16-bit additions carry out, the request is already wider than
// the address space and we trap without computing the gap.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

// -----------------------------------------------------------------------------
// alloc_init — reset allocator pointers, free list, and reserved list.
// -----------------------------------------------------------------------------
alloc_init:
    lda #<HEAP_DATA_START
    sta NEXT_DATA
    lda #>HEAP_DATA_START
    sta NEXT_DATA+1
    lda #<HEAP_HANDLE_START
    sta NEXT_HANDLE
    lda #>HEAP_HANDLE_START
    sta NEXT_HANDLE+1
    lda #0
    sta FREE_HEAD
    sta FREE_HEAD+1
    sta RESERVED_HEAD
    sta RESERVED_HEAD+1
    sta RESERVED_TAIL
    sta RESERVED_TAIL+1
    rts

// -----------------------------------------------------------------------------
// alloc — allocate a heap object + handle.
//   in:  ALLOC_SIZE (word), ALLOC_TYPE (byte) — preset in ZP by caller
//   out: RV = handle address. OOM is a fatal panic, not a return value.
// -----------------------------------------------------------------------------
alloc:
    preamble_args(0, 0)
    lda #0
    sta ALLOC_GC_TRIED            // reset per-call retry marker

alloc_check:
    // 0a. W1 = need_data = ALLOC_SIZE + O_HEADER.
    clc
    lda ALLOC_SIZE
    adc #O_HEADER
    sta W1
    lda ALLOC_SIZE+1
    adc #0
    sta W1+1
    bcs alloc_oom                 // need_data overflows 16 bits

    // 0b. If the free list is empty, add SIZEOF_HANDLE to need.
    lda FREE_HEAD
    ora FREE_HEAD+1
    bne alloc_need_ready
    clc
    lda W1
    adc #SIZEOF_HANDLE
    sta W1
    lda W1+1
    adc #0
    sta W1+1
    bcs alloc_oom
alloc_need_ready:

    // 0c. W0 = gap = NEXT_HANDLE - NEXT_DATA (invariant: NEXT_HANDLE >= NEXT_DATA).
    sec
    lda NEXT_HANDLE
    sbc NEXT_DATA
    sta W0
    lda NEXT_HANDLE+1
    sbc NEXT_DATA+1
    sta W0+1

    // 0d. OOM if gap < need.
    sec
    lda W0
    sbc W1
    lda W0+1
    sbc W1+1
    bcs alloc_ok

alloc_oom:
    // First OOM within this call → try a GC pass and re-check. Second time
    // through, we give up and surface the failure.
    lda ALLOC_GC_TRIED
    bne alloc_really_oom
    inc ALLOC_GC_TRIED
    jsr gc_collect
    jmp alloc_check

alloc_really_oom:
    jmp panic_oom

alloc_ok:
    // 1. Acquire handle: reuse from free list, or carve from NEXT_HANDLE.
    lda FREE_HEAD
    ora FREE_HEAD+1
    beq alloc_carve_new

    // Reuse: W0 = FREE_HEAD; FREE_HEAD = (W0).H_NEXT.
    lda FREE_HEAD
    sta W0
    lda FREE_HEAD+1
    sta W0+1
    ldy #H_NEXT
    lda (W0),y
    sta FREE_HEAD
    iny
    lda (W0),y
    sta FREE_HEAD+1
    jmp alloc_populate

alloc_carve_new:
    sec
    lda NEXT_HANDLE
    sbc #SIZEOF_HANDLE
    sta NEXT_HANDLE
    sta W0
    lda NEXT_HANDLE+1
    sbc #0
    sta NEXT_HANDLE+1
    sta W0+1

alloc_populate:
    // 2a. H_PTR = NEXT_DATA
    ldy #H_PTR
    lda NEXT_DATA
    sta (W0),y
    iny
    lda NEXT_DATA+1
    sta (W0),y

    // 2b. H_SIZE = ALLOC_SIZE + O_HEADER (16-bit)
    lda ALLOC_SIZE
    clc
    adc #O_HEADER
    ldy #H_SIZE
    sta (W0),y
    iny
    lda ALLOC_SIZE+1
    adc #0
    sta (W0),y

    // 2c. H_NEXT = 0 (clean slate; leave no stale free-list linkage)
    lda #0
    ldy #H_NEXT
    sta (W0),y
    iny
    sta (W0),y

    // 2d. H_TYPE
    lda ALLOC_TYPE
    ldy #H_TYPE
    sta (W0),y

    // 2e. H_FLAGS = 0
    ldy #H_FLAGS
    lda #0
    sta (W0),y

    // 3. Write O_LEN (word) header at NEXT_DATA.
    ldy #O_LEN
    lda ALLOC_SIZE
    sta (NEXT_DATA),y
    iny
    lda ALLOC_SIZE+1
    sta (NEXT_DATA),y

    // 4. Return new handle in RV.
    lda W0
    sta RV
    lda W0+1
    sta RV+1

    // 5. Bump NEXT_DATA by ALLOC_SIZE + O_HEADER (16-bit).
    clc
    lda NEXT_DATA
    adc ALLOC_SIZE
    sta NEXT_DATA
    lda NEXT_DATA+1
    adc ALLOC_SIZE+1
    sta NEXT_DATA+1
    clc
    lda NEXT_DATA
    adc #O_HEADER
    sta NEXT_DATA
    bcc !+
    inc NEXT_DATA+1
!:

    // 6. Append W0 (new handle) to the reserved list. H_NEXT was already 0'd
    //    in step 2c, so the new entry is a valid tail. Empty-list case: set
    //    both HEAD and TAIL; otherwise patch the old tail's H_NEXT.
    lda RESERVED_TAIL
    ora RESERVED_TAIL+1
    bne alloc_append_link
    // Empty list: RESERVED_HEAD = W0.
    lda W0
    sta RESERVED_HEAD
    lda W0+1
    sta RESERVED_HEAD+1
    jmp alloc_set_tail
alloc_append_link:
    // old_tail.H_NEXT = W0
    lda RESERVED_TAIL
    sta W1
    lda RESERVED_TAIL+1
    sta W1+1
    ldy #H_NEXT
    lda W0
    sta (W1),y
    iny
    lda W0+1
    sta (W1),y
alloc_set_tail:
    lda W0
    sta RESERVED_TAIL
    lda W0+1
    sta RESERVED_TAIL+1

    jmp postamble

// -----------------------------------------------------------------------------
// alloc_int — convenience wrapper: alloc() with type = TYPE_INT.
//   in:  ALLOC_SIZE (word) preset by caller
//   out: RV = new int handle. OOM is a fatal panic, not a return value.
// -----------------------------------------------------------------------------
alloc_int:
    lda #TYPE_INT
    sta ALLOC_TYPE
    jmp alloc

// -----------------------------------------------------------------------------
// alloc_int_a_deref_w2 — combined "size in A → 1-byte ALLOC_SIZE; alloc_int;
// deref RV → W2" tail helper. Replaces the 12-byte sequence
//     sta ALLOC_SIZE
//     lda #0
//     sta ALLOC_SIZE+1
//     jsr alloc_int
//     jsr deref_RV_to_W2
// at every builtin that allocates a small TYPE_INT and writes its payload via
// W2 (builtin_ord, type, int-from-bool, hex, etc.).
//   in:  A = payload size in bytes (1..255)
//   out: RV = new TYPE_INT handle; W2 = payload pointer; A = length low byte.
//   clobbers: A, X, Y. Allocates → may GC; W0/W1/W3/B regs preserved by V4'.
// -----------------------------------------------------------------------------
alloc_int_a_deref_w2:
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int
    jmp deref_RV_to_W2

// -----------------------------------------------------------------------------
// heap_carve_payload — bump NEXT_DATA by ALLOC_SIZE + O_HEADER without carving
// a handle. Used by list growth to acquire a fresh payload area and rewire an
// existing handle to point at it. The old payload bytes become orphaned and
// are squeezed out by the next gc_compact.
//
//   in:  ALLOC_SIZE (word) preset by caller
//   out: RV = new object base address (where O_LEN is written; payload starts
//        at RV + O_HEADER). On OOM: gc_collect retry once, then panic.
//
// Side effects:
//   - Writes O_LEN = ALLOC_SIZE at the new object base (caller may overwrite).
//   - Bumps NEXT_DATA by ALLOC_SIZE + O_HEADER.
//   - Does NOT touch the reserved or free handle lists.
//
// Note: callers that root a handle that points at the current heap data must
// re-read its H_PTR after this call — gc_collect during the retry path may
// have moved live payloads via compact.
// -----------------------------------------------------------------------------
heap_carve_payload:
    preamble_args(0, 0)
    lda #0
    sta ALLOC_GC_TRIED

hcp_check:
    // need = ALLOC_SIZE + O_HEADER (16-bit)
    clc
    lda ALLOC_SIZE
    adc #O_HEADER
    sta W1
    lda ALLOC_SIZE+1
    adc #0
    sta W1+1
    bcs hcp_oom

    // gap = NEXT_HANDLE - NEXT_DATA
    sec
    lda NEXT_HANDLE
    sbc NEXT_DATA
    sta W0
    lda NEXT_HANDLE+1
    sbc NEXT_DATA+1
    sta W0+1

    // OOM if gap < need
    sec
    lda W0
    sbc W1
    lda W0+1
    sbc W1+1
    bcs hcp_ok

hcp_oom:
    lda ALLOC_GC_TRIED
    bne hcp_really_oom
    inc ALLOC_GC_TRIED
    jsr gc_collect
    jmp hcp_check
hcp_really_oom:
    jmp panic_oom

hcp_ok:
    // RV = NEXT_DATA (object header address).
    lda NEXT_DATA
    sta RV
    lda NEXT_DATA+1
    sta RV+1

    // Write O_LEN = ALLOC_SIZE at NEXT_DATA. Caller usually overwrites.
    ldy #O_LEN
    lda ALLOC_SIZE
    sta (NEXT_DATA),y
    iny
    lda ALLOC_SIZE+1
    sta (NEXT_DATA),y

    // Bump NEXT_DATA by ALLOC_SIZE + O_HEADER (16-bit).
    clc
    lda NEXT_DATA
    adc ALLOC_SIZE
    sta NEXT_DATA
    lda NEXT_DATA+1
    adc ALLOC_SIZE+1
    sta NEXT_DATA+1
    clc
    lda NEXT_DATA
    adc #O_HEADER
    sta NEXT_DATA
    bcc !+
    inc NEXT_DATA+1
!:
    jmp postamble

// -----------------------------------------------------------------------------
// _relink_to_tail — move handle at W0 to the tail of RESERVED.
//
// Used by `_array_grow` after `heap_carve_payload` reassigns a handle's
// H_PTR to a higher address: gc_compact walks RESERVED in list order and
// relies on H_PTR being ascending. heap_carve_payload always carves at
// NEXT_DATA (the highest address), so the regrown handle belongs at the
// tail to keep the invariant intact.
//
// Without this relink, compact would copy a handle's payload over data
// belonging to handles that haven't been processed yet — silently corrupting
// the heap.
//
// Leaf-helper contract:
//   in:  W0 = handle to relink. Must already be on RESERVED.
//   out: handle is at RESERVED_TAIL; HEAD/TAIL/H_NEXT links updated.
//   clobbers: A, Y, W2, W3 (W0 / W1 preserved)
// -----------------------------------------------------------------------------
_relink_to_tail:
    // Already tail? No-op.
    lda W0
    cmp RESERVED_TAIL
    bne _rtt_unlink
    lda W0+1
    cmp RESERVED_TAIL+1
    beq _rtt_done

_rtt_unlink:
    // Is W0 the HEAD?
    lda W0
    cmp RESERVED_HEAD
    bne _rtt_walk_setup
    lda W0+1
    cmp RESERVED_HEAD+1
    bne _rtt_walk_setup

    // HEAD: RESERVED_HEAD = W0.H_NEXT
    ldy #H_NEXT
    lda (W0),y
    sta RESERVED_HEAD
    iny
    lda (W0),y
    sta RESERVED_HEAD+1
    jmp _rtt_append

_rtt_walk_setup:
    lda RESERVED_HEAD
    sta W2
    lda RESERVED_HEAD+1
    sta W2+1

_rtt_walk:
    // W3 = W2.H_NEXT
    ldy #H_NEXT
    lda (W2),y
    sta W3
    iny
    lda (W2),y
    sta W3+1

    // W3 == W0? Found predecessor.
    lda W3
    cmp W0
    bne _rtt_advance
    lda W3+1
    cmp W0+1
    bne _rtt_advance

    // Unlink: W2.H_NEXT = W0.H_NEXT
    ldy #H_NEXT
    lda (W0),y
    sta (W2),y
    iny
    lda (W0),y
    sta (W2),y
    jmp _rtt_append

_rtt_advance:
    lda W3
    sta W2
    lda W3+1
    sta W2+1
    jmp _rtt_walk

_rtt_append:
    // RESERVED_TAIL.H_NEXT = W0
    lda RESERVED_TAIL
    sta W2
    lda RESERVED_TAIL+1
    sta W2+1
    ldy #H_NEXT
    lda W0
    sta (W2),y
    iny
    lda W0+1
    sta (W2),y

    // W0.H_NEXT = 0
    lda #0
    ldy #H_NEXT
    sta (W0),y
    iny
    sta (W0),y

    // RESERVED_TAIL = W0
    lda W0
    sta RESERVED_TAIL
    lda W0+1
    sta RESERVED_TAIL+1

_rtt_done:
    rts
