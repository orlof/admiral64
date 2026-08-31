// -----------------------------------------------------------------------------
// plugin_rt.asm — kernel-side runtime for disk-loaded TYPE_CODE plugins.
//
// v2 plugin payload layout (produced by tools/build_plugin.py):
//   +0  jsr SYS_RELOC        3 bytes — MUST be the first instruction. Also
//                            serves as the v2-ABI signature the dispatcher
//                            checks (see parser.asm _llp_code_call).
//   +3  .word linked_base    the base address the payload's absolute refs
//                            currently point at; rewritten by sys_reloc.
//   +5  .word fixups_off     payload-relative offset of the fixup table
//                            (a constant: `fixup_table - plugin_base`).
//   +7  entry                the plugin code starts here, always.
//   ...
//   fixup table (at base+fixups_off, appended by the build tool):
//        .word nfix, then nfix words, each the payload-relative offset of a
//        16-bit absolute address word to shift by (base - linked_base).
//
// sys_reloc contract:
//   in:  W0 = payload base (set by _llp_code_call before the JSR into the
//        payload; the payload's own `jsr SYS_RELOC` doesn't disturb it).
//   out: jumps to base+7 (the entry point); never returns to base+3.
//   clobbers: A, X, Y, RV, RV2, B4, B5, B7. PRESERVES W0-W3, B0-B3 (arg
//   slots) and B6 (the dispatcher passes the v2 arg count in B6).
//
// GC interplay: the dispatcher pins the code handle (FLAG_PINNED) around
// the whole call, so the payload cannot move while sys_reloc or the plugin
// runs. Between calls it may move freely — that is exactly why linked_base
// is re-checked on every call.
// -----------------------------------------------------------------------------
#importonce
#import "defs.asm"
#import "sys.inc"

sys_reloc:
    pla                             // discard return address (base+2):
    pla                             // we jump straight to the entry point.

    // RV = delta = base - linked_base
    ldy #3
    sec
    lda W0
    sbc (W0),y
    sta RV
    iny
    lda W0+1
    sbc (W0),y
    sta RV+1

    lda RV
    ora RV+1
    beq _sr_entry                   // already linked here → run

    // linked_base = base
    ldy #3
    lda W0
    sta (W0),y
    iny
    lda W0+1
    sta (W0),y

    // B4:B5 = fixup-table walker = base + fixups_off
    ldy #5
    clc
    lda (W0),y
    adc W0
    sta B4
    iny
    lda (W0),y
    adc W0+1
    sta B5

    // X:B7 = nfix (lo:hi); advance walker past the count word
    ldy #0
    lda (B4),y
    tax
    iny
    lda (B4),y
    sta B7
    clc
    lda B4
    adc #2
    sta B4
    bcc _sr_loop
    inc B5

_sr_loop:
    txa
    ora B7
    beq _sr_entry

    // RV2 = base + fixup offset  (absolute address of the word to patch)
    ldy #0
    clc
    lda (B4),y
    adc W0
    sta RV2
    iny
    lda (B4),y
    adc W0+1
    sta RV2+1

    // word at (RV2) += delta
    ldy #0
    clc
    lda (RV2),y
    adc RV
    sta (RV2),y
    iny
    lda (RV2),y
    adc RV+1
    sta (RV2),y

    // walker += 2, nfix -= 1
    clc
    lda B4
    adc #2
    sta B4
    bcc !+
    inc B5
!:
    cpx #0
    bne !+
    dec B7
!:
    dex
    jmp _sr_loop

_sr_entry:
    // RV2 = base + 7, then jmp (RV2)
    clc
    lda W0
    adc #7
    sta RV2
    lda W0+1
    adc #0
    sta RV2+1
    jmp (RV2)

// Reserved-slot target: a plugin built against a newer sys.inc jumped into
// a slot this kernel doesn't implement yet.
sys_unimpl:
    jmp panic_type
