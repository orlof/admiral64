// -----------------------------------------------------------------------------
// Software stacks: frame stack (FS) and root stack (RS).
//
// Both stacks:
//   - Grow DOWN (high → low addresses).
//   - Pointer = top of stack (the most recently pushed word).
//   - Empty: pointer = region-end (one past the highest usable byte).
//   - 16-bit ZP pointer (FSP / RSP), accessed via (zp),y.
//
// Frame stack (FS):
//   - Holds per-routine preamble frames (saved regs, target pointers, saved
//     caller's FP), any caller-pushed non-handle args above those frames, and
//     any body-level fs_push scratch below.
//   - FSP moves on every fs_push/fs_pop.
//   - FP is distinct from FSP — it's the STABLE base of the current routine's
//     frame, set once by preamble and not moved during the body. Bodies access
//     saved regs via (FP, 0..15) and non-handle args via (FP, 22..).
//   - Not GC-visible.
//
// Root stack (RS): live handle pointers only — linearly scanned by GC.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"

// --- Stack regions (fixed layout) --------------------------------------------
// Both stacks sit at the low end of the BASIC-ROM-freed area ($8000-$BFFF).
// Heap begins at HEAP_DATA_START = $8800 (defs.asm), directly above RS.
// FS is 1 KB (~45 nested 22-byte frames, plus body pushes and caller args).
// RS is 1 KB (512 handle slots — each is a 16-bit handle pointer).
.const FS_BEGIN = $8000     // frame stack low bound (inclusive)
.const FS_END   = $8400     // frame stack high bound (exclusive; = empty FSP)
.const RS_BEGIN = $8400     // root stack low bound
.const RS_END   = $8800     // root stack high bound (1 KB / 512 handle slots)

// FSP, RSP, and FP are declared in defs.asm as ZP pointers.

// -----------------------------------------------------------------------------
// fs_init — reset FSP and FP to empty (both = FS_END).
// -----------------------------------------------------------------------------
fs_init:
    lda #<FS_END
    sta FSP
    sta FP
    lda #>FS_END
    sta FSP+1
    sta FP+1
    rts

// -----------------------------------------------------------------------------
// rs_init — reset RSP to empty (RSP = RS_END).
// -----------------------------------------------------------------------------
rs_init:
    lda #<RS_END
    sta RSP
    lda #>RS_END
    sta RSP+1
    rts

// -----------------------------------------------------------------------------
// Root-stack macros — inline expansion for push/pop/peek. `src`/`dst` is a ZP
// word address (e.g. W0, RV).
// -----------------------------------------------------------------------------

// rs_push: dispatch to a shared subroutine for the common ZP-word sources
// (W0, W1, W2, W3, RV). Each call site shrinks from ~17 bytes inline to 3
// bytes (`jsr rs_push_xxx`). Unusual sources (absolute addresses like
// GLOBAL_SCOPE) fall through to inline expansion.
.macro rs_push(src) {
    .if (src == W0)      { jsr rs_push_w0 }
    else .if (src == W1) { jsr rs_push_w1 }
    else .if (src == W2) { jsr rs_push_w2 }
    else .if (src == W3) { jsr rs_push_w3 }
    else .if (src == RV) { jsr rs_push_rv }
    else {
        sec
        lda RSP
        sbc #2
        sta RSP
        bcs !+
        dec RSP+1
    !:
        ldy #0
        lda src
        sta (RSP),y
        iny
        lda src+1
        sta (RSP),y
    }
}

// rs_pop: dispatch to a per-target subroutine; same pattern as rs_push.
.macro rs_pop(dst) {
    .if (dst == W0)      { jsr rs_pop_w0 }
    else .if (dst == W1) { jsr rs_pop_w1 }
    else .if (dst == W2) { jsr rs_pop_w2 }
    else .if (dst == W3) { jsr rs_pop_w3 }
    else .if (dst == RV) { jsr rs_pop_rv }
    else {
        ldy #0
        lda (RSP),y
        sta dst
        iny
        lda (RSP),y
        sta dst+1
        clc
        lda RSP
        adc #2
        sta RSP
        bcc !+
        inc RSP+1
    !:
    }
}

// Read top (or offset-from-top) of RS into `dst` without modifying RSP.
// offset=0 is top; offset=1 is one word below top, etc.
.macro rs_peek(dst) {
    .if (dst == W0)      { jsr rs_peek_w0 }
    else .if (dst == W1) { jsr rs_peek_w1 }
    else .if (dst == W2) { jsr rs_peek_w2 }
    else .if (dst == W3) { jsr rs_peek_w3 }
    else .if (dst == RV) { jsr rs_peek_rv }
    else {
        ldy #0
        lda (RSP),y
        sta dst
        iny
        lda (RSP),y
        sta dst+1
    }
}

.macro rs_peek_at(dst, offset) {
    ldy #offset*2
    .if (dst == W0)      { jsr rs_peek_at_w0 }
    else .if (dst == W1) { jsr rs_peek_at_w1 }
    else {
        lda (RSP),y
        sta dst
        iny
        lda (RSP),y
        sta dst+1
    }
}

// Drop N words from RS without reading them.
.macro rs_drop(n) {
    clc
    lda RSP
    adc #n*2
    sta RSP
    bcc !+
    inc RSP+1
!:
}

// Push a 16-bit immediate (e.g. a static-handle label) onto RS. Compiles to
// LDA #<addr / LDX #>addr / JSR rs_push_const_ax — 7 bytes per site, vs the
// 22-byte inline version. Useful for static constants like INT_10 where we
// don't want to burn a ZP slot staging the address first.
.macro rs_push_const(addr) {
    lda #<addr
    ldx #>addr
    jsr rs_push_const_ax
}

// -----------------------------------------------------------------------------
// Frame-stack macros — push/pop/peek via FSP (not FP).
// -----------------------------------------------------------------------------

.macro fs_push(src) {
    .if (src == W0)      { jsr fs_push_w0 }
    else .if (src == W2) { jsr fs_push_w2 }
    else .if (src == W3) { jsr fs_push_w3 }
    else {
        sec
        lda FSP
        sbc #2
        sta FSP
        bcs !+
        dec FSP+1
    !:
        ldy #0
        lda src
        sta (FSP),y
        iny
        lda src+1
        sta (FSP),y
    }
}

.macro fs_pop(dst) {
    ldy #0
    lda (FSP),y
    sta dst
    iny
    lda (FSP),y
    sta dst+1
    clc
    lda FSP
    adc #2
    sta FSP
    bcc !+
    inc FSP+1
!:
}

// Read non-handle arg from the caller's FS slot. Caller-pushed args live
// immediately above this routine's 22-byte frame, starting at offset 22.
// depth=0 is the topmost (most recently pushed) arg.
.macro fs_peek_arg(dst, depth) {
    ldy #22 + depth*2
    lda (FP),y
    sta dst
    iny
    lda (FP),y
    sta dst+1
}

// -----------------------------------------------------------------------------
// Byte-oriented FS operations. Unlike fs_push / fs_pop (which move words),
// these move a single byte per call — useful when you need to buffer scratch
// bytes (e.g. the digit reversal buffer in int_to_str).
//
// Interleaving a run of fs_push_byte with normal V4' sub-calls is safe:
// sub-routines' preamble frames are carved BELOW the current FSP, and their
// postamble restores FSP exactly. Byte data above that point is preserved.
//
// Contract:
//   fs_push_byte — in A = byte; out nothing. Clobbers Y.
//   fs_pop_byte  — in nothing; out A = popped byte. Clobbers Y.
// -----------------------------------------------------------------------------

.macro fs_push_byte() {
    pha                      // save byte while we decrement FSP
    lda FSP
    bne !+
    dec FSP+1
!:
    dec FSP
    pla
    ldy #0
    sta (FSP),y
}

.macro fs_pop_byte() {
    ldy #0
    lda (FSP),y              // A = popped byte
    inc FSP
    bne !+
    inc FSP+1
!:
}

// -----------------------------------------------------------------------------
// Callable wrappers — used both by the Python test harness and by the
// `rs_push` macro itself, which compiles `rs_push(W0)` etc. into a 3-byte
// JSR to one of these. Each body is the inline rs_push expansion + RTS;
// they MUST stay byte-for-byte equivalent to the macro's else-branch fallback.
// -----------------------------------------------------------------------------
rs_push_w0:
    sec
    lda RSP
    sbc #2
    sta RSP
    bcs !+
    dec RSP+1
!:
    ldy #0
    lda W0
    sta (RSP),y
    iny
    lda W0+1
    sta (RSP),y
    rts

rs_push_w1:
    sec
    lda RSP
    sbc #2
    sta RSP
    bcs !+
    dec RSP+1
!:
    ldy #0
    lda W1
    sta (RSP),y
    iny
    lda W1+1
    sta (RSP),y
    rts

rs_push_w2:
    sec
    lda RSP
    sbc #2
    sta RSP
    bcs !+
    dec RSP+1
!:
    ldy #0
    lda W2
    sta (RSP),y
    iny
    lda W2+1
    sta (RSP),y
    rts

rs_push_w3:
    sec
    lda RSP
    sbc #2
    sta RSP
    bcs !+
    dec RSP+1
!:
    ldy #0
    lda W3
    sta (RSP),y
    iny
    lda W3+1
    sta (RSP),y
    rts

rs_push_rv:
    sec
    lda RSP
    sbc #2
    sta RSP
    bcs !+
    dec RSP+1
!:
    ldy #0
    lda RV
    sta (RSP),y
    iny
    lda RV+1
    sta (RSP),y
    rts

// -----------------------------------------------------------------------------
// fs_push_{w0,w2,w3} — JSR-callable wrappers behind the fs_push(src) macro.
// W0/W3 entries load A/X and tail-jump into the W2 fall-through, so all
// three share one copy of the FSP-decrement and the (FSP)-write.
// -----------------------------------------------------------------------------
fs_push_w0:
    lda W0
    ldx W0+1
    jmp _fs_push_ax
fs_push_w3:
    lda W3
    ldx W3+1
    jmp _fs_push_ax
fs_push_w2:
    lda W2
    ldx W2+1
_fs_push_ax:                  // in: A = lo, X = hi
    pha
    sec
    lda FSP
    sbc #2
    sta FSP
    bcs !+
    dec FSP+1
!:
    txa
    ldy #1
    sta (FSP),y
    pla
    dey
    sta (FSP),y
    rts

// rs_pop_{w0..w3,rv} — peek into target, then bump RSP by 2 via the shared
// _rs_inc_rsp tail. rs_peek_* preserves X, _rs_inc_rsp preserves X, so the
// macro contract (clobbers A/Y, preserves X) is intact.
rs_pop_w0:
    jsr rs_peek_w0
    jmp _rs_inc_rsp
rs_pop_w1:
    jsr rs_peek_w1
    jmp _rs_inc_rsp
rs_pop_w2:
    jsr rs_peek_w2
    jmp _rs_inc_rsp
rs_pop_w3:
    jsr rs_peek_w3
    jmp _rs_inc_rsp
rs_pop_rv:
    jsr rs_peek_rv
_rs_inc_rsp:
    clc
    lda RSP
    adc #2
    sta RSP
    bcc !+
    inc RSP+1
!:
    rts

rs_peek_w0:
    ldy #0
    lda (RSP),y
    sta W0
    iny
    lda (RSP),y
    sta W0+1
    rts

rs_peek_w1:
    ldy #0
    lda (RSP),y
    sta W1
    iny
    lda (RSP),y
    sta W1+1
    rts

rs_peek_w2:
    ldy #0
    lda (RSP),y
    sta W2
    iny
    lda (RSP),y
    sta W2+1
    rts

rs_peek_w3:
    ldy #0
    lda (RSP),y
    sta W3
    iny
    lda (RSP),y
    sta W3+1
    rts

rs_peek_rv:
    ldy #0
    lda (RSP),y
    sta RV
    iny
    lda (RSP),y
    sta RV+1
    rts

// rs_peek_at_xx — caller has loaded Y = offset*2 (typically the macro
// stages it). Reads the word at (RSP + Y) into the named ZP target.
rs_peek_at_w0:
    lda (RSP),y
    sta W0
    iny
    lda (RSP),y
    sta W0+1
    rts

rs_peek_at_w1:
    lda (RSP),y
    sta W1
    iny
    lda (RSP),y
    sta W1+1
    rts

// arg_get_xx — caller has staged Y = i*2; reads (W3,Y) into target ZP word.
arg_get_w0:
    lda (W3),y
    sta W0
    iny
    lda (W3),y
    sta W0+1
    rts

arg_get_w1:
    lda (W3),y
    sta W1
    iny
    lda (W3),y
    sta W1+1
    rts

arg_get_w2:
    lda (W3),y
    sta W2
    iny
    lda (W3),y
    sta W2+1
    rts

arg_get_rv:
    lda (W3),y
    sta RV
    iny
    lda (W3),y
    sta RV+1
    rts

// rs_push_const_ax — caller passes the constant in A=lo, X=hi.
rs_push_const_ax:
    pha
    sec
    lda RSP
    sbc #2
    sta RSP
    bcs !+
    dec RSP+1
!:
    ldy #0
    pla
    sta (RSP),y
    iny
    txa
    sta (RSP),y
    rts
