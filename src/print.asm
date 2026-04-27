// -----------------------------------------------------------------------------
// print_str / print_int + `ln` variants — runtime string and integer output.
//
// All four are V4' routines. Both convert their input to a byte stream and
// feed it through screen_put_char. No type dispatch yet — we'll route through
// a polymorphic `print` once we have more than two types.
//
// Register discipline note: screen_put_char clobbers W2/W3/GC_DEST (plus
// A/X/Y) but preserves W0/W1/B0-B7. print_str keeps the payload walking
// pointer in W0 and the remaining byte count in B0, which survive every
// inner call.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

// -----------------------------------------------------------------------------
// print_str — print a TYPE_STR's payload bytes to the screen.
//   in:  1 handle on RS (top) — a TYPE_STR.
//   out: (nothing; no return value)
// -----------------------------------------------------------------------------
print_str:
    preamble_args(1, 0)

    rs_peek(W0)                  // W0 = string handle
    jsr deref_W0_to_W2           // W2 = payload, A = O_LEN
    sta B0                       // B0 = bytes remaining

    // Move the payload pointer into W0 for the loop — W0 is preserved across
    // screen_put_char, W2 is not.
    lda W2
    sta W0
    lda W2+1
    sta W0+1

ps_loop:
    lda B0
    beq ps_done
    ldy #0
    lda (W0),y
    jsr screen_put_char
    // Advance W0 by 1.
    inc W0
    bne !+
    inc W0+1
!:
    dec B0
    jmp ps_loop
ps_done:
    jmp postamble

// -----------------------------------------------------------------------------
// print_int — render a TYPE_INT as decimal and print it.
//   in:  1 handle on RS (top) — a TYPE_INT.
//   out: (nothing)
// -----------------------------------------------------------------------------
print_int:
    preamble_args(1, 0)

    // Dup the int arg to top and call int_to_str.
    rs_peek(W0)
    rs_push(W0)
    jsr int_to_str               // consumes top arg; RV = string handle

    // Root the returned string (no jsr between int_to_str return and rs_push).
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    rs_push(W0)

    // Call print_str on the string (consumes top arg).
    jsr print_str

    jmp postamble

// -----------------------------------------------------------------------------
// println_str — print_str followed by a newline ($0D).
// -----------------------------------------------------------------------------
println_str:
    preamble_args(1, 0)
    rs_peek(W0)
    rs_push(W0)
    jsr print_str
    lda #$0D
    jsr screen_put_char
    jmp postamble

// -----------------------------------------------------------------------------
// println_int — print_int followed by a newline ($0D).
// -----------------------------------------------------------------------------
println_int:
    preamble_args(1, 0)
    rs_peek(W0)
    rs_push(W0)
    jsr print_int
    lda #$0D
    jsr screen_put_char
    jmp postamble

// -----------------------------------------------------------------------------
// print_value — polymorphic print: dispatches on H_TYPE.
//   in:   1 handle on RS — value of any type.
//   out:  (no return; consumes arg)
//
//   TYPE_INT   → print_int
//   TYPE_STR   → print_str
//   TYPE_BOOL  → "True" / "False"  (handle-identity disambiguates)
//   TYPE_NONE  → "None"
//   TYPE_FLOAT → float_to_str → print_str  (requires BASIC ROM)
//   other      → "?"  (defer rich rendering for list/tuple/dict)
// -----------------------------------------------------------------------------
print_value:
    preamble_args(1, 0)

    rs_peek(W0)
    ldy #H_TYPE
    lda (W0),y

    cmp #TYPE_INT
    bne !not_int+
    rs_peek(W0)
    rs_push(W0)
    jsr print_int
    jmp postamble
!not_int:
    cmp #TYPE_STR
    bne !not_str+
    rs_peek(W0)
    rs_push(W0)
    jsr print_str
    jmp postamble
!not_str:
    cmp #TYPE_BOOL
    bne !not_bool+
    // TRUE vs FALSE by handle identity.
    rs_peek(W0)
    lda W0
    cmp #<TRUE
    bne !is_false+
    lda W0+1
    cmp #>TRUE
    bne !is_false+
    rs_push_const(STR_TRUE)
    jsr print_str
    jmp postamble
!is_false:
    rs_push_const(STR_FALSE)
    jsr print_str
    jmp postamble
!not_bool:
    cmp #TYPE_NONE
    bne !not_none+
    rs_push_const(STR_NONE)
    jsr print_str
    jmp postamble
!not_none:
    cmp #TYPE_FLOAT
    bne !not_float+
    rs_peek(W0)
    rs_push(W0)
    jsr float_to_str
    rs_push(RV)
    jsr print_str
    jmp postamble
!not_float:
    // Unsupported — print '?' for now.
    lda #'?'
    jsr screen_put_char
    jmp postamble
