// -----------------------------------------------------------------------------
// Admiral — top-level assembler entry point.
//
// Produces admiral.prg. Tests load it into py65 and invoke routines directly
// by their labels. On real hardware, `boot` is the SYS-able entry: it switches
// BASIC ROM off (keeping KERNAL + I/O mapped), then runs the three inits.
// -----------------------------------------------------------------------------

#import "defs.asm"

* = $0801 "Code"

// BASIC upstart stub: 10 SYS2061  → SYS $080D → label `boot`.
// Layout: [link $080B][line 10][SYS $9E]["2061"][eol $00][eop $00 $00].
.byte $0B, $08, $0A, $00, $9E, $32, $30, $36, $31, $00, $00, $00

// cold — the SYS / RESET entry. Defaults the heap config to text (full heap),
// then falls into boot. REBOOT(bool) sets GFX_CONFIG itself and JMPs to `boot`
// directly, preserving the chosen config across the warm restart.
cold:
    lda #0
    sta GFX_CONFIG

boot:
    // REBOOT reaches `boot` via JMP from deep in a builtin call chain, so the
    // HW stack would leak across reboots — reset it. Harmless on the cold path
    // (we never RTS back to BASIC; boot ends in `jmp repl_main`).
    ldx #$FF
    txs

    // Phase 1 banking: bank BASIC + KERNAL out, keep I/O. KERNAL ROM is no
    // longer mapped at $E000-$FFFF; the CPU's IRQ/NMI vectors at $FFFA-$FFFF
    // now read RAM. We must populate them before flipping $01, otherwise the
    // first IRQ jumps into uninitialized RAM.
    //
    // SEI guards the install window so a CIA1 timer-A IRQ (KERNAL has it
    // armed at boot) can't fire mid-edit. Writes to $FFFA-$FFFF go to
    // underlying RAM regardless of HIRAM (only reads are gated), so the STAs
    // below work even with KERNAL still mapped for reads.
    sei

    // IRQ dispatch — two paths, same as NMI:
    //
    //   $01=MEM_NORMAL/IO ($34/$35) → CPU reads RAM at $FFFE → irq_handler.
    //   $01=MEM_KERNAL/FP  ($36/$37) → CPU reads KERNAL ROM $FFFE = $FF48.
    //                       KERNAL pushes A/X/Y, then JMP ($0314) → our stub.
    //
    // The stub pops KERNAL's A/X/Y, then falls through to irq_handler so the
    // unified body sees identical state regardless of path. Without the
    // $0314 hook, IRQs that fire during a $36/$37 window land in KERNAL's
    // $EA31 — that runs the cursor flash + jiffy clock + SCNKEY but doesn't
    // touch our STOP_REQUESTED, so RUN/STOP detection misses ticks.
    lda #<irq_handler
    sta $FFFE
    lda #>irq_handler
    sta $FFFF
    lda #<irq_kernal_stub
    sta $0314
    lda #>irq_kernal_stub
    sta $0315

    // NMI dispatch — two paths because $01 may be MEM_NORMAL or MEM_KERNAL
    // when NMI fires:
    //
    //   $01=MEM_NORMAL → CPU reads RAM at $FFFA → straight to nmi_handler.
    //   $01=MEM_KERNAL → CPU reads KERNAL ROM $FFFA → KERNAL NMI start at
    //                    $FE43: SEI / JMP ($0318) → nmi_handler.
    //
    // KERNAL does NOT push A/X/Y before JMP ($0318) — its default handler at
    // $FE47 saves them itself. Both paths therefore arrive with identical
    // stack state (just [PC_lo, PC_hi, P] from the NMI hardware push), so a
    // single entry point works for both.
    lda #<nmi_handler
    sta $FFFA
    lda #>nmi_handler
    sta $FFFB
    lda #<nmi_handler
    sta $0318
    lda #>nmi_handler
    sta $0319

    // RESET: pointer to `cold`, so a soft-reset re-enters us in text config
    // (a stale graphics config must not survive a reset).
    lda #<cold
    sta $FFFC
    lda #>cold
    sta $FFFD

    // $01 = MEM_NORMAL ($34): BASIC out, KERNAL out, $D000-$DFFF is RAM
    // (HIRAM=0 AND LORAM=0 makes CHAREN moot — full RAM). Steady state.
    // Code that needs I/O temporarily flips to MEM_IO ($35); kbd-getchar
    // and irq_handler use $36 (KERNAL+I/O); FP wrappers use $37 (full ROM).
    lda #MEM_NORMAL
    sta $01

    cli

    jsr rs_init
    jsr fs_init
    jsr _heap_apply              // set HEAP_TOP from GFX_CONFIG (before alloc)
    jsr alloc_init
    jsr rnd_init

    // Screen must init AFTER the software stacks + heap — print_str runs as
    // a V4' routine and expects FS/RS to be live. BASIC is already banked
    // out above, so VIC / color-RAM writes won't get shadowed.
    jsr screen_init

    // Banner line 1: "    **** COMMODORE 64 ADMIRAL ****\n".
    lda #<STR_BANNER
    sta W0
    lda #>STR_BANNER
    sta W0+1
    rs_push(W0)
    jsr println_str

    // Banner line 2: "  64K RAM SYSTEM  " <heap-free> " HEAP BYTES FREE\n".
    // Compute heap-free into B0:B1 BEFORE the alloc_int that follows — the
    // int allocation itself reduces the count by SIZEOF_HANDLE + O_HEADER + 2,
    // and we want the displayed number to reflect the pre-alloc state (the
    // user-relevant ceiling).
    sec
    lda NEXT_HANDLE
    sbc NEXT_DATA
    sta B0
    lda NEXT_HANDLE+1
    sbc NEXT_DATA+1
    sta B1

    lda #<STR_BANNER_2A
    sta W0
    lda #>STR_BANNER_2A
    sta W0+1
    rs_push(W0)
    jsr print_str

    // Inline int holding the 16-bit heap-free count (B0=lo, B1=hi; hi16 = 0).
    lda B0
    sta W2
    lda B1
    sta W2+1
    lda #0
    sta W3
    sta W3+1
    jsr alloc_inline_int
    rs_push(RV)
    jsr print_int

    lda #<STR_BANNER_2B
    sta W0
    lda #>STR_BANNER_2B
    sta W0+1
    rs_push(W0)
    jsr println_str

    // Paint a static cursor below the banner so the system looks alive.
    // (No blink yet — IRQ hook is future work.)
    jsr screen_show_cursor

    // Hand off to the REPL. Never returns under normal operation; in the
    // future an ESC key or `quit` builtin could break out.
    jmp repl_main

// -----------------------------------------------------------------------------
// panic_<code> — load A with the ERR_* code, then fall through to a shared
// `sta ERROR_CODE ; jmp error_handler` tail. Saves 4 bytes per use vs the
// inline 3-instruction panic. The `.byte $2C` between entries is `BIT abs`
// which consumes the next 2 bytes (`lda #N`) as a harmless absolute-address
// read, leaving A untouched and threading control through to the tail.
// -----------------------------------------------------------------------------
panic_break:
    lda #ERR_BREAK
    .byte $2C
panic_arity:
    lda #ERR_ARITY
    .byte $2C
panic_disk:
    lda #ERR_DISK
    .byte $2C
panic_div_zero:
    lda #ERR_DIV_ZERO
    .byte $2C
panic_oom:
    lda #ERR_OOM
    .byte $2C
panic_lex:
    lda #ERR_LEX
    .byte $2C
panic_type:
    lda #ERR_TYPE       // panic-helper terminal entry — fall through
    sta ERROR_CODE
    jmp error_handler

// -----------------------------------------------------------------------------
// error_handler — panic sink. Callers store an ERR_* code in ERROR_CODE then
// JMP here. We recover by:
//   1. Restoring HW SP, FP, RSP, FSP from the snapshot the REPL captured at
//      its first-time setup. This unwinds whatever parser_exec was mid-doing.
//   2. Printing "?ERROR <hex>" so the user can tell what went wrong.
//   3. Jumping to repl_loop, which prints a fresh prompt and waits for input.
// The persistent root scope stays on RS because the saved RSP points just
// past it — vars defined before the panic survive.
//
// If a panic happens BEFORE the REPL has set up its snapshot (e.g., during
// boot-time alloc), repl_rec_s is still 0 and the txs would land us in low
// HW stack. That edge case currently isn't handled; bootloader-time panics
// are rare and would point at a misconfiguration.
// -----------------------------------------------------------------------------
error_handler:
    ldx repl_rec_s
    txs
    lda repl_rec_rsp
    sta RSP
    lda repl_rec_rsp+1
    sta RSP+1
    lda repl_rec_fsp
    sta FSP
    lda repl_rec_fsp+1
    sta FSP+1
    lda repl_rec_fp
    sta FP
    lda repl_rec_fp+1
    sta FP+1

    // Close any disk channels left open by an aborted save/load/dir/format/rm.
    // KERNAL CLOSE on an unopened lfn is a harmless no-op; calling both
    // unconditionally avoids stuck channels across panic recoveries.
    jsr disk_close_data
    jsr disk_close_cmd

    // Restore current scope to root. A panic mid-function-call (TYPE_STR
    // call via _llp_str_call) leaves CURRENT_SCOPE pointing at the leaked
    // function-local dict; without this reset, subsequent REPL turns can't
    // find names defined at top level. Also clear METHOD_RECEIVER in case
    // the panic hit between led_dot setting it and the call consuming it.
    lda ROOT_SCOPE
    sta CURRENT_SCOPE
    lda ROOT_SCOPE+1
    sta CURRENT_SCOPE+1
    lda #0
    sta METHOD_RECEIVER
    sta METHOD_RECEIVER+1

    // Clear the NMI inhibit so the next RESTORE press shows the banner again
    // even if the panic happened mid-save/load (between inc and dec). Also
    // clear NMI_PAUSED in case the panic hit during a banner busy-wait.
    sta PAUSE_BLOCKED
    sta NMI_PAUSED

    // Newline so the message starts on a fresh row regardless of how far
    // the panicking print got.
    lda #$0D
    jsr screen_put_char

    // "?ERROR " literal — six PETSCII bytes inline (no need for a static).
    lda #$3F                          // '?'
    jsr screen_put_char
    lda #$45                          // 'E'
    jsr screen_put_char
    lda #$52                          // 'R'
    jsr screen_put_char
    lda #$52                          // 'R'
    jsr screen_put_char
    lda #$20                          // ' '
    jsr screen_put_char

    // Hex of ERROR_CODE — single byte, two nibbles.
    lda ERROR_CODE
    pha
    lsr
    lsr
    lsr
    lsr
    jsr _err_nibble
    pla
    and #$0F
    jsr _err_nibble

    lda #$0D
    jsr screen_put_char

    // Clear the code so a stray re-entry shows 00 instead of stale state.
    lda #0
    sta ERROR_CODE

    jmp repl_loop

_err_nibble:
    cmp #$0A
    bcc !+
    clc
    adc #$07                          // 'A'-'0'-10 = 7
!:
    clc
    adc #$30                          // '0'
    jmp screen_put_char

// -----------------------------------------------------------------------------
// Heap-config cells + selector. `cold` sets GFX_CONFIG=0 (text); REBOOT(bool)
// sets it from the arg's truthiness. _heap_apply (called by boot before
// alloc_init) reads it and sets HEAP_TOP — the handle-table ceiling alloc_init
// carves down from. These resident RAM cells survive the warm restart; they
// avoid ZP $FB-$FE (used by builtin_call/int_divmod) and the cassette buffer
// (used by the REPL).
// -----------------------------------------------------------------------------
GFX_CONFIG: .byte 0
HEAP_TOP:   .word 0

_heap_apply:
    lda GFX_CONFIG
    beq _ha_text
    lda #<HEAP_HANDLE_START_GFX
    sta HEAP_TOP
    lda #>HEAP_HANDLE_START_GFX
    sta HEAP_TOP+1
    rts
_ha_text:
    lda #<HEAP_HANDLE_START
    sta HEAP_TOP
    lda #>HEAP_HANDLE_START
    sta HEAP_TOP+1
    rts

// -----------------------------------------------------------------------------
// irq_handler — RAM-resident IRQ vector. Two entry paths:
//
//   1. Direct, via $FFFE in RAM ($01 has HIRAM=0): hardware pushes only
//      [PC, P]; A/X/Y still hold pre-IRQ values. Enter at irq_handler and
//      our PHA/TXA/PHA/TYA/PHA saves them.
//
//   2. KERNAL, via $FFFE in ROM ($01 has HIRAM=1) → $FF48 → KERNAL pushes
//      A/X/Y → JMP ($0314) → irq_kernal_stub. The stub pops KERNAL's saves
//      back into the registers (so the values match path 1) and falls
//      through to irq_handler, which then re-saves them. Net stack/reg
//      state is identical for both paths past the fall-through.
//
// Body flips $01 to MEM_KERNAL ($36) so KERNAL ROM is mapped for the SCNKEY
// call (and I/O is on for the direct CIA1 STOP poll + $DC0D ack). We
// deliberately don't tail into KERNAL's full IRQ ($EA31): it ends with JMP
// $EA81 → A/X/Y pull + RTI, which would skip our $01 restore.
// -----------------------------------------------------------------------------
irq_kernal_stub:
    pla
    tay                              // pop KERNAL's Y
    pla
    tax                              // pop KERNAL's X
    pla                              // pop KERNAL's A — fall through with A live
irq_handler:
    pha
    txa
    pha
    tya
    pha
    lda $01
    pha
    lda #MEM_KERNAL                   // KERNAL+I/O for SCNKEY + CIA1 + $DC0D ack
    sta $01

    // Direct STOP-key poll BEFORE SCNKEY (SCNKEY mutates PRA during its scan
    // and KERNAL's $91 pipeline doesn't reliably reflect bare STOP holds in
    // our context). Row 7 / col 7 of the keyboard matrix is RUN/STOP: with
    // PRA = $7F (only row 7 driven low), PRB bit 7 is the STOP key — 0 if
    // pressed. We latch the inverted bit at STOP_REQUESTED so parser_stmt
    // can poll cheaply (a single ZP read) without re-entering CIA1 / KERNAL
    // at every statement boundary.
    lda #$7F
    sta $DC00                         // PRA = select row 7
    lda $DC01                         // PRB pin state
    eor #$FF                          // invert: pressed-bit becomes 1
    and #$80                          // keep only bit 7 → $80 if pressed, 0 if not
    sta STOP_REQUESTED

    jsr KERNAL_SCNKEY                 // populate $0277 buffer for kbd_getchar
    lda $DC0D                         // ack CIA1 timer-A IRQ source
    pla
    sta $01                           // restore prev bank
    pla
    tay
    pla
    tax
    pla
    rti

// -----------------------------------------------------------------------------
// nmi_handler — RESTORE key = pause + status banner. Press RESTORE once to
// freeze execution and overlay a 4-word status line on row 0 (heap-free,
// handle-table-bytes, FS depth, RS depth — each 4 hex chars in inverse video,
// space-separated). Press RESTORE again to dismiss; row is restored from a
// 40-byte scratch and execution resumes.
//
// Both entry paths ($FFFA direct via RAM, $0318 via KERNAL ROM's JMP) arrive
// with identical stack state: only [PC_lo, PC_hi, P] from the NMI hardware
// push. KERNAL's $FE43 entry is just SEI / JMP ($0318) — it does NOT push
// A/X/Y, so we save them ourselves below.
//
// Second-press detection is a software flag, not CIA2: RESTORE on the C64
// is wired directly to /NMI through a 555 monostable, bypassing CIA2 ICR
// entirely — there is no flag bit that latches "RESTORE was pressed". So
// the first invocation sets NMI_PAUSED=1 and busy-waits for it to flip;
// the second invocation re-enters via NMI, sees NMI_PAUSED!=0, clears it
// and RTIs, freeing the first instance's wait loop to restore the screen.
//
// PAUSE_BLOCKED guard: while a disk operation is in flight, $01 may be set
// to MEM_KERNAL by a kjsr_* wrapper. Writing $D800 then hits RAM under the
// bank, not color RAM — banner would be invisible. When PAUSE_BLOCKED != 0
// we silently dismiss after $01 normalisation.
nmi_handler:
    pha
    txa
    pha
    tya
    pha
    lda $01
    pha
    lda #MEM_IO                      // I/O at $D000 — steady-state $34 has no I/O
    sta $01
    // Save W0 — the banner math (NEXT_HANDLE - NEXT_DATA etc.) stashes results
    // there before calling _nmi_word_at_x. The interrupted V4' routine is
    // allowed to hold live state in W0..W3 / B0..B7 (preamble preserves them
    // across calls), so we must not clobber W0 asynchronously.
    lda W0
    pha
    lda W0+1
    pha

    lda NMI_PAUSED
    beq _nmi_first                   // 0 → first press, draw banner & wait
    // Second press while banner showing: clear flag and RTI; the first
    // instance's wait loop will then exit and restore the screen.
    lda #0
    sta NMI_PAUSED
    jmp _nmi_exit

_nmi_first:
    lda PAUSE_BLOCKED
    beq _nmi_run                     // not blocked — show banner
    jmp _nmi_exit                    // disk I/O in flight — silent dismiss
_nmi_run:

    // Save row 0 (40 chars).
    ldy #39
_nmi_save:
    lda $0400,y
    sta NMI_SCRATCH,y
    dey
    bpl _nmi_save

    // Build banner: "nnnn nnnn nnnn nnnn" at cols 0-18, spaces 19-39.
    sec
    lda NEXT_HANDLE
    sbc NEXT_DATA
    sta W0
    lda NEXT_HANDLE+1
    sbc NEXT_DATA+1
    sta W0+1
    ldx #0
    jsr _nmi_word_at_x
    lda #$20
    sta $0400+4

    sec
    lda HEAP_TOP                       // dynamic ceiling (config-dependent)
    sbc NEXT_HANDLE
    sta W0
    lda HEAP_TOP+1
    sbc NEXT_HANDLE+1
    sta W0+1
    ldx #5
    jsr _nmi_word_at_x
    lda #$20
    sta $0400+9

    // FS_END = $8400, RS_END = $8800 (literals — defined in stacks.asm but
    // .const forward refs from admiral.asm can't resolve at this point in the
    // single-segment build; the real defs live there for everyone else).
    sec
    lda #$00
    sbc FSP
    sta W0
    lda #$84
    sbc FSP+1
    sta W0+1
    ldx #10
    jsr _nmi_word_at_x
    lda #$20
    sta $0400+14

    sec
    lda #$00
    sbc RSP
    sta W0
    lda #$88
    sbc RSP+1
    sta W0+1
    ldx #15
    jsr _nmi_word_at_x

    // Pad cols 19..39 with spaces.
    ldy #19
    lda #$20
_nmi_pad:
    sta $0400,y
    iny
    cpy #40
    bne _nmi_pad

    // Inverse-video colour overlay on row 0 (red, COLOR_RED=2).
    lda #2
    ldy #39
_nmi_red:
    sta $D800,y
    dey
    bpl _nmi_red

    // Mark paused, then busy-wait for second RESTORE press. The second NMI
    // re-enters this handler, clears NMI_PAUSED, and RTIs back here.
    lda #1
    sta NMI_PAUSED
_nmi_wait:
    lda NMI_PAUSED
    bne _nmi_wait

    // Restore row 0 chars and default colour.
    ldy #39
_nmi_restore:
    lda NMI_SCRATCH,y
    sta $0400,y
    dey
    bpl _nmi_restore

    lda #COLOR_FG
    ldy #39
_nmi_uncolor:
    sta $D800,y
    dey
    bpl _nmi_uncolor

_nmi_exit:
    pla
    sta W0+1
    pla
    sta W0
    pla
    sta $01
    pla
    tay
    pla
    tax
    pla
    rti

// Helper: write 4 hex screen-codes from W0 starting at column X on row 0.
_nmi_word_at_x:
    lda W0+1
    pha
    lsr
    lsr
    lsr
    lsr
    jsr _nmi_nib
    sta $0400,x
    inx
    pla
    and #$0F
    jsr _nmi_nib
    sta $0400,x
    inx
    lda W0
    pha
    lsr
    lsr
    lsr
    lsr
    jsr _nmi_nib
    sta $0400,x
    inx
    pla
    and #$0F
    jsr _nmi_nib
    sta $0400,x
    rts

// Convert nibble 0..15 in A to screen code in upper-case charset.
//   0..9  → $30..$39 (digits)
//   A..F  → $01..$06 (uppercase letters)
_nmi_nib:
    cmp #10
    bcc !+
    sbc #9                           // carry already set
    rts
!:
    adc #$30                         // carry clear from cmp
    rts

#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"
#import "alloc.asm"
#import "gc.asm"
#import "int_util.asm"
#import "int_negate.asm"
#import "int_add.asm"
#import "int_sub.asm"
#import "int_mul.asm"
#import "int_pow.asm"
#import "int_bitwise.asm"
#import "int_shift.asm"
#import "int_divmod.asm"
#import "int_div.asm"
#import "int_mod.asm"
#import "int_sgn.asm"
#import "int_cmp.asm"
#import "float.asm"
#import "str_to_float.asm"
#import "val.asm"
#import "str.asm"
#import "array.asm"
#import "tuple.asm"
#import "list.asm"
#import "dict.asm"
#import "statics.asm"
#import "int_to_str.asm"
#import "screen.asm"
#import "keyboard.asm"
#import "print.asm"
#import "lexer.asm"
#import "int_parse.asm"
#import "scope.asm"
#import "rnd.asm"
#import "edit.asm"
#import "disk.asm"
#import "builtins.asm"
#import "assign.asm"
#import "parser.asm"
#import "repl.asm"

// -----------------------------------------------------------------------------
// Code-segment cap: must end strictly below $8000 so it doesn't collide with
// the frame stack at $8000. KickAss errors out if `*` (current PC) ≥ $8000.
// -----------------------------------------------------------------------------
.if (* > $8000) {
    .error "Code segment overran $8000 — stacks/heap area corrupted (current end = " + toHexString(*) + ")"
}
