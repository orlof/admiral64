"""TYPE_CODE — a tagged "machine code" value type and the `f(args)` dispatch.

CODE(str) clones a STR into a TYPE_CODE handle. `f(arg1, ..., arg5)` where f is
TYPE_CODE marshals up to 5 positional handles into W1/W2/W3/B0:B1/B2:B3 and
JSRs the payload. W0 carries the code's own load address on entry (for
JMP-indirect loops). The 16-bit value in W0 on RTS becomes the inline-int
result.
"""

from __future__ import annotations

from conftest import RV


def _eval_int(h, src: str, max_steps: int = 3_000_000) -> int:
    payload = list(src.encode("ascii"))
    handle = h.alloc_str(len(payload))
    h.write_bytes(h.read_word(handle) + 2, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=max_steps)
    rv = h.read_word(RV)
    return h.read_word(rv) | (h.read_word(rv + 2) << 16)


TYPE_CODE = 0x2D


def test_code_returns_type_code_tag(h):
    src = ('F = CODE("\\xA9\\x2A\\x85\\x10\\xA9\\x00\\x85\\x11\\x60")\n'
           'TYPE(F)')
    assert _eval_int(h, src) == TYPE_CODE


def test_code_call_returns_constant(h):
    # LDA #42 ; STA W0 ; LDA #0 ; STA W0+1 ; RTS
    src = ('F = CODE("\\xA9\\x2A\\x85\\x10\\xA9\\x00\\x85\\x11\\x60")\n'
           'F()')
    assert _eval_int(h, src) == 42


def test_code_call_one_arg_positional(h):
    # arg1 arrives in W1 (not W0 — that's the base now).
    # LDY #0 ; LDA (W1),Y ; ASL ; STA W0 ; LDA #0 ; STA W0+1 ; RTS
    code = "\\xA0\\x00\\xB1\\x12\\x0A\\x85\\x10\\xA9\\x00\\x85\\x11\\x60"
    src = f'F = CODE("{code}")\nF(21)'
    assert _eval_int(h, src) == 42


def test_code_call_two_args(h):
    # Add W1 lo + W2 lo  →  W0.  Sum two byte-sized ints.
    # LDY #0 ; LDA (W1),Y ; CLC ; ADC (W2),Y ; STA W0 ; LDA #0 ; STA W0+1 ; RTS
    code = "\\xA0\\x00\\xB1\\x12\\x18\\x71\\x14\\x85\\x10\\xA9\\x00\\x85\\x11\\x60"
    src = f'F = CODE("{code}")\nF(30, 12)'
    assert _eval_int(h, src) == 42


def test_code_call_five_args_no_crash(h):
    # Just an RTS — returns whatever W0 was on entry (= the code's load
    # address). Confirms 5-arg marshalling doesn't panic / clobber the
    # parser state and W0 carries the base.
    src = 'F = CODE("\\x60")\nF(1, 2, 3, 4, 5)'
    assert _eval_int(h, src) != 0


def test_code_call_six_args_panics(h):
    src = 'F = CODE("\\x60")\nF(1, 2, 3, 4, 5, 6)'
    payload = list(src.encode("ascii"))
    handle = h.alloc_str(len(payload))
    h.write_bytes(h.read_word(handle) + 2, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000, expect_panic=True)


def test_code_call_propagates_base_in_w0(h):
    # Sanity that the base address in W0 actually points at the first opcode.
    # The code reads its own first byte (which is itself, $A5) and returns it
    # zero-extended.
    # LDY #0 ; LDA (W0),Y ; STA W0 ; LDA #0 ; STA W0+1 ; RTS
    code = "\\xA0\\x00\\xB1\\x10\\x85\\x10\\xA9\\x00\\x85\\x11\\x60"
    src = f'F = CODE("{code}")\nF()'
    assert _eval_int(h, src) == 0xA0    # first byte = LDY opcode
