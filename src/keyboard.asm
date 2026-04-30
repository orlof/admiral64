// -----------------------------------------------------------------------------
// Minimal keyboard facade on top of KERNAL GETIN ($FFE4).
//
// KERNAL's IRQ (~60 Hz, fed by our irq_handler stub via SCNKEY) scans the
// keyboard matrix and drops decoded PETSCII into the 10-byte buffer at $0277.
// GETIN pops the next byte (0 if empty). KERNAL is normally banked OUT
// ($01=$35), so we briefly flip it in around each GETIN call.
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
    // Steady-state $01 = MEM_NORMAL ($34). Two INCs → $36 (KERNAL+I/O in)
    // for the GETIN call; two DECs back to $34.
    inc $01
    inc $01
    jsr KERNAL_GETIN
    pha                              // save returned byte across the bank flip
    dec $01
    dec $01
    pla
    beq kbd_getchar_spin
    jmp postamble                    // postamble preserves A across the restore loop

// -----------------------------------------------------------------------------
// kbd_poll — non-blocking: one GETIN read, return whatever it gave.
//   in:  (no args)
//   out: A = PETSCII byte (may be 0 when buffer empty).
// -----------------------------------------------------------------------------
kbd_poll:
    preamble_args(0, 0)
    inc $01
    inc $01
    jsr KERNAL_GETIN
    pha
    dec $01
    dec $01
    pla
    jmp postamble
