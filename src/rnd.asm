// -----------------------------------------------------------------------------
// AX+ Tinyrand8 — fast 8-bit PRNG with 16-bit internal state.
//
// Algorithm by Wil. Period 59748. The state is held in two immediate-operand
// bytes inside `rand8` itself — classic self-modifying-code trick. Total cost
// is 15 bytes for `rand8`, ~17 bytes for `set_seed`.
//
// `set_seed` distributes the 8-bit input across both state bytes via a fixed
// mask + offset that has been proven (by exhaustion, per the original
// commentary) to land on a maximum-period cycle for any seed value.
//
// Deterministic-by-default: `rnd_init` seeds with 0 so tests get a
// repeatable sequence. Real hardware can re-seed at startup from $A2
// (jiffy clock low) once we wire that up.
// -----------------------------------------------------------------------------

#importonce

// -----------------------------------------------------------------------------
// rand8 — return next 8-bit pseudo-random in A.
//   in:  (none)
//   out: A = next byte
//   clobbers: A, P. X/Y preserved.
// -----------------------------------------------------------------------------
rand8:
.label _r8_b1 = * + 1
    lda #$00                   // operand at _r8_b1 (state byte 1)
    asl
.label _r8_a1 = * + 1
    eor #$00                   // operand at _r8_a1 (state byte 2)
    sta _r8_b1
    adc _r8_a1
    sta _r8_a1
    rts

// -----------------------------------------------------------------------------
// rnd_set_seed — seed the PRNG from A. Picks a maximum-period cycle for
// any 8-bit input via a fixed mask + offset (constants from the original
// AX+ commentary, derived by simulation).
//   in:  A = seed byte
//   clobbers: A, P. X/Y preserved.
// -----------------------------------------------------------------------------
rnd_set_seed:
    pha
    and #217
    clc
    adc #<21263
    sta _r8_a1
    pla
    and #255 - 217
    adc #>21263
    sta _r8_b1
    rts

// -----------------------------------------------------------------------------
// rnd_init — boot-time PRNG initialisation. Seeds with 0 for deterministic
// runs (matters for tests). Hardware-only callers can override later by
// invoking rnd_set_seed with whatever entropy they prefer.
// -----------------------------------------------------------------------------
rnd_init:
    lda #0
    jmp rnd_set_seed
