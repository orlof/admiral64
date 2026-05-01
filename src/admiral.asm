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

boot:
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

    lda #<irq_handler
    sta $FFFE
    lda #>irq_handler
    sta $FFFF

    // NMI fires on RESTORE keypress — we don't handle it, but pointing it at
    // an RTI stub keeps the machine alive. The stub is irq_handler+rts (the
    // last byte of irq_handler is rti — close enough for a no-op NMI path).
    lda #<nmi_handler
    sta $FFFA
    lda #>nmi_handler
    sta $FFFB

    // RESET: pointer to boot, so a soft-reset re-enters us.
    lda #<boot
    sta $FFFC
    lda #>boot
    sta $FFFD

    // $01 = MEM_NORMAL ($35): BASIC out, KERNAL out, I/O at $D000. Steady
    // state. Kbd-getchar and the IRQ handler temporarily flip to $36; FP
    // wrappers flip to $37.
    lda #MEM_NORMAL
    sta $01

    cli

    jsr rs_init
    jsr fs_init
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

    // Allocate a 2-byte TYPE_INT holding B1:B0 (lo, hi).
    lda #2
    jsr alloc_int_a_deref_w2     // size in A → alloc TYPE_INT, deref RV→W2
    ldy #0
    lda B0
    sta (W2),y
    iny
    lda B1
    sta (W2),y

    // Normalize (strips leading zero high byte if value < 256), then print.
    rs_push(RV)
    jsr int_normalize
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
// irq_handler — RAM-resident IRQ vector since KERNAL is normally banked out.
//
// On entry the CPU has pushed PC + P; it has NOT pushed A/X/Y. We do that
// ourselves, then flip $01 to MEM_KERNAL ($36) so KERNAL ROM at $E000-$FFFF
// is mapped back in (writes to $01 stay valid since the underlying register
// is not banked). Inside the bank, JSR KERNAL_SCNKEY ($EA87) does what
// KERNAL's normal IRQ handler does for keyboard scan: read the matrix,
// decode, push PETSCII into the $0277 ringbuf, update the modifier latch.
// Then read $DC0D to ack the CIA1 timer-A IRQ source — without this, the
// IRQ line stays asserted and we re-enter immediately.
//
// We deliberately don't run KERNAL's full IRQ ($EA31): it ends with
// JMP $EA81 → A/X/Y pull + RTI, which would skip our $01 restore. SCNKEY
// is a normal JSR-RTS subroutine so we own the unwind.
// -----------------------------------------------------------------------------
irq_handler:
    pha
    txa
    pha
    tya
    pha
    lda $01
    pha
    lda #MEM_KERNAL
    sta $01
    jsr KERNAL_SCNKEY
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
// nmi_handler — bare RTI. RESTORE key fires NMI directly via hardware (CIA2
// NMI mask doesn't gate it). We don't want any of KERNAL's NMI behavior
// (which would BRK back to BASIC), so just dismiss the interrupt.
// -----------------------------------------------------------------------------
nmi_handler:
    rti

#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"
#import "alloc.asm"
#import "gc.asm"
#import "int_normalize.asm"
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
