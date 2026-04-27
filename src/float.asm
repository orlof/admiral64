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

// -----------------------------------------------------------------------------
// basic_call(addr) — bank BASIC ROM in, JSR, bank back out.
//
// BASIC sits at $A000-$BFFF when bit 0 of $01 is set. We flip in just for the
// JSR window. KERNAL stays mapped in both states, so IRQs (CIA1 jiffy, CIA2)
// remain serviced from KERNAL ROM and don't see a stale state.
//
// Use this for single-FAC ops (NEGOP, QINT, FOUT, GIVAYF). For binary
// register-form arithmetic (FADDT/FSUBT/FMULTT/FDIVT) use `basic_binop`,
// which additionally preloads A=FAC1 exp and $6F=combined sign — the
// register-form entries assume what a memory-form CONUPK would have set.
// -----------------------------------------------------------------------------
// Bank flip via `inc $01` / `dec $01` (not `lda #$37 ; sta $01`) so A, X, Y
// are preserved through the switch — register-form binary ops need A=FAC1
// exp at JSR time, and GIVAYF needs A=lo / Y=hi. We rely on $01 staying at
// $36 in steady state; INC $36 → $37 banks BASIC IN, DEC $37 → $36 banks
// BASIC OUT.
.macro basic_call(addr) {
    inc $01
    jsr addr
    dec $01
}

.macro basic_binop(addr) {
    // ARISGN ($6F) = FAC1.sign XOR FAC2.sign — what BASIC's CONUPK would have
    // computed. Multiplication and division read it for result sign;
    // addition/subtraction recompute internally so the value is harmless.
    lda FAC1+5
    eor FAC2+5
    sta ARISGN
    inc $01
    // A = FAC1 exp — the register-form entries start with a BNE/BEQ on A,
    // expecting it to reflect the FAC1-zero (or FAC2-zero for FSUBT) check.
    // INC $01 clobbers Z/N flags so the LDA must come *after* it.
    lda FAC1
    jsr addr
    dec $01
}

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
    jsr _fp_alloc_and_pack
    jmp postamble

float_sub:
    preamble_args(2, 0)
    jsr _fp_load_left_right
    basic_binop(BASIC_FSUBT)
    jsr _fp_alloc_and_pack
    jmp postamble

float_mul:
    preamble_args(2, 0)
    jsr _fp_load_left_right
    basic_binop(BASIC_FMULTT)
    jsr _fp_alloc_and_pack
    jmp postamble

float_div:
    preamble_args(2, 0)
    jsr _fp_load_left_right

    // Range-check: divisor is FAC1 (right operand). Zero divisor → panic
    // before BASIC's own div-by-zero handler can take us to its error vector.
    lda FAC1
    bne _fdiv_ok
    lda #ERR_DIV_ZERO
    sta ERROR_CODE
    jmp error_handler
_fdiv_ok:

    basic_binop(BASIC_FDIVT)
    jsr _fp_alloc_and_pack
    jmp postamble

// -----------------------------------------------------------------------------
// _fp_zp_save / _fp_zp_restore — protect allocator + parser ZP against the
// transcendental BASIC FP routines (FPWRT/INT/EXP/LOG and the POLY1/POLYX
// helpers in KERNAL ROM). These routines scribble across $20-$2F (allocator
// state — same range FIN clobbers, called out in str_to_float) and into
// $71-$7D (BASIC POLY scratch). Our V4' preamble already covers $10-$1F
// (W/B), so we need to additionally save $20-$2F. Done from leaf helpers
// to keep the call sites tiny.
//
// Leaf — does NOT preserve W/B/A/X/Y. Callers must arrange around that.
// -----------------------------------------------------------------------------
_fp_zp_save:
    ldy #15
!loop:
    lda $20,y
    sta _fp_zp_buf,y
    dey
    bpl !loop-
    rts
_fp_zp_restore:
    ldy #15
!loop:
    lda _fp_zp_buf,y
    sta $20,y
    dey
    bpl !loop-
    rts
_fp_zp_buf:
    .fill 16, 0

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
    jsr _fp_zp_save
    basic_binop(BASIC_FPWRT)
    jsr _fp_zp_restore
    jsr _fp_alloc_and_pack
    jmp postamble

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
    lda #ERR_DIV_ZERO
    sta ERROR_CODE
    jmp error_handler
_ffd_ok:
    jsr _fp_zp_save
    basic_binop(BASIC_FDIVT)         // FAC1 = a / b
    basic_call(BASIC_INT)            // FAC1 = floor(FAC1)
    jsr _fp_zp_restore
    jsr _fp_alloc_and_pack
    jmp postamble

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
    lda #ERR_DIV_ZERO
    sta ERROR_CODE
    jmp error_handler
_fmod_ok:
    jsr _fp_zp_save
    basic_binop(BASIC_FDIVT)         // FAC1 = a / b
    basic_call(BASIC_INT)            // FAC1 = floor(a/b)

    // Reload b → FAC2, then FAC1 *= b. The reload reads from RS, which we
    // didn't save — RSP/FSP/FP all live in $02-$07 and so far INT/FDIVT
    // haven't touched them. Same assumption as float_div.
    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2
    jsr _fp_unpack_to_fac2
    basic_binop(BASIC_FMULTT)        // FAC1 = floor(a/b) * b

    // Reload a → FAC2, then FAC1 = a - FAC1.
    rs_peek_at(W0, 1)
    jsr deref_W0_to_W2
    jsr _fp_unpack_to_fac2
    basic_binop(BASIC_FSUBT)         // FAC1 = a - floor(a/b)*b

    jsr _fp_zp_restore
    jsr _fp_alloc_and_pack
    jmp postamble

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

    basic_call(BASIC_NEGOP)

    jsr _fp_alloc_and_pack
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
    lda #0
    jmp postamble

_fc_nonzero:
    lda FAC1+5
    bmi _fc_neg
    lda #1
    jmp postamble

_fc_neg:
    lda #$FF
    jmp postamble

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
    jsr deref_W0_to_W2          // W2 = int payload, A = length
    sta B0                      // B0 = length

    // Length 0 → value 0 (jump past mag/loop).
    lda B0
    bne _i2f_nonzero_input
    jmp _i2f_zero_input
_i2f_nonzero_input:

    // Sign byte from MSB.
    jsr sign_byte_W2            // A = $00 (non-neg) or $FF (neg)
    sta B3                      // B3 = sign

    bpl _i2f_have_mag

    // Negative: re-push the int so int_negate can consume it, then root the
    // magnitude. After this, RS top = magnitude.
    rs_peek_at(W0, 0)
    rs_push(W0)
    jsr int_negate              // consumes top dup; RV = magnitude
    rs_push(RV)

    rs_peek_at(W0, 0)
    jsr deref_W0_to_W2          // W2 = magnitude payload, A = length
    sta B0

_i2f_have_mag:
    // FAC1 = 0
    lda #0
    ldx #5
_i2f_zero_fac1:
    sta FAC1,x
    dex
    bpl _i2f_zero_fac1

    lda B0
    sta B1                      // B1 = remaining count, MSB-first
    beq _i2f_apply_sign         // empty magnitude → 0

_i2f_byte_loop:
    // FAC1 *= 256: exponent += 8 (skip if zero).
    lda FAC1
    beq _i2f_no_x256
    clc
    adc #8
    sta FAC1
_i2f_no_x256:

    // byte = magnitude[B1-1]
    ldy B1
    dey
    lda (W2),y
    beq _i2f_no_add
    sta B2

    // FAC2 = FAC1 (save accumulator).
    ldx #5
_i2f_mov:
    lda FAC1,x
    sta FAC2,x
    dex
    bpl _i2f_mov

    // FAC1 = byte (positive 8-bit promotes to signed 16-bit zero-extended).
    // GIVAYF takes A=high byte, Y=low byte. Byte value 0..255 → A=0, Y=byte.
    lda #0
    ldy B2
    basic_call(BASIC_GIVAYF)

    // FAC1 = FAC2 + FAC1. Both operands are positive in this loop, so the
    // sign prep done by basic_binop simplifies to "$6F = 0", harmless.
    basic_binop(BASIC_FADDT)

_i2f_no_add:
    dec B1
    bne _i2f_byte_loop

_i2f_apply_sign:
    lda B3
    bpl _i2f_pack
    basic_call(BASIC_NEGOP)

_i2f_pack:
    jsr _fp_alloc_and_pack
    jmp postamble

_i2f_zero_input:
    // Length 0: produce zero float.
    lda #0
    ldx #5
_i2f_zfac:
    sta FAC1,x
    dex
    bpl _i2f_zfac
    jsr _fp_alloc_and_pack
    jmp postamble

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

    // exp = 0 → result is zero.
    lda FAC1
    bne _f2i_nonzero
    jmp _f2i_alloc_zero
_f2i_nonzero:
    sec
    sbc #128                    // A = N (signed)
    bcs _f2i_n_carry_ok
    jmp _f2i_alloc_zero         // exp < 128 → |value| < 1 → 0
_f2i_n_carry_ok:
    bne _f2i_n_nonzero
    jmp _f2i_alloc_zero         // exp == 128 → |value| in [.5, 1) → 0
_f2i_n_nonzero:
    sta B0                      // B0 = N (1..127)

    // byte_count = ceil(N / 8) = (N + 7) >> 3
    clc
    adc #7
    lsr
    lsr
    lsr
    sta B1                      // B1 = byte_count

    // payload_size = max(byte_count + 1, 5) — need 5 minimum so the 32-bit
    // mantissa fits at offsets 0..3 plus a sign byte at offset 4.
    clc
    adc #1                      // A = byte_count + 1
    cmp #5
    bcs _f2i_size_ok
    lda #5
_f2i_size_ok:
    sta B3                      // B3 = payload size

    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int               // RV = result handle (payload uninitialized)
    rs_push(RV)                 // root
    jsr deref_RV_to_W2

    // Zero the payload (B3 bytes) so the high bytes start at zero.
    ldy B3
    lda #0
_f2i_zero_loop:
    dey
    sta (W2),y
    cpy #0
    bne _f2i_zero_loop

    // Place mantissa at offsets 0..3, LE. FAC1+1 has the explicit hidden bit.
    ldy #0
    lda FAC1+4
    sta (W2),y
    iny
    lda FAC1+3
    sta (W2),y
    iny
    lda FAC1+2
    sta (W2),y
    iny
    lda FAC1+1
    sta (W2),y

    // Shift = N - 32 (signed): + → left, − → right by abs.
    lda B0
    sec
    sbc #32
    beq _f2i_apply_sign         // N == 32: no shift
    bpl _f2i_left_shift_setup

    // N < 32: right-shift by (32 - N) = -A.
    eor #$FF
    clc
    adc #1
    sta B2                      // B2 = right-shift count

_f2i_right_shift_pass:
    // One pass: shift B3 bytes right by 1 bit. Process MSB → LSB so the
    // carry chain propagates downward.
    ldx B3
    ldy B3
    dey                         // Y = MSB index
    clc                         // bit 7 of MSB ← 0 (zero-extended sign)
_f2i_rs_byte:
    lda (W2),y
    ror
    sta (W2),y
    dey
    dex
    bne _f2i_rs_byte
    dec B2
    bne _f2i_right_shift_pass
    jmp _f2i_apply_sign

_f2i_left_shift_setup:
    sta B2                      // B2 = left-shift count
    beq _f2i_apply_sign         // (covered above, defensive)

_f2i_left_shift_pass:
    // One pass: shift B3 bytes left by 1 bit. Process LSB → MSB.
    ldx B3
    ldy #0
    clc                         // bit 0 of LSB ← 0
_f2i_ls_byte:
    lda (W2),y
    rol
    sta (W2),y
    iny
    dex
    bne _f2i_ls_byte
    dec B2
    bne _f2i_left_shift_pass

_f2i_apply_sign:
    lda FAC1+5
    bpl _f2i_normalize          // positive → already correct sign-extended

    // Negative: in-place two's-complement negate of B3 bytes.
    sec
    ldy #0
    ldx B3
_f2i_neg_byte:
    lda #0
    sbc (W2),y
    sta (W2),y
    iny
    dex
    bne _f2i_neg_byte

_f2i_normalize:
    // RS top is still our result handle (rooted earlier). Push a duplicate
    // for int_normalize to consume; the original stays for our postamble.
    rs_peek(W0)
    rs_push(W0)
    jsr int_normalize           // RV = same handle, O_LEN possibly trimmed
    jmp postamble

_f2i_alloc_zero:
    lda #1
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    jsr alloc_int
    jsr deref_RV_to_W2
    lda #0
    ldy #0
    sta (W2),y
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

    basic_call(BASIC_FOUT)

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
