// -----------------------------------------------------------------------------
// float.asm — TYPE_FLOAT primitives, backed by C64 BASIC ROM FP routines.
//
// On real hardware steady state is $01=$36 (BASIC banked OUT). Each FP op
// banks BASIC IN ($01=$37) only across the JSR into BASIC space, then back
// OUT. Heap reads and writes always happen with BASIC OUT, so the heap can
// freely live in $A000-$BFFF.
//
// Heap object layout: O_LEN = 5 + 5 packed MS-Basic bytes.
//   byte 0:    exponent (excess-128; $00 = value is exactly zero)
//   byte 1:    bit 7 = sign, bits 6..0 = high mantissa bits (hidden 1 implicit)
//   bytes 2-4: mantissa low bits
//
// FAC1 ($61-$66) and FAC2 ($69-$6E) are unpacked: 6 bytes each, with the
// hidden bit explicit in byte +1 and a separate sign byte at byte +5
// ($00 positive, $FF negative). Pack/unpack helpers convert between forms.
//
// All binary ops use **register-form** BASIC routines (FADDT/FSUBT/FMULTT/
// FDIVT). Compare uses FSUBT and tests the result. No memory-form ops, no
// scratch buffer, no FCOMP.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "rnd.asm"
#import "int_util.asm"

// -----------------------------------------------------------------------------
// basic_call(addr) / basic_binop(addr) — bank BASIC + KERNAL ROM in, JSR,
// bank back out. Both bracket the call with `_basic_zp_save` /
// `_basic_zp_restore` so the BASIC ROM can freely scribble on our pseudo-
// register file without corrupting V4' frames or allocator state.
//
// BASIC sits at $A000-$BFFF when bit 0 of $01 is set; KERNAL at $E000-$FFFF
// when bit 1 is set. We flip both in for the JSR window — some BASIC
// routines call into KERNAL (POLY1/POLYX for transcendentals), so KERNAL
// has to be present too.
//
// `basic_call` — single-FAC ops where the caller may have preloaded A/Y
// (GIVAYF needs A=hi, Y=lo). The save/restore preserves A and Y across
// the save (HW stack), so the caller's setup survives to the JSR.
//
// `basic_binop` — register-form binary ops (FADDT/FSUBT/FMULTT/FDIVT/FPWRT).
// These need A=FAC1 exp and $6F=combined sign at JSR time. The macro sets
// those up itself AFTER `_basic_zp_save`, so no caller registers need to
// survive — `lda FAC1` at the bottom sets Z/N for the BNE/BEQ on A that
// every register-form entry begins with.
//
// Bank flip via `inc $01` / `dec $01` (not `lda #$37 ; sta $01`) so A, X, Y
// are preserved through the switch. Steady-state $01 is MEM_NORMAL
// ($34, all ROMs + I/O out); three INCs reach $37 (all in), three DECs
// return to $34.
.macro basic_call(addr) {
    pha
    tya
    pha
    jsr _basic_zp_save
    pla
    tay
    pla
    inc $01
    inc $01
    inc $01
    jsr addr
    dec $01
    dec $01
    dec $01
    jsr _basic_zp_restore
}

// basic_binop is now an alias for basic_op — register-form binops are the
// canonical "needs sign-prep and A=FAC1" callers, and the unified envelope
// always does both. Kept as a separate macro name for readability at the
// FADDT/FSUBT/FMULTT/FDIVT/FPWRT call sites.
.macro basic_binop(addr) { basic_op(addr) }

// -----------------------------------------------------------------------------
// _fp_unpack_to_fac1 / _fp_unpack_to_fac2 — packed heap bytes (5) → unpacked
// FAC{1,2} (6 bytes).
//
// Two entry points share one body. They differ only in the FAC base offset
// (0 → FAC1 at $61; 8 → FAC2 at $69), so we parameterize on X and use
// `STA $61,x` zero-page-X addressing throughout. Saves ~54 bytes vs the
// pre-merge duplicates.
//
// Entry from `_fp_unpack_to_fac1` falls through `BEQ _fp_unpack` (always
// taken, since `LDX #0` set Z=1) past the `LDX #8` instruction. Entry from
// `_fp_unpack_to_fac2` lands directly on `LDX #8`.
//
//   in:  W2 = pointer to 5 packed bytes
//   out: FAC{1,2} ($61-$66 / $69-$6E) loaded
//   clobbers: A, X, Y. One byte staged through HW stack across the X-keyed
//             store sequence (X is occupied by the FAC base offset, so we
//             can't TAX/TXA the saved byte). W2 preserved.
//
// Zero-exponent fast path canonicalizes to all-zero unpacked form so that
// downstream BASIC ops see a clean zero.
// -----------------------------------------------------------------------------
_fp_unpack_to_fac1:
    ldx #0
    beq _fp_unpack            // always taken (LDX #0 → Z=1)
_fp_unpack_to_fac2:
    ldx #8
_fp_unpack:
    ldy #0
    lda (W2),y
    sta $61,x                 // exp
    beq _fpu_zero

    iny
    lda (W2),y
    pha                       // save sign+mantissa MSB across X-keyed stores
    ora #$80                  // force hidden bit explicit
    sta $62,x
    iny
    lda (W2),y
    sta $63,x
    iny
    lda (W2),y
    sta $64,x
    iny
    lda (W2),y
    sta $65,x

    pla
    and #$80
    beq _fpu_pos
    lda #$FF
    sta $66,x
    rts
_fpu_pos:
    lda #$00
    sta $66,x
    rts

_fpu_zero:
    lda #0
    sta $62,x
    sta $63,x
    sta $64,x
    sta $65,x
    sta $66,x
    rts

// -----------------------------------------------------------------------------
// _fp_pack_from_fac1 — unpacked FAC1 → packed 5 bytes at (W2).
//   in:  W2 = destination pointer (5 bytes will be written)
//   out: 5 packed bytes written
//   clobbers: A, X, Y (W2 preserved)
//
// On exp=0, writes canonical all-zero (so val_eq's bytewise compare works).
// On non-zero, folds the FAC sign byte into bit 7 of mantissa MSB and clears
// the hidden 1 bit (it's implicit in packed form).
// -----------------------------------------------------------------------------
_fp_pack_from_fac1:
    // Order matters: LDY #0 sets Z based on Y, which would clobber the
    // exponent's zero flag. Set Y first, *then* LDA the exponent so the
    // BNE that follows tests the exponent — STA preserves flags.
    ldy #0
    lda FAC1
    sta (W2),y
    bne _fpp_nonzero

    // Zero — write canonical zero in remaining 4 bytes.
    iny
    lda #0
    sta (W2),y
    iny
    sta (W2),y
    iny
    sta (W2),y
    iny
    sta (W2),y
    rts

_fpp_nonzero:
    lda FAC1+1
    and #$7F                  // strip hidden bit
    ldx FAC1+5
    bpl _fpp_pos
    ora #$80                  // sign bit on
_fpp_pos:
    iny
    sta (W2),y                // byte 1 (sign + mantissa MSB)
    iny
    lda FAC1+2
    sta (W2),y
    iny
    lda FAC1+3
    sta (W2),y
    iny
    lda FAC1+4
    sta (W2),y
    rts

// -----------------------------------------------------------------------------
// _fp_load_left_right — common front-half of binary ops.
//   pre: RS deeper=left, top=right.
//   post: FAC2 = left, FAC1 = right. RS unchanged.
//   clobbers: A, X, Y, W0, W2
// -----------------------------------------------------------------------------
_fp_load_left_right:
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    jsr _fp_unpack_to_fac2

    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    jsr _fp_unpack_to_fac1
    rts

// -----------------------------------------------------------------------------
// _fp_alloc_and_pack — allocate a fresh TYPE_FLOAT and pack FAC1 into it.
//   out: RV = new handle. Payload populated from FAC1.
//   clobbers: A, X, Y, W2 (alloc internals); W0/W1/B regs preserved enough
//             for V4' bodies to continue (the alloc-call's V4' postamble
//             restores caller's W/B).
// -----------------------------------------------------------------------------
_fp_alloc_and_pack:
    lda #5
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_FLOAT
    sta ALLOC_TYPE
    jsr alloc

    jsr deref_RV_to_W2
    jmp _fp_pack_from_fac1   // tail-call: rts back to our caller

// _fp_alloc_pack_post — `jsr _fp_alloc_and_pack ; jmp postamble` shortcut.
// Saves 3 bytes per use across the 10 float builtins that pack and return.
_fp_alloc_pack_post:
    jsr _fp_alloc_and_pack
    jmp postamble

// -----------------------------------------------------------------------------
// float_alloc — empty TYPE_FLOAT (5 zero bytes — canonical zero).
//   in:  (none)
//   out: RV = new handle.
// -----------------------------------------------------------------------------
float_alloc:
    preamble_args(0, 0)

    lda #5
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_FLOAT
    sta ALLOC_TYPE
    jsr alloc

    jsr deref_RV_to_W2
    ldy #4
    lda #0
_fa_zero:
    sta (W2),y
    dey
    bpl _fa_zero

    jmp postamble

// -----------------------------------------------------------------------------
// float_add / float_sub / float_mul / float_div — V4' arithmetic.
//   in:  RS — left (deeper), right (top).
//   out: RV = result handle. Args consumed.
//
// FAC convention for register-form ops: left → FAC2, right → FAC1.
//   FADDT:  FAC1 = FAC2 + FAC1 = left + right
//   FSUBT:  FAC1 = FAC2 - FAC1 = left - right
//   FMULTT: FAC1 = FAC2 * FAC1 = left * right
//   FDIVT:  FAC1 = FAC2 / FAC1 = left / right
// -----------------------------------------------------------------------------
float_add:
    preamble_args(2, 0)
    jsr _fp_load_left_right
    basic_binop(BASIC_FADDT)
    jmp _fp_alloc_pack_post

float_sub:
    preamble_args(2, 0)
    jsr _fp_load_left_right
    basic_binop(BASIC_FSUBT)
    jmp _fp_alloc_pack_post

float_mul:
    preamble_args(2, 0)
    jsr _fp_load_left_right
    basic_binop(BASIC_FMULTT)
    jmp _fp_alloc_pack_post

float_div:
    preamble_args(2, 0)
    jsr _fp_load_left_right

    // Range-check: divisor is FAC1 (right operand). Zero divisor → panic
    // before BASIC's own div-by-zero handler can take us to its error vector.
    lda FAC1
    bne _fdiv_ok
    jmp panic_div_zero
_fdiv_ok:

    basic_binop(BASIC_FDIVT)
    jmp _fp_alloc_pack_post

// -----------------------------------------------------------------------------
// _basic_zp_save / _basic_zp_restore — bracket every BASIC-ROM call so its
// scratch writes can't corrupt our state. Saves the entire `BASIC_ZP_LO ..
// BASIC_ZP_HI` range — every ZP location our code uses, contiguous from
// FSP/RSP/FP/RV through allocator state, lexer state, and runtime scope.
// We don't audit which BASIC routine touches what; we save it all and the
// next addition to our ZP map is automatically protected.
//
// The buffer lives in the code segment; total ~140 cycles per save +
// restore pair, negligible against BASIC FP ops (~10K cycles each).
//
// Leaf — does NOT preserve A/X/Y/flags. The basic_call macro saves A/Y on
// HW stack across `_basic_zp_save` so caller-set-up registers survive to
// the JSR; basic_binop sets up its registers AFTER the save and so doesn't
// need to.
// -----------------------------------------------------------------------------
.const BASIC_ZP_LO  = $02
.const BASIC_ZP_HI  = $47
.const BASIC_ZP_LEN = BASIC_ZP_HI - BASIC_ZP_LO + 1

_basic_zp_save:
    ldy #BASIC_ZP_LEN - 1
!loop:
    lda BASIC_ZP_LO,y
    sta _basic_zp_buf,y
    dey
    bpl !loop-
    rts
_basic_zp_restore:
    ldy #BASIC_ZP_LEN - 1
!loop:
    lda _basic_zp_buf,y
    sta BASIC_ZP_LO,y
    dey
    bpl !loop-
    rts
_basic_zp_buf:
    .fill BASIC_ZP_LEN, 0

// -----------------------------------------------------------------------------
// basic_op(addr) / _fp_basic_envelope — shared bank-flip + JSR + restore for
// any single-FAC ROM call where the caller doesn't need A/Y preserved across
// the ZP save. Replaces both the old `basic_call` (unary) and `basic_binop`
// (register-form binop) inline expansions — the envelope unconditionally does
// the binop-style ARISGN sign-prep and A=FAC1 preload, both of which are
// harmless to unary ROM entries that ignore them.
//
// Saves ~14-16 bytes per site vs the old inline macros: each call shrinks to
// `lda/sta/lda/sta/jsr` (13 bytes) and shares the 32-byte envelope.
// Self-modifies the JMP target — single-threaded contexts only (no IRQ-time
// entries into FP exist in admiral).
//
// `basic_call` (in the section above) is still required for GIVAYF — it
// preserves A=hi/Y=lo across the ZP save via HW-stack pha/tya/pha.
// -----------------------------------------------------------------------------
.macro basic_op(addr) {
    lda #<addr
    sta _fp_basic_target+1
    lda #>addr
    sta _fp_basic_target+2
    jsr _fp_basic_envelope
}

_fp_basic_envelope:
    jsr _basic_zp_save
    // ARISGN ($6F) = FAC1.sign XOR FAC2.sign — required by FMULTT/FDIVT/FPWRT
    // for result-sign computation; harmless to other ROM entries (they don't
    // read ARISGN). Unary callers may see a random XOR if FAC2 was never set
    // up — still harmless because they don't read ARISGN either.
    lda FAC1+5
    eor FAC2+5
    sta ARISGN
    inc $01
    inc $01
    inc $01
    // A = FAC1 exp — required by register-form binops (BNE/BEQ on A at entry).
    // Other ROM entries ignore A or load their own; the preload is harmless.
    // INC $01 above clobbers Z/N so the LDA must come *after* it.
    lda FAC1
    jsr _fp_basic_target
    dec $01
    dec $01
    dec $01
    jmp _basic_zp_restore               // tail-jmp
_fp_basic_target:
    jmp $0000                            // patched per call

// -----------------------------------------------------------------------------
// float_pow — FAC1 = FAC2 ** FAC1 via BASIC FPWRT (which calls EXP/LOG and
// the POLY helpers in KERNAL ROM).
//   in:  RS — base (deeper), exponent (top).
//   out: RV = new TYPE_FLOAT.
// V4'.
// -----------------------------------------------------------------------------
float_pow:
    preamble_args(2, 0)
    jsr _fp_load_left_right
    basic_binop(BASIC_FPWRT)
    jmp _fp_alloc_pack_post

// -----------------------------------------------------------------------------
// float_floordiv — FAC1 = floor(a/b). FDIVT alone is safe; INT does not call
// out to KERNAL POLY but we still save defensively so the same wrapper shape
// applies to all transcendental-style results.
//   in:  RS — a (deeper), b (top).
//   out: RV = new TYPE_FLOAT.
// V4'.
// -----------------------------------------------------------------------------
float_floordiv:
    preamble_args(2, 0)
    jsr _fp_load_left_right

    // Divisor is FAC1 here; reject zero up front.
    lda FAC1
    bne _ffd_ok
    jmp panic_div_zero
_ffd_ok:
    basic_binop(BASIC_FDIVT)         // FAC1 = a / b
    basic_op(BASIC_INT)           // FAC1 = floor(FAC1)
    jmp _fp_alloc_pack_post

// -----------------------------------------------------------------------------
// float_mod — Python-style float `%`: a - floor(a/b) * b. RS [a, b] is left
// in place across the helper sequence so we can re-deref a / b for the
// successive FAC reloads.
//   in:  RS — a (deeper), b (top).
//   out: RV = new TYPE_FLOAT.
// V4'.
// -----------------------------------------------------------------------------
float_mod:
    preamble_args(2, 0)
    jsr _fp_load_left_right

    lda FAC1
    bne _fmod_ok
    jmp panic_div_zero
_fmod_ok:
    basic_binop(BASIC_FDIVT)         // FAC1 = a / b
    basic_op(BASIC_INT)           // FAC1 = floor(a/b)

    // Reload b → FAC2, then FAC1 *= b.
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    jsr _fp_unpack_to_fac2
    basic_binop(BASIC_FMULTT)        // FAC1 = floor(a/b) * b

    // Reload a → FAC2, then FAC1 = a - FAC1.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    jsr _fp_unpack_to_fac2
    basic_binop(BASIC_FSUBT)         // FAC1 = a - floor(a/b)*b

    jmp _fp_alloc_pack_post

// -----------------------------------------------------------------------------
// float_neg — V4' negation. Uses BASIC NEGOP, which just toggles FAC1's
// sign byte (works correctly for zero — leaves it as zero).
//   in:  RS top = float handle.
//   out: RV = new handle holding -x. Arg consumed.
// -----------------------------------------------------------------------------
float_neg:
    preamble_args(1, 0)

    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    jsr _fp_unpack_to_fac1

    basic_op(BASIC_NEGOP)

    jmp _fp_alloc_pack_post

// -----------------------------------------------------------------------------
// float_random — return a TYPE_FLOAT in [0, 1).
//
//   in:  (no args)
//   out: RV = freshly-allocated TYPE_FLOAT, ~31-bit mantissa precision.
//
// Build a value in [1.0, 2.0) by stuffing 4 rand8 bytes directly into FAC1
// (top mantissa byte's bit 7 is the explicit hidden-1; the remaining 31 bits
// are random), then subtract 1.0 to translate the range to [0.0, 1.0).
// Mirrors admiral's float__random uniformity. Costs 4× rand8 + one FSUB.
// -----------------------------------------------------------------------------
float_random:
    preamble_args(0, 0)

    lda #$81
    sta FAC1                        // exp = 1 (excess-128) → value in [1.0, 2.0)

    jsr rand8
    and #$7F                         // clear sign bit of mantissa MSB...
    ora #$80                         // ...and force the hidden-1 bit explicit.
    sta FAC1+1
    jsr rand8
    sta FAC1+2
    jsr rand8
    sta FAC1+3
    jsr rand8
    sta FAC1+4

    lda #0
    sta FAC1+5                       // sign byte = positive

    jsr _fp_alloc_and_pack           // RV = packed [1.0, 2.0)

    // Subtract 1.0: float_sub takes RS [a, b], returns a - b.
    rs_push(RV)
    lda #<FLOAT_ONE
    sta W0
    lda #>FLOAT_ONE
    sta W0+1
    rs_push(W0)
    jsr float_sub                    // RV = our_random - 1.0 → [0.0, 1.0)
    jmp postamble

// -----------------------------------------------------------------------------
// float_cmp — V4' three-way compare. Computes left - right via FSUBT and
// inspects FAC1: zero exp = equal; sign-byte bit 7 set = negative result =
// left<right; otherwise left>right.
//
//   in:  RS — left (deeper), right (top).
//   out: A = $FF / $00 / $01. Args consumed. No allocation.
// -----------------------------------------------------------------------------
float_cmp:
    preamble_args(2, 0)

    jsr _fp_load_left_right
    basic_binop(BASIC_FSUBT)

    lda FAC1
    bne _fc_nonzero
    jmp postamble_a_zero

_fc_nonzero:
    lda FAC1+5
    bmi _fc_neg
    jmp postamble_a_one

_fc_neg:
    jmp postamble_a_ff

// -----------------------------------------------------------------------------
// int_to_float — V4' conversion: TYPE_INT → TYPE_FLOAT.
//
// Algorithm: get magnitude (negate if negative); for each magnitude byte from
// MSB to LSB, FAC1 = FAC1*256 + byte; finally negate if input was negative.
// Multiplication by 256 is done by bumping the exponent ($61) by 8 (zero
// values stay zero).
//
//   in:  RS top = int handle.
//   out: RV = new TYPE_FLOAT handle.
// -----------------------------------------------------------------------------
int_to_float:
    preamble_args(1, 0)

    rs_peek_at(W0, 0)
    jsr int_load_a              // B0..B3 = 32-bit value (LE)

    // Sign → B7; magnitude into B0..B3 (negate if negative).
    lda B3
    bpl _i2f_pos
    lda #$FF
    sta B7
    sec
    lda #0
    sbc B0
    sta B0
    lda #0
    sbc B1
    sta B1
    lda #0
    sbc B2
    sta B2
    lda #0
    sbc B3
    sta B3
    jmp _i2f_build
_i2f_pos:
    lda #0
    sta B7

_i2f_build:
    // FAC1 = 0
    lda #0
    ldx #5
_i2f_zero_fac1:
    sta FAC1,x
    dex
    bpl _i2f_zero_fac1

    // Process bytes MSB-first (B3,B2,B1,B0): FAC1 = FAC1*256 + byte.
    // B5 = byte index 3 → 0; X used transiently to index B0,x ($18..$1B).
    lda #3
    sta B5
_i2f_byte_loop:
    lda FAC1                    // FAC1 *= 256 (skip when still zero)
    beq _i2f_no_x256
    clc
    adc #8
    sta FAC1
_i2f_no_x256:
    ldx B5
    lda B0,x
    beq _i2f_no_add
    sta B6                      // byte to add

    ldx #5                      // FAC2 = FAC1
_i2f_mov:
    lda FAC1,x
    sta FAC2,x
    dex
    bpl _i2f_mov

    lda #0
    ldy B6
    basic_call(BASIC_GIVAYF)    // FAC1 = byte (A=hi=0, Y=lo=byte)
    basic_binop(BASIC_FADDT)    // FAC1 = FAC2 + FAC1
_i2f_no_add:
    dec B5
    bpl _i2f_byte_loop

    lda B7                      // apply sign
    bpl _i2f_pack
    basic_op(BASIC_NEGOP)
_i2f_pack:
    jmp _fp_alloc_pack_post

// -----------------------------------------------------------------------------
// float_to_int — V4' conversion: TYPE_FLOAT → TYPE_INT (truncated toward zero).
//
// Manual mantissa+exponent extraction — symmetric with `int_to_float` and
// covers any value the float can represent (up to ~2¹²⁸ since MS-Basic's
// exponent goes to +127). Replaces an earlier QINT-based path that capped
// at signed-32-bit and would have fallen into BASIC's error vector outside
// that range.
//
// Algorithm:
//   1. Special cases: exp = 0 (canonical zero) or N = exp - 128 ≤ 0
//      (|value| < 1, truncates to 0).
//   2. byte_count = ceil(N / 8); allocate max(byte_count + 1, 5) bytes
//      (need ≥ 5 because we drop the 32-bit mantissa in at offsets 0..3
//      before shifting; the +1 reserves a sign byte for two's-complement).
//   3. Place mantissa LE at offsets 0..3 with the explicit hidden bit.
//   4. Shift the entire payload (LE) by (N - 32) bits — left if positive,
//      right (= shift right by 32 - N) if negative.
//   5. If FAC1 sign byte indicates negative, two's-complement-negate.
//   6. `int_normalize` trims redundant sign-extension bytes.
//
//   in:  RS top = float handle.
//   out: RV = new TYPE_INT handle (normalized, signed two's-complement LE).
// -----------------------------------------------------------------------------
float_to_int:
    preamble_args(1, 0)

    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    jsr _fp_unpack_to_fac1

    // exp = 0 → zero.
    lda FAC1
    bne _f2i_nonzero
    jmp _f2i_zero
_f2i_nonzero:
    sec
    sbc #128                    // A = N (binary-point position)
    bcs _f2i_n_ok
    jmp _f2i_zero               // exp < 128 → |value| < 1 → 0
_f2i_n_ok:
    bne _f2i_n_nonzero
    jmp _f2i_zero               // exp == 128 → [.5,1) → 0
_f2i_n_nonzero:
    sta B0                      // B0 = N (1..127)

    // 32-bit mantissa magnitude → B4..B7 (LE). FAC1+1 holds the hidden bit.
    lda FAC1+4
    sta B4
    lda FAC1+3
    sta B5
    lda FAC1+2
    sta B6
    lda FAC1+1
    sta B7

    // shift = N - 32 : + → left, − → right by abs. Result wraps mod 2^32.
    lda B0
    sec
    sbc #32
    beq _f2i_sign
    bpl _f2i_left

    // right shift by (32 - N)
    eor #$FF
    clc
    adc #1
    cmp #32
    bcs _f2i_zero               // shifts everything out
    tax
_f2i_rloop:
    lsr B7
    ror B6
    ror B5
    ror B4
    dex
    bne _f2i_rloop
    jmp _f2i_sign

_f2i_left:
    cmp #32
    bcs _f2i_zero               // all significant bits shifted past bit 31
    tax
_f2i_lloop:
    asl B4
    rol B5
    rol B6
    rol B7
    dex
    bne _f2i_lloop

_f2i_sign:
    // magnitude → B0..B3
    lda B4
    sta B0
    lda B5
    sta B1
    lda B6
    sta B2
    lda B7
    sta B3
    lda FAC1+5
    bpl _f2i_store
    sec                         // negate
    lda #0
    sbc B0
    sta B0
    lda #0
    sbc B1
    sta B1
    lda #0
    sbc B2
    sta B2
    lda #0
    sbc B3
    sta B3
_f2i_store:
    jsr alloc_int_b0
    jmp postamble

_f2i_zero:
    lda #0
    sta B0
    sta B1
    sta B2
    sta B3
    jsr alloc_int_b0
    jmp postamble

// -----------------------------------------------------------------------------
// float_to_str — V4' conversion: TYPE_FLOAT → TYPE_STR.
//
// FOUT writes a null-terminated ASCII string starting at $0100, with a
// leading space for non-negatives or '-' for negatives. We strip the leading
// space (so str(1.0) → "1", not " 1") but keep '-' intact.
//
//   in:  RS top = float handle.
//   out: RV = new TYPE_STR handle (PETSCII / ASCII; identical for digits).
// -----------------------------------------------------------------------------
float_to_str:
    preamble_args(1, 0)

    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    jsr _fp_unpack_to_fac1

    basic_op(BASIC_FOUT)

    // B1 = source offset into $0100 (0 or 1 if first byte is space).
    ldx #0
    lda $0100
    cmp #' '
    bne _f2s_no_skip
    inx
_f2s_no_skip:
    stx B1

    // B0 = length scanning from $0100+B1 to next $00.
    ldx #0
    ldy B1
_f2s_strlen:
    lda $0100,y
    beq _f2s_have_len
    inx
    iny
    bne _f2s_strlen             // unlikely to wrap, but guard
_f2s_have_len:
    stx B0

    // Allocate TYPE_STR with B0 bytes.
    stx ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr str_alloc

    jsr deref_RV_to_W2

    // Copy B0 bytes from $0100+B1 (src) to (W2)+0..B0-1 (dst).
    // Y = dst offset; B1 acts as a moving src offset (X-indexed into $0100).
    ldy #0
_f2s_copy:
    cpy B0
    beq _f2s_done
    ldx B1
    lda $0100,x
    sta (W2),y
    inc B1
    iny
    jmp _f2s_copy
_f2s_done:

    jmp postamble
