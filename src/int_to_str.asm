// -----------------------------------------------------------------------------
// int_to_str — render a signed int as a decimal byte string.
//
//   in:  1 handle on RS (top) — the integer to render. Must be normalized.
//   out: RV = TYPE_STR handle containing ASCII decimal representation.
//
// Algorithm: repeated divmod by the pinned static INT_10. Each remainder is
// a digit (0..9), pushed as an ASCII byte onto FS via fs_push_byte. When the
// quotient hits zero the digit loop terminates, sign is pushed (if negative),
// and an exact-size TYPE_STR is allocated. Digits are popped off FS into the
// string payload in order — because the byte-stack is LIFO and digits were
// pushed LSB-first (+ sign last), popping top→bottom yields the correct
// MSB-first output order.
//
// Zero case falls out naturally: divmod(0, 10) = (0, 0), pushes '0', Q=0 →
// exit loop. No special-casing needed.
//
// FS as reversal buffer: byte-pushes between V4' sub-calls are safe because
// int_divmod / str_alloc carve their preamble frames BELOW the current FSP
// and restore FSP exactly on exit. Our scratch bytes live untouched above.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

int_to_str:
    preamble_args(1, 0)

    // --- Compute sign of x, save in B0. ---
    rs_peek(W0)                  // W0 = x handle
    jsr deref_W0_to_W2           // W2 = x payload, A = length
    jsr sign_byte_W2             // A = $00 (non-neg) or $FF (neg)
    sta B0

    // --- Push |x| onto RS as the working value. ---
    bmi i2s_neg
    // Non-negative: dup x as working.
    rs_push(W0)
    jmp i2s_have_working
i2s_neg:
    // Negative: push x, int_negate produces |x| in RV, push RV.
    rs_push(W0)
    jsr int_negate               // consumes top; RV = -x = |x|
    rs_push(RV)
i2s_have_working:
    // RS: [... x, working]. B0 = sign. B1:B2 = 16-bit digit count
    // (8-bit would cap at 255 digits → 2**1000 = 302 digits got truncated).

    lda #0
    sta B1
    sta B2

    // --- Digit-extraction loop. ---
i2s_digit_loop:
    rs_peek(W0)                  // W0 = working
    rs_push(W0)                  // arg 0: dividend
    rs_push_const(INT_10)        // arg 1: divisor
    jsr int_divmod               // RV=Q, RV2=R

    // Extract digit from R: payload[0] if non-empty, else 0.
    lda RV2
    sta W0
    lda RV2+1
    sta W0+1
    jsr deref_W0_to_W2           // W2 = R payload, A = O_LEN
    beq i2s_r_zero
    ldy #0
    lda (W2),y                   // digit value 0..9
    jmp i2s_digit_ready
i2s_r_zero:
    lda #0
i2s_digit_ready:
    clc
    adc #'0'                     // ASCII digit
    fs_push_byte()
    inc B1
    bne !+
    inc B2
!:

    // Is Q zero? Zero for our non-negative Q means either O_LEN=0 or
    // O_LEN=1 & payload[0]=0. Anything else is non-zero.
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    jsr deref_W0_to_W2           // W2 = Q payload, A = O_LEN
    beq i2s_q_zero               // O_LEN = 0
    cmp #1
    bne i2s_replace_working      // O_LEN >= 2 → definitely non-zero
    ldy #0
    lda (W2),y
    beq i2s_q_zero               // O_LEN=1 and payload[0]=0 → zero

i2s_replace_working:
    // Pop old working, push Q as new working.
    rs_drop(1)
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    rs_push(W0)
    jmp i2s_digit_loop

i2s_q_zero:
    // Drop old working; Q is zero and not needed as a root.
    rs_drop(1)

    // --- Sign byte (if negative). ---
    lda B0
    bpl i2s_no_sign
    lda #'-'
    fs_push_byte()
    inc B1
    bne !+
    inc B2
!:
i2s_no_sign:

    // --- Allocate exact-size string. ---
    lda B1
    sta ALLOC_SIZE
    lda B2
    sta ALLOC_SIZE+1
    jsr str_alloc                // RV = string handle
    rs_push(RV)                  // root it
    // RS: [... x, string]

    // --- Deref string and drain FS byte-stack into payload. ---
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    jsr deref_W0_to_W2           // W2 = string payload ptr

    // Copy B1:B2 bytes from FS (top → bottom) into the payload.
    // W2 walks forward through the payload one byte at a time; Y stays 0
    // since fs_pop_byte clobbers it anyway. B1:B2 down-counts to zero.
    // fs_pop_byte's call form keeps the loop body small.
i2s_pop_loop:
    lda B1
    ora B2
    beq i2s_pop_done
    jsr fs_pop_byte_call         // A = digit, Y clobbered
    ldy #0
    sta (W2),y
    inc W2
    bne !+
    inc W2+1
!:
    lda B1
    bne !+
    dec B2
!:
    dec B1
    jmp i2s_pop_loop
i2s_pop_done:

    // --- Return string handle in RV. Top of RS is the string handle. ---
    jmp postamble_peek_rv
