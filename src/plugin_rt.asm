// -----------------------------------------------------------------------------
// plugin_rt.asm — kernel-side runtime for disk-loaded TYPE_CODE plugins.
//
// v2 plugin payload layout (produced by tools/build_plugin.py):
//   +0  jsr SYS_RELOC        3 bytes — MUST be the first instruction. Also
//                            serves as the v2-ABI signature the dispatcher
//                            checks (see parser.asm _llp_code_call).
//   +3  .word linked_base    the base address the payload's absolute refs
//                            currently point at; rewritten by sys_reloc.
//   +5  .word nfix           number of fixups.
//   +7  fixups               nfix words, each the payload-relative offset of
//                            a 16-bit absolute address to shift by delta.
//   +7+2*nfix                the real entry point (plugin code).
//
// sys_reloc contract:
//   in:  W0 = payload base (set by _llp_code_call before the JSR into the
//        payload; the payload's own `jsr SYS_RELOC` doesn't disturb it).
//   out: jumps to the payload entry point; never returns to base+3.
//   clobbers: A, X, Y, RV, RV2, B4-B7. PRESERVES W0-W3, B0-B3 (arg slots).
//
// GC interplay: the dispatcher pins the code handle (FLAG_PINNED) around
// the whole call, so the payload cannot move while sys_reloc or the plugin
// runs. Between calls it may move freely — that's exactly why linked_base
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

    // B4:B5 = nfix, B6:B7 = fixup walker (= base + 7)
    ldy #5
    lda (W0),y
    sta B4
    iny
    lda (W0),y
    sta B5

    clc
    lda W0
    adc #7
    sta B6
    lda W0+1
    adc #0
    sta B7

_sr_loop:
    lda B4
    ora B5
    beq _sr_entry

    // RV2 = base + fixup offset  (absolute address of the word to patch)
    ldy #0
    clc
    lda (B6),y
    adc W0
    sta RV2
    iny
    lda (B6),y
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
    lda B6
    adc #2
    sta B6
    bcc !+
    inc B7
!:
    lda B4
    bne !+
    dec B5
!:
    dec B4
    jmp _sr_loop

_sr_entry:
    // B6:B7 = entry = base + 7 + 2*nfix, then jmp (B6)
    ldy #5
    lda (W0),y
    asl
    sta B6
    iny
    lda (W0),y
    rol
    sta B7
    clc
    lda B6
    adc #7
    sta B6
    bcc !+
    inc B7
!:
    clc
    lda B6
    adc W0
    sta B6
    lda B7
    adc W0+1
    sta B7
    jmp (B6)

// Reserved-slot target: a plugin built against a newer sys.inc jumped into
// a slot this kernel doesn't implement yet.
sys_unimpl:
    jmp panic_type
