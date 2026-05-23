"""RETURN propagates through WHILE/FOR and IF, stopping at the function call
frame.

Previous behavior: stmt_while / stmt_for only knew about CTRL_BREAK; any other
TYPE_CTRL sentinel (including RETURN's wrapped one) was treated as
CTRL_CONTINUE, so `RETURN` inside a loop silently re-iterated forever.
"""

from __future__ import annotations

from conftest import RV


def _eval_int(h, src: str, max_steps: int = 5_000_000) -> int:
    payload = list(src.encode("ascii"))
    handle = h.alloc_str(len(payload))
    h.write_bytes(h.read_word(handle) + 2, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=max_steps)
    rv = h.read_word(RV)
    return h.read_word(rv) | (h.read_word(rv + 2) << 16)


def test_return_breaks_while(h):
    src = ('F = "WHILE 1 == 1:\\n  RETURN 42\\n"\n'
           'F()')
    assert _eval_int(h, src) == 42


def test_return_breaks_for(h):
    src = ('F = "FOR I IN RANGE(10):\\n  RETURN I\\n"\n'
           'F()')
    assert _eval_int(h, src) == 0


def test_return_breaks_for_with_value(h):
    # RETURN should fire on iteration where I == 3.
    src = ('F = "FOR I IN RANGE(10):\\n  IF I == 3:\\n    RETURN I*100\\n"\n'
           'F()')
    assert _eval_int(h, src) == 300


def test_return_breaks_nested_while(h):
    # RETURN inside inner WHILE must propagate through outer WHILE too.
    src = ('F = "WHILE 1 == 1:\\n  WHILE 1 == 1:\\n    RETURN 7\\n"\n'
           'F()')
    assert _eval_int(h, src) == 7


def test_break_still_works(h):
    # Regression: don't break BREAK while fixing RETURN.
    src = ('F = "N = 0\\nWHILE 1 == 1:\\n  N = N + 1\\n  IF N == 5:\\n    BREAK\\nRETURN N"\n'
           'F()')
    assert _eval_int(h, src) == 5


def test_continue_still_works(h):
    # CONTINUE should still re-iterate, not propagate.
    src = ('F = "S = 0\\nFOR I IN RANGE(10):\\n  IF I == 3:\\n    CONTINUE\\n  S = S + I\\nRETURN S"\n'
           'F()')
    # sum(0..9) - 3 = 45 - 3 = 42
    assert _eval_int(h, src) == 42
