// -----------------------------------------------------------------------------
// plugins/sort.asm — SORT as a disk-loaded v2 TYPE_CODE plugin.
//
// Usage from Admiral:   SORT = LOAD("SORT")
//                       SORT(lst)            in-place, returns the list
//                       SORT(str)            returns a sorted copy
//                       SORT(tup)            returns a sorted copy
//                       SORT(x, TRUE)        descending
//
// Called via the v2 CODE ABI (parser.asm _llp_code_call):
//   in:  W1 = arg1 handle, W2 = arg2 handle (if any), B6 = arg count.
//        The code handle is FLAG_PINNED for the duration of the call and
//        every arg sits rooted on RS, so allocs (array_repeat) are safe.
//   out: carry set, W0 = result handle.
//
// PLUGIN RULES (relocated at call time by SYS_RELOC — see plugin_rt.asm):
//   - kernel calls ONLY through sys.inc SYS_* slots; kernel statics ONLY
//     through the SYSD_* directory
//   - no `#<label` / `#>label` immediates of internal labels (the build
//     tool relocates 16-bit words only, and verifies this)
// -----------------------------------------------------------------------------
#import "defs.asm"
#import "sys.inc"

.var pbase = $1000
.if (cmdLineVars.containsKey("base")) .eval pbase = cmdLineVars.get("base").asNumber()

* = pbase "Plugin"

plugin_base:
    jsr SYS_RELOC
    .word plugin_base                 // +3 linked_base (rewritten on move)
    .word fixup_table - plugin_base   // +5 fixup-table offset (relative: PIC)

// --- entry (= base+7) --------------------------------------------------------
entry:
    lda B6                            // arity 1..2
    beq _arity_err
    cmp #3
    bcc _arity_ok
_arity_err:
    jmp SYS_PANIC_ARITY
_arity_ok:

    // Stage ASC SMC opcodes; swap to DESC when arg2 is truthy.
    ldx #$B0                          // BCS (asc)
    ldy #1                            // cmp #1 (asc)
    lda B6
    cmp #2
    bne _apply
    lda W2
    sta W0
    lda W2+1
    sta W0+1
    jsr SYS_VAL_TRUTHY                // A = 0/1; preserves X/Y (leaf)
    beq _apply
    ldx #$90                          // BCC (desc)
    ldy #$FF                          // cmp #$FF (desc)
_apply:
    stx _bsb_branch
    sty _bsh_cmp_imm

    lda W1                            // W0 = arg1 handle
    sta W0
    lda W1+1
    sta W0+1
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_STR
    beq _sort_str
    cmp #TYPE_TUPLE
    beq _sort_tuple
    cmp #TYPE_LIST
    beq _sort_list
    jmp SYS_PANIC_TYPE

_sort_str:
    // Clone via array_repeat(str, 1), sort the clone's bytes, return it.
    jsr _push_arg1_and_one
    jsr SYS_ARRAY_REPEAT              // RV = clone (TYPE_STR)
    jsr SYS_RS_PUSH_RV                // root the clone across nothing-in-
                                      // particular; balanced by the pop below
    jsr SYS_RS_PEEK_W0
    jsr SYS_DEREF_W0_TO_W2            // W2 = clone payload, A = len
    sta B0
    jsr _w2_to_w3
    jsr _bsort_bytes
    jmp _pop_ret

_sort_tuple:
    jsr _push_arg1_and_one
    jsr SYS_ARRAY_REPEAT              // RV = clone (TYPE_TUPLE preserved)
    jsr SYS_RS_PUSH_RV
    jsr SYS_RS_PEEK_W0
    jsr SYS_DEREF_W0_TO_W2            // W2 = clone payload, A = element count
    sta B0
    jsr _w2_to_w3
    jsr _bsort_handles
    jmp _pop_ret

_sort_list:
    // In place; returns the same handle. _bsort_handles clobbers W1, so
    // park the handle on RS and let _pop_ret recover it.
    jsr SYS_RS_PUSH_W0
    jsr SYS_DEREF_W0_TO_W2            // W2 = payload, A = element count
    sta B0
    jsr _w2_to_w3
    jsr _bsort_handles
    jmp _pop_ret

// --- shared tails / helpers --------------------------------------------------

// Push args[0] handle and the static INT_1 onto RS (array_repeat's inputs).
_push_arg1_and_one:
    lda W1
    sta W0
    lda W1+1
    sta W0+1
    jsr SYS_RS_PUSH_W0
    lda SYSD_INT1
    ldx SYSD_INT1+1
    jmp SYS_RS_PUSH_CONST_AX

_w2_to_w3:
    lda W2
    sta W3
    lda W2+1
    sta W3+1
    rts

_pop_ret:
    jsr SYS_RS_POP_RV                 // RV = clone (pops our root)
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    sec                               // carry set → W0 is a handle
    rts

// --- insertion sort over bytes at (W3),y for y in 0..B0-1 --------------------
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
    sta B4
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

// --- insertion sort over handles at (W3),y (2 bytes/slot) --------------------
// Comparator: val_cmp (V4': preserves W0..W3, B0..B7).
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

    ldy B2
    dey
    tya
    asl
    tay                               // Y = 2*(j-1)
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

    jsr SYS_RS_PUSH_W0
    jsr SYS_RS_PUSH_W1
    jsr SYS_VAL_CMP                   // A = -1/0/+1
.label _bsh_cmp_imm = * + 1
    cmp #1                            // SMC: #1 (asc) / #$FF (desc)
    bne _bsh_on

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

fixup_table:                          // build_plugin.py appends [nfix][offsets]
