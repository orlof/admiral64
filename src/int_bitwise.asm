// -----------------------------------------------------------------------------
// int_bitwise_not / _and / _or / _xor — fixed 32-bit bitwise ops.
//
//   not:  in 1 handle on RS;          out RV = ~x
//   and/or/xor: in 2 handles (a deeper, b top); out RV = a OP b
//
// and/or/xor share one body; the SMC opcode byte of a single `ORA B4,x`
// (zero-page,x) is patched to AND/EOR. B0..B7 are contiguous ($18..$1F), so
// `lda B0,x` / `OP B4,x` / `sta B0,x` with x=0..3 walk a vs b vs result.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "int_util.asm"

int_bitwise_not:
    preamble_args(1, 0)
    rs_peek(W0)
    jsr int_load_a               // B0..B3 = x
    lda B0
    eor #$FF
    sta B0
    lda B1
    eor #$FF
    sta B1
    lda B2
    eor #$FF
    sta B2
    lda B3
    eor #$FF
    sta B3
    jsr alloc_int_b0
    jmp postamble

// zero-page,x opcodes: ORA=$15, AND=$35, EOR=$55.
.const OPC_ORA_ZPX = $15
.const OPC_AND_ZPX = $35
.const OPC_EOR_ZPX = $55

int_bitwise_and:
    lda #OPC_AND_ZPX
    bne _ibw_set
int_bitwise_or:
    lda #OPC_ORA_ZPX
    bne _ibw_set
int_bitwise_xor:
    lda #OPC_EOR_ZPX
_ibw_set:
    sta _ibw_op
    preamble_args(2, 0)
    rs_peek_at(W0, 1)
    jsr int_load_a               // B0..B3 = a
    rs_peek_at(W1, 0)
    jsr int_load_b               // B4..B7 = b
    ldx #0
_ibw_loop:
    lda B0,x
_ibw_op:
    ora B4,x                     // SMC: opcode patched to AND/ORA/EOR zp,x
    sta B0,x
    inx
    cpx #4
    bne _ibw_loop
    jsr alloc_int_b0
    jmp postamble
