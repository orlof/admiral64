import sys
sys.path.insert(0, 'tests')
import test_parser as tp


def test_inline_montecarlo_small(hfp):
    h = hfp
    src = (
        'n = 20\n'
        'hits = 0\n'
        'i = 0\n'
        'while i < n:\n'
        '    x = rnd()\n'
        '    y = rnd()\n'
        '    if x*x + y*y < 1.0:\n'
        '        hits = hits + 1\n'
        '    i = i + 1\n'
        '4 * hits'  # final expression
    )
    # Just verify it returns without crash. The actual value is non-deterministic.
    tp._eval(h, src)


def test_inline_montecarlo_full(hfp):
    h = hfp
    """The full 200-iteration variant the user reported as crashing."""
    src = (
        'n = 200\n'
        'hits = 0\n'
        'i = 0\n'
        'while i < n:\n'
        '    x = rnd()\n'
        '    y = rnd()\n'
        '    if x*x + y*y < 1.0:\n'
        '        hits += 1\n'
        '    i += 1\n'
        '4 * hits'
    )
    tp._eval(h, src)


def test_string_call_with_rnd(hfp):
    """Minimal string-call lambda calling rnd()."""
    h = hfp
    src = (
        't1 = "return rnd()"\n'
        't1()'
    )
    tp._eval(h, src)


def test_string_call_with_int_arith(hfp):
    """Minimal string-call lambda doing pure int arithmetic."""
    h = hfp
    src = (
        't1 = "return 1 + 2"\n'
        't1()'
    )
    assert tp._eval(h, src) == 3


def test_string_call_with_float_arith(hfp):
    """Minimal string-call lambda doing FP arithmetic."""
    h = hfp
    src = (
        't1 = "return 1.0 + 2.0"\n'
        't1()'
    )
    tp._eval(h, src)


def test_string_call_one_iter_loop(hfp):
    h = hfp
    src = (
        't1 = "i = 0\\nwhile i < 5: i = i + 1\\nreturn i"\n'
        't1()'
    )
    assert tp._eval(h, src) == 5


def test_string_call_augass(hfp):
    """Augmented assignment inside a string-call lambda."""
    h = hfp
    src = (
        't1 = "i = 0\\ni += 5\\nreturn i"\n'
        't1()'
    )
    assert tp._eval(h, src) == 5


def test_string_call_if_inside_while(hfp):
    h = hfp
    src = (
        't1 = "n = 5\\nh = 0\\ni = 0\\nwhile i < n:\\n    if i < 3:\\n        h = h + 1\\n    i = i + 1\\nreturn h"\n'
        't1()'
    )
    assert tp._eval(h, src) == 3


def test_string_call_float_compare_in_if(hfp):
    h = hfp
    src = (
        't1 = "x = 0.5\\nif x*x < 1.0:\\n    return 1\\nreturn 0"\n'
        't1()'
    )
    assert tp._eval(h, src) == 1


def test_montecarlo_string_call_n5(hfp):
    """Same body as the full version but n=5 — bisect the failure."""
    h = hfp
    src = (
        't1 = "n = 5\\n'
        'hits = 0\\n'
        'i = 0\\n'
        'while i < n:\\n'
        '    x = rnd()\\n'
        '    y = rnd()\\n'
        '    if x*x + y*y < 1.0:\\n'
        '        hits += 1\\n'
        '    i += 1\\n'
        'return 4 * hits"\n'
        't1()'
    )
    tp._eval(h, src)


def test_montecarlo_string_call_n20(hfp):
    h = hfp
    src = (
        't1 = "n = 20\\n'
        'hits = 0\\n'
        'i = 0\\n'
        'while i < n:\\n'
        '    x = rnd()\\n'
        '    y = rnd()\\n'
        '    if x*x + y*y < 1.0:\\n'
        '        hits += 1\\n'
        '    i += 1\\n'
        'return 4 * hits"\n'
        't1()'
    )
    tp._eval(h, src)


import pytest


@pytest.mark.parametrize("n", [6, 8, 10, 12, 15])
def test_mc_string_call_bisect_n(hfp, n):
    h = hfp
    src = (
        f't1 = "n = {n}\\n'
        'hits = 0\\n'
        'i = 0\\n'
        'while i < n:\\n'
        '    x = rnd()\\n'
        '    y = rnd()\\n'
        '    if x*x + y*y < 1.0:\\n'
        '        hits += 1\\n'
        '    i += 1\\n'
        'return 4 * hits"\n'
        't1()'
    )
    tp._eval(h, src)


@pytest.mark.parametrize("n", [12, 15, 20, 30])
def test_mc_inline_bisect_n(hfp, n):
    """Same as bisect_n but inline (no string-call lambda)."""
    h = hfp
    src = (
        f'n = {n}\n'
        'hits = 0\n'
        'i = 0\n'
        'while i < n:\n'
        '    x = rnd()\n'
        '    y = rnd()\n'
        '    if x*x + y*y < 1.0:\n'
        '        hits += 1\n'
        '    i += 1\n'
        '4 * hits'
    )
    tp._eval(h, src)


def test_montecarlo_via_string_call(hfp):
    h = hfp
    """User's exact path: assign source as string, call as lambda via T1()."""
    src = (
        't1 = "n = 20\\n'
        'hits = 0\\n'
        'i = 0\\n'
        'while i < n:\\n'
        '    x = rnd()\\n'
        '    y = rnd()\\n'
        '    if x*x + y*y < 1.0:\\n'
        '        hits += 1\\n'
        '    i += 1\\n'
        'return 4 * hits"\n'
        't1()'
    )
    tp._eval(h, src)
