"""Tests for CALL(code, a0..a3) — leaf native-code extension primitive.

The code string holds position-independent 6510 machine code; CALL JSRs into
its first payload byte. Args are passed as handle addresses in W0..W3 (an
inline int's 4 value bytes live at the handle, so `(W0),Y` reads them). The
routine returns a 16-bit result in W0, zero-extended to an inline int.

W0 = $10, W1 = $12 (the ZP pseudo-registers — part of the documented ABI).
"""

from __future__ import annotations

from test_parser import _eval


def test_call_returns_constant(h):
    # LDA #42 ; STA $10 ; LDA #0 ; STA $11 ; RTS   -> W0 = 42
    src = r'CALL("\xA9\x2A\x85\x10\xA9\x00\x85\x11\x60")'
    assert _eval(h, src) == 42


def test_call_doubles_int_arg(h):
    # arg0 handle in W0; inline value low byte at (W0),0.
    # LDY #0 ; LDA ($10),Y ; ASL ; STA $10 ; LDA #0 ; STA $11 ; RTS
    src = r'CALL("\xA0\x00\xB1\x10\x0A\x85\x10\xA9\x00\x85\x11\x60", 21)'
    assert _eval(h, src) == 42


def test_call_adds_two_int_args(h):
    # arg0 in W0, arg1 in W1; result = arg0.lo + arg1.lo.
    # LDY #0 ; LDA ($10),Y ; CLC ; ADC ($12),Y ; STA $10 ; LDA #0 ; STA $11 ; RTS
    src = r'CALL("\xA0\x00\xB1\x10\x18\x71\x12\x85\x10\xA9\x00\x85\x11\x60", 30, 12)'
    assert _eval(h, src) == 42


def test_call_zero_extends_16bit_result(h):
    # LDA #$00 ; STA $10 ; LDA #$01 ; STA $11 ; RTS   -> W0 = $0100 = 256
    src = r'CALL("\xA9\x00\x85\x10\xA9\x01\x85\x11\x60")'
    assert _eval(h, src) == 256
