"""End-to-end test of examples/asm.admiral — the in-language 6510 assembler.

Loads the assembler library, assembles a routine, and checks both the exact
machine-code bytes and (via CALL) that the assembled routine runs correctly.

The source here is several KB, so it is placed via the real allocator (a heap
string, as a LOADed program would be) rather than the harness's fixed-address
scratch slot, which would collide with the program's own allocations. The
assembler re-lexes its method bodies per line, so a large step budget is
needed under py65.
"""

from __future__ import annotations

import os

from conftest import RV
from test_str import read_str

STEPS = 120_000_000

_ASM_PATH = os.path.join(os.path.dirname(__file__), "..", "examples", "asm.admiral")
with open(_ASM_PATH) as _f:
    # Drop the trailing `RETURN A` so the program falls through to the
    # invocation we append (a top-level RETURN would stop evaluation early).
    _ASM_LIB = _f.read().rsplit("RETURN A", 1)[0]


def _run(h, source: str):
    """Evaluate `source` from a properly-allocated heap string; return the RV
    handle and a helper to read it."""
    payload = list(source.encode("ascii"))
    handle = h.alloc_str(len(payload))
    obj = h.read_word(handle)            # H_PTR
    h.write_bytes(obj + 2, payload)      # O_HEADER = 2
    h.rs_push(handle)
    h.call("parser_eval", max_steps=STEPS)
    return h.read_word(RV)


def _assemble(h, asm_text: str) -> bytes:
    """Return just the assembled bytes — CODE() frames every payload with the
    unified 7-byte v2 header and a 2-byte empty fixup table (see
    EXTENSIONS.md), which are not the assembler's output."""
    rv = _run(h, _ASM_LIB + '\nA.GO(SRC="' + asm_text + '")')
    return bytes(read_str(h, rv))[7:-2]


def _assemble_and_call(h, asm_text: str, *args: int) -> int:
    arglist = "".join(", " + str(a) for a in args)
    rv = _run(h, _ASM_LIB
              + '\nC = A.GO(SRC="' + asm_text + '")'
              + '\nC(' + arglist.lstrip(", ") + ')')
    lo = h.read_word(rv)                 # inline int: value = H_PTR | H_SIZE<<16
    hi = h.read_word(rv + 2)
    val = lo | (hi << 16)
    return val - 0x1_0000_0000 if val & 0x8000_0000 else val


# Doubles its int argument: arg1 handle now in W1 ($12) under the new
# `code(args)` ABI (W0 holds the code's own load address). Inline value low
# byte at (W1),0.  LDY #0 ; LDA ($12),Y ; ASL ; STA $10 ; LDA #0 ; STA $11 ; RTS
DOUBLE = r"LDY #0\nLDA ($12),Y\nASL\nSTA $10\nLDA #0\nSTA $11\nRTS"
DOUBLE_BYTES = bytes([0xA0, 0x00, 0xB1, 0x12, 0x0A, 0x85, 0x10,
                      0xA9, 0x00, 0x85, 0x11, 0x60])


def test_assemble_double_bytes(h):
    assert _assemble(h, DOUBLE) == DOUBLE_BYTES


def test_assemble_double_runs(h):
    assert _assemble_and_call(h, DOUBLE, 21) == 42


# Sum of five increments — exercises a label + backward branch and register
# names (W0 -> $10).  LDX #5 ; LDA #0 ; L: CLC ; ADC #1 ; DEX ; BNE L ;
# STA W0 ; LDA #0 ; STA W0+1 ; RTS
SUM5 = (r"LDX #5\nLDA #0\nL:\nCLC\nADC #1\nDEX\nBNE L\n"
        r"STA W0\nLDA #0\nSTA W0+1\nRTS")
SUM5_BYTES = bytes([0xA2, 0x05, 0xA9, 0x00, 0x18, 0x69, 0x01, 0xCA,
                    0xD0, 0xFA, 0x85, 0x10, 0xA9, 0x00, 0x85, 0x11, 0x60])


def test_assemble_branch_and_label_bytes(h):
    assert _assemble(h, SUM5) == SUM5_BYTES


def test_assemble_branch_runs(h):
    assert _assemble_and_call(h, SUM5) == 5
