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
    lda #0
    sta repl_shell_retry             // interactive wait reached → a shell
                                     // restart (if any) succeeded
    preamble_args(0, 0)
kbd_getchar_spin:
    // A focus change (C= key) requests a color repaint — do it here, at a
    // safe point (idle REPL/shells spin here), not in the IRQ.
    lda WM_REFRESH_PENDING
    beq _kgc_nofr
    lda #0
    sta WM_REFRESH_PENDING
    lda WM_FLAGS
    lsr
    bcc _kgc_nofr
    jsr wm_refresh
_kgc_nofr:
    // Only the focused task reads the keyboard; others yield and wait.
    lda ts_cur
    cmp TASK_FOCUS
    beq _kgc_read
    jsr task_switch
    jmp kbd_getchar_spin
_kgc_read:
    // Steady-state $01 = MEM_NORMAL ($34). Two INCs → $36 (KERNAL+I/O in)
    // for the GETIN call; two DECs back to $34.
    inc $01
    inc $01
    jsr KERNAL_GETIN
    pha                              // save returned byte across the bank flip
    dec $01
    dec $01
    pla
    bne !+
    // No key: yield to other tasks while we wait (blocking-call yield —
    // preemption only fires at parser_stmt boundaries, and an idle prompt
    // has none). task_switch is a cheap no-op when this is the only task.
    jsr task_switch
    jmp kbd_getchar_spin
!:
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
