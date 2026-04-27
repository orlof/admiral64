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
    // $01 = %00110110: LORAM=0 (BASIC ROM off), HIRAM=1 (KERNAL on),
    // CHAREN=1 (I/O at $D000). Frees $A000-$BFFF for our heap ceiling.
    lda #$36
    sta $01

    jsr rs_init
    jsr fs_init
    jsr alloc_init
    jsr rnd_init

    // Screen must init AFTER the software stacks + heap — print_str runs as
    // a V4' routine and expects FS/RS to be live. BASIC is already banked
    // out above, so VIC / color-RAM writes won't get shadowed.
    jsr screen_init

    // Print banner: rs_push(STR_BANNER); jsr println_str.
    lda #<STR_BANNER
    sta W0
    lda #>STR_BANNER
    sta W0+1
    rs_push(W0)
    jsr println_str

    // Paint a static cursor below the banner so the system looks alive.
    // (No blink yet — IRQ hook is future work.)
    jsr screen_show_cursor

    // Real-hardware entry will eventually invoke the REPL. For now, soft-lock
    // so a stray SYS doesn't crash into garbage.
boot_hang:
    jmp boot_hang

// -----------------------------------------------------------------------------
// error_handler — fatal-error sink. Callers store an ERR_* code in ERROR_CODE
// then JMP here. For now we just spin; later this will render the code on
// screen and wait for reset.
// -----------------------------------------------------------------------------
error_handler:
    jmp error_handler

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
#import "builtins.asm"
#import "parser.asm"

// -----------------------------------------------------------------------------
// Code-segment cap: must end strictly below $8000 so it doesn't collide with
// the frame stack at $8000. KickAss errors out if `*` (current PC) ≥ $8000.
// -----------------------------------------------------------------------------
.if (* > $8000) {
    .error "Code segment overran $8000 — stacks/heap area corrupted (current end = " + toHexString(*) + ")"
}
