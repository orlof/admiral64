// -----------------------------------------------------------------------------
// int_normalize — strip redundant leading sign bytes from a signed int.
// Operates IN PLACE on the heap object; returns the same handle.
//
//   in:  handle on RS (top)
//   out: RV = handle (same one); object's O_LEN reduced if normalization
//        stripped bytes.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"

int_normalize:
    preamble_args(1, 0)

    // Read handle from RS (do not pop — postamble auto-cleans).
    rs_peek(W0)               // W0 = handle

    // Deref to object pointer in W2 (not advanced past header — we need to
    // write O_LEN back at end).
    ldy #H_PTR
    lda (W0),y
    sta W2
    iny
    lda (W0),y
    sta W2+1

    // Read current length.
    ldy #O_LEN
    lda (W2),y
    sta B0                    // B0 = length

norm_loop:
    lda B0
    cmp #2
    bcc norm_done             // length < 2 → can't shrink

    // Y = O_HEADER + (B0 - 1) = B0 + 1 → index of MSB byte.
    lda B0
    clc
    adc #O_HEADER - 1
    tay
    lda (W2),y
    sta B1                    // B1 = MSB (temp)

    // Read byte below MSB.
    dey
    lda (W2),y
    bmi below_neg

    // Below non-negative → MSB must be $00 to be redundant.
    lda B1
    bne norm_done
    dec B0
    jmp norm_loop

below_neg:
    // Below negative → MSB must be $FF to be redundant.
    lda B1
    cmp #$FF
    bne norm_done
    dec B0
    jmp norm_loop

norm_done:
    // Write new length back to O_LEN.
    ldy #O_LEN
    lda B0
    sta (W2),y
    iny
    lda #0
    sta (W2),y

    // Return handle in RV.
    lda W0
    sta RV
    lda W0+1
    sta RV+1

    jmp postamble
