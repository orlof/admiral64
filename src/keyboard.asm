// -----------------------------------------------------------------------------
// Minimal keyboard facade on top of KERNAL GETIN ($FFE4).
//
// KERNAL's default IRQ (~60 Hz) scans the keyboard matrix and drops decoded
// PETSCII into a 10-byte buffer at $0277. GETIN pops the next byte (or 0 if
// empty). We don't need any CIA1 code — just keep KERNAL mapped and poll.
//
// Both routines are V4' so callers use a uniform preamble/postamble contract.
// Neither allocates, so no GC implications.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

// -----------------------------------------------------------------------------
// kbd_getchar — blocking: spin on GETIN until it returns a non-zero PETSCII
// byte, then return it in A.
//   in:  (no args)
//   out: A = PETSCII byte (never zero).
// -----------------------------------------------------------------------------
kbd_getchar:
    preamble_args(0, 0)
kbd_getchar_spin:
    jsr KERNAL_GETIN
    beq kbd_getchar_spin
    jmp postamble                    // postamble preserves A across the restore loop

// -----------------------------------------------------------------------------
// kbd_poll — non-blocking: one GETIN read, return whatever it gave.
//   in:  (no args)
//   out: A = PETSCII byte (may be 0 when buffer empty).
// -----------------------------------------------------------------------------
kbd_poll:
    preamble_args(0, 0)
    jsr KERNAL_GETIN
    jmp postamble
