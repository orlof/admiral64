// -----------------------------------------------------------------------------
// int_parse_{dec,hex,bin} — parse a digit span into a fixed 32-bit inline int.
//
//   in:  W0 = absolute pointer to first digit byte
//        A  = byte length of the span (hex/bin include the "0x"/"0b" prefix)
//   out: RV = TYPE_INT handle
//
// The value accumulates directly in B0..B3 (no per-digit heap allocation):
//   acc = acc*base + digit, then a single alloc_int_b0 at the end.
// Out-of-range literals wrap mod 2^32. Span pointer stays in W0 (no alloc
// happens mid-loop, so GC can't move it).
//
// Register use: B0..B3 = accumulator, B4 = index, B5 = length, W2:W3 = mul
// temp.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"

int_parse_dec:
    preamble_args(0, 0)
    sta B5                       // length
    lda #0
    sta B0
    sta B1
    sta B2
    sta B3
    sta B4                       // index = 0
_ipd_loop:
    lda B4
    cmp B5
    beq _ip_done
    jsr _acc_mul10
    ldy B4
    lda (W0),y
    sec
    sbc #'0'
    jsr _acc_add_a
    inc B4
    jmp _ipd_loop

_ip_done:
    jsr alloc_int_b0
    jmp postamble

// -----------------------------------------------------------------------------
// int_parse_hex — "0xNN" / "0XNN". Body chars 0-9, a-f, A-F.
// -----------------------------------------------------------------------------
int_parse_hex:
    preamble_args(0, 0)
    sta B5
    lda #0
    sta B0
    sta B1
    sta B2
    sta B3
    lda #2                       // skip "0x"
    sta B4
_iph_loop:
    lda B4
    cmp B5
    bne _iph_go
    jmp _ip_done
_iph_go:
    asl B0                       // acc <<= 4
    rol B1
    rol B2
    rol B3
    asl B0
    rol B1
    rol B2
    rol B3
    asl B0
    rol B1
    rol B2
    rol B3
    asl B0
    rol B1
    rol B2
    rol B3
    ldy B4
    lda (W0),y
    cmp #'9'+1
    bcs _iph_alpha
    sec
    sbc #'0'
    jmp _iph_have
_iph_alpha:
    cmp #$61                     // 'a'
    bcs _iph_lower
    sec
    sbc #$41                     // 'A'
    clc
    adc #10
    jmp _iph_have
_iph_lower:
    sec
    sbc #$61                     // 'a'
    clc
    adc #10
_iph_have:
    jsr _acc_add_a
    inc B4
    jmp _iph_loop

// -----------------------------------------------------------------------------
// int_parse_bin — "0bNN" / "0BNN". Body chars '0' or '1'.
// -----------------------------------------------------------------------------
int_parse_bin:
    preamble_args(0, 0)
    sta B5
    lda #0
    sta B0
    sta B1
    sta B2
    sta B3
    lda #2
    sta B4
_ipb_loop:
    lda B4
    cmp B5
    bne _ipb_go
    jmp _ip_done
_ipb_go:
    asl B0                       // acc <<= 1
    rol B1
    rol B2
    rol B3
    ldy B4
    lda (W0),y
    sec
    sbc #'0'
    jsr _acc_add_a
    inc B4
    jmp _ipb_loop

// -----------------------------------------------------------------------------
// _acc_mul10 — B0..B3 *= 10, in place. acc*10 = (acc<<3) + (acc<<1).
//   Uses W2:W3 as a temp copy. Clobbers A.
// -----------------------------------------------------------------------------
_acc_mul10:
    lda B0
    sta W2
    lda B1
    sta W2+1
    lda B2
    sta W3
    lda B3
    sta W3+1
    asl B0                       // acc <<= 3
    rol B1
    rol B2
    rol B3
    asl B0
    rol B1
    rol B2
    rol B3
    asl B0
    rol B1
    rol B2
    rol B3
    asl W2                       // temp <<= 1
    rol W2+1
    rol W3
    rol W3+1
    clc                          // acc += temp
    lda B0
    adc W2
    sta B0
    lda B1
    adc W2+1
    sta B1
    lda B2
    adc W3
    sta B2
    lda B3
    adc W3+1
    sta B3
    rts

// -----------------------------------------------------------------------------
// _acc_add_a — B0..B3 += A (unsigned byte), carry propagated. Clobbers A.
// -----------------------------------------------------------------------------
_acc_add_a:
    clc
    adc B0
    sta B0
    bcc _aaa_done
    inc B1
    bne _aaa_done
    inc B2
    bne _aaa_done
    inc B3
_aaa_done:
    rts
