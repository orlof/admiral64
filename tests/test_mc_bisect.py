"""Bisect MC failure: which body shape triggers the RSP-corruption panic.

These tests are kept short so the harness step-budget doesn't matter — they
either return cleanly or panic during evaluation. The pre-existing string-call
montecarlo bug (task #209) trips the `compound_only` and `full_mc_use_i` cases.
"""
import sys
sys.path.insert(0, 'tests')
import test_parser as tp
import pytest


@pytest.mark.parametrize("n", [10, 15, 20])
def test_string_call_decr_only(hfp, n):
    """`n -= 1` only — no allocations."""
    h = hfp
    src = (
        f't1 = "n = {n}\\n'
        'WHILE n > 0:\\n'
        '    n -= 1\\n'
        'RETURN n"\n'
        't1()'
    )
    assert tp._eval(h, src) == 0


@pytest.mark.parametrize("n", [10, 15, 20])
def test_string_call_with_rnd(hfp, n):
    """rnd() per iter — exercises FP alloc."""
    h = hfp
    src = (
        f't1 = "n = {n}\\n'
        'WHILE n > 0:\\n'
        '    x = RND()\\n'
        '    n -= 1\\n'
        'RETURN n"\n'
        't1()'
    )
    tp._eval(h, src)


@pytest.mark.parametrize("n", [10, 15])
def test_string_call_compound_only(hfp, n):
    """`z = x*x + y*y` — compound FP expression with two rnd()s. This is the
    minimum body that triggers the RSP-corruption panic at n=15+ (task #209)."""
    h = hfp
    src = (
        f't1 = "n = {n}\\n'
        'WHILE n > 0:\\n'
        '    x = RND()\\n'
        '    y = RND()\\n'
        '    z = x*x + y*y\\n'
        '    n -= 1\\n'
        'RETURN n"\n'
        't1()'
    )
    tp._eval(h, src)
