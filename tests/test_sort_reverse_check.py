"""Smoke tests for sort(..., reverse) parity check."""

def _eval_str(h, source: str) -> bytes:
    from test_parser import _eval_str as helper
    return helper(h, source)

def _eval(h, source: str):
    from test_parser import _eval as helper
    return helper(h, source)

def test_sort_str_reverse_true(h):
    assert _eval_str(h, 'sort("cba", true)') == b"cba"

def test_sort_str_reverse_true_banana(h):
    assert _eval_str(h, 'sort("banana", true)') == b"nnbaaa"

def test_sort_str_reverse_false_explicit(h):
    assert _eval_str(h, 'sort("cba", false)') == b"abc"

def test_sort_str_reverse_truthy_int(h):
    """Any truthy 2nd arg counts as reverse=True (val_truthy semantics)."""
    assert _eval_str(h, 'sort("cba", 1)') == b"cba"

def test_sort_str_reverse_falsy_zero(h):
    assert _eval_str(h, 'sort("cba", 0)') == b"abc"

def test_sort_list_reverse_in_place(h):
    """List sort is in-place; reverse=True descending."""
    src = (
        'lst = [3, 1, 2, 5, 4]\n'
        'sort(lst, true)\n'
        'lst[0]'
    )
    assert _eval(h, src) == 5

def test_sort_list_reverse_last(h):
    src = (
        'lst = [3, 1, 2, 5, 4]\n'
        'sort(lst, true)\n'
        'lst[4]'
    )
    assert _eval(h, src) == 1

def test_sort_tuple_reverse_returns_new(h):
    src = (
        't = (3, 1, 2)\n'
        'r = sort(t, true)\n'
        'r[0]'
    )
    assert _eval(h, src) == 3

def test_sort_tuple_reverse_returns_new_last(h):
    src = (
        't = (3, 1, 2)\n'
        'r = sort(t, true)\n'
        'r[2]'
    )
    assert _eval(h, src) == 1

def test_sort_default_no_reverse(h):
    """Without 2nd arg, sort is ascending (regression for SMC default)."""
    assert _eval_str(h, 'sort("cba")') == b"abc"

def test_sort_reverse_then_default_isolated(h):
    """Verify SMC patches don't leak between calls."""
    src = (
        'a = sort("dca", true)\n'   # patches DESC
        'b = sort("dca")\n'         # should re-patch ASC; bug if leaks
        'b'
    )
    assert _eval_str(h, src) == b"acd"
