"""Smoke tests for EXP/LOG/SQRT/SIN/COS/TAN/ATAN builtins.

Targeted at the bug report where `SIN(1)` returned 1 (the input) while
`SIN(1.0)` returned the correct ~0.8415.
"""
import math
import pytest

from conftest import RV, msbasic_to_python
from test_str import place_str


def _eval_float(h, source):
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8500, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    rv = h.read_word(RV)
    obj = h.read_word(rv)
    return msbasic_to_python(h.read_bytes(obj + 2, 5))


@pytest.mark.parametrize("expr,expected", [
    ("SIN(1.0)", math.sin(1.0)),
    ("SIN(1)",   math.sin(1.0)),
    ("SIN(0.0)", 0.0),
    ("SIN(0)",   0.0),
    ("COS(0)",   1.0),
    ("EXP(0)",   1.0),
    ("EXP(1)",   math.e),
    ("LOG(1)",   0.0),
    ("SQRT(4)",  2.0),
])
def test_transcendental(hfp, expr, expected):
    assert _eval_float(hfp, expr) == pytest.approx(expected, rel=1e-4)
