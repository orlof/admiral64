"""Tests for keyboard.asm — KERNAL GETIN polling.

py65 doesn't have KERNAL ROM mapped, so we stub the GETIN entry point at
$FFE4 with our own small machine-code snippet that returns controlled values.
VICE validates the real behavior.
"""

from __future__ import annotations

KERNAL_GETIN = 0xFFE4


def _stub_getin_always(h, return_val: int) -> None:
    """Stub GETIN to always return `return_val` in A."""
    h.mpu.memory[KERNAL_GETIN + 0] = 0xA9      # LDA #imm
    h.mpu.memory[KERNAL_GETIN + 1] = return_val
    h.mpu.memory[KERNAL_GETIN + 2] = 0x60      # RTS


def _stub_getin_after_n(h, n_zeros: int, then_value: int) -> None:
    """Stub GETIN: return 0 for `n_zeros` calls, then `then_value` thereafter.

    Counter at $02FE, return value at $02FF. Assembly at $FFE4:
        dec $02fe
        lda $02fe
        bne ret_zero    ; still spinning
        lda $02ff       ; counter hit 0 → return the value
        rts
    ret_zero:
        lda #0
        rts
    """
    h.mpu.memory[0x02FE] = n_zeros
    h.mpu.memory[0x02FF] = then_value
    stub = [
        0xCE, 0xFE, 0x02,    # dec $02fe
        0xAD, 0xFE, 0x02,    # lda $02fe
        0xD0, 0x04,          # bne +4
        0xAD, 0xFF, 0x02,    # lda $02ff
        0x60,                # rts
        0xA9, 0x00,          # lda #0
        0x60,                # rts
    ]
    for i, b in enumerate(stub):
        h.mpu.memory[KERNAL_GETIN + i] = b


# --- kbd_poll ----------------------------------------------------------------

def test_kbd_poll_returns_zero_when_buffer_empty(h):
    _stub_getin_always(h, 0x00)
    h.call("kbd_poll")
    assert h.mpu.a == 0x00


def test_kbd_poll_returns_petscii_value(h):
    _stub_getin_always(h, 0x41)  # 'A'
    h.call("kbd_poll")
    assert h.mpu.a == 0x41


# --- kbd_getchar -------------------------------------------------------------

def test_kbd_getchar_returns_immediate_nonzero(h):
    _stub_getin_always(h, 0x58)  # 'X'
    h.call("kbd_getchar")
    assert h.mpu.a == 0x58


def test_kbd_getchar_spins_until_key_appears(h):
    # Return 0 for 3 calls, then 'Z' ($5A) on the 4th call.
    _stub_getin_after_n(h, 3, 0x5A)
    h.call("kbd_getchar")
    assert h.mpu.a == 0x5A
    # Counter should have been fully drained.
    assert h.mpu.memory[0x02FE] == 0
