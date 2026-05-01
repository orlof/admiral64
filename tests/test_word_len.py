"""Regression tests for word-aware O_LEN handling on long containers.

Background: deref_W0_to_W2/W3 used to return only the low byte of O_LEN in A.
Callers that did `sta B0` then iterated saw `len & 0xFF` — strings/lists/tuples
≥256 silently truncated. The fix returns A:X = full 16-bit length and the
relevant routines (print_str, builtin_len, val_eq, val_cmp, array_find,
dict_binary_search, dict_get) iterate / compare on the full word.

These tests construct >255-byte strings via the C64-side parser and verify
each routine sees the full length.
"""
from __future__ import annotations

import sys

sys.path.insert(0, 'tests')
import test_parser as tp


def test_len_returns_full_word_for_long_string(hfp):
    """A 300-char string built via repetition reports len 300, not 44."""
    h = hfp
    src = (
        's = "abcdefghij" * 30\n'   # 300 bytes
        'len(s)'
    )
    assert tp._eval(h, src) == 300


def test_len_returns_full_word_at_256_boundary(hfp):
    """The exact-256 boundary: len must return 256, not 0."""
    h = hfp
    src = (
        's = "0123456789abcdef" * 16\n'  # 256 bytes
        'len(s)'
    )
    assert tp._eval(h, src) == 256


def test_str_eq_distinguishes_long_strings(hfp):
    """Two 300-char strings differing only in the high half compare unequal —
    the byte-only val_eq used to walk only the low 256 bytes and miss it."""
    h = hfp
    src = (
        'a = "x" * 300\n'
        'b = "x" * 280 + "y" * 20\n'
        'a == b'
    )
    # 0 = false (correct: they differ in bytes 280..299)
    assert tp._eval(h, src) == 0


def test_str_eq_long_equal_strings(hfp):
    """Two identical 300-char strings still compare equal."""
    h = hfp
    src = (
        'a = "z" * 300\n'
        'b = "z" * 300\n'
        'a == b'
    )
    assert tp._eval(h, src) == 1


def test_str_cmp_long_string_difference_past_256(hfp):
    """Lex-compare must reach a difference at index 280 — used to be invisible."""
    h = hfp
    src = (
        'a = "a" * 280 + "x"\n'
        'b = "a" * 280 + "y"\n'
        'cmp(a, b)'
    )
    # a < b → -1
    assert tp._eval(h, src) == -1


def test_list_append_grows_past_127_elements(hfp):
    """Append more than 127 elements; len reports the full count, last index works."""
    h = hfp
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l = l + [i]\n'
        '    i = i + 1\n'
        'len(l)'
    )
    # Note: `l + [i]` builds via array_merge each iter (still byte-only).
    # array_merge caps at 127, so this hits the cap if not extended.
    # If the test runs but caps the result, len returns < 200.
    # Currently expected to fail or be capped — keeping the test as a forward
    # signal for when array_merge gets the word treatment.
    result = tp._eval(h, src, max_steps=20_000_000)
    assert result == 200


def test_list_append_via_method_grows_past_127(hfp):
    """Same but uses .append() in-place (calls array_append directly)."""
    h = hfp
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l.append(i)\n'
        '    i = i + 1\n'
        'len(l)'
    )
    result = tp._eval(h, src, max_steps=20_000_000)
    assert result == 200


def test_list_append_index_above_127(hfp):
    """After appending past 127, accessing element 150 returns the right value."""
    h = hfp
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l.append(i)\n'
        '    i = i + 1\n'
        'l[150]'
    )
    result = tp._eval(h, src, max_steps=20_000_000)
    assert result == 150


def test_list_append_index_at_127_boundary(hfp):
    """l[127] just at the boundary."""
    h = hfp
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l.append(i)\n'
        '    i = i + 1\n'
        'l[127]'
    )
    result = tp._eval(h, src, max_steps=20_000_000)
    assert result == 127


def test_list_append_index_at_128(hfp):
    """l[128] — first index past byte boundary."""
    h = hfp
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l.append(i)\n'
        '    i = i + 1\n'
        'l[128]'
    )
    result = tp._eval(h, src, max_steps=20_000_000)
    assert result == 128


def test_list_append_index_zero_after_long_growth(hfp):
    """l[0] should still be 0 after the list has grown past 127."""
    h = hfp
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l.append(i)\n'
        '    i = i + 1\n'
        'l[0]'
    )
    result = tp._eval(h, src, max_steps=20_000_000)
    assert result == 0


def test_list_repeat_past_127(hfp):
    """[1] * 200 → 200-element list — array_repeat past the byte cap."""
    h = hfp
    src = (
        'l = [1] * 200\n'
        'len(l)'
    )
    assert tp._eval(h, src) == 200


def test_list_repeat_index_past_127(hfp):
    """l = [42] * 200; l[180] should be 42."""
    h = hfp
    src = (
        'l = [42] * 200\n'
        'l[180]'
    )
    assert tp._eval(h, src) == 42


def test_str_repeat_past_127(hfp):
    """`"a" * 200` is past the byte cap. Multiplier itself is now read as a
    16-bit signed word (was capped at 255 in the original byte-only path)."""
    h = hfp
    src = (
        's = "a" * 200\n'
        'len(s)'
    )
    assert tp._eval(h, src) == 200


def test_str_repeat_past_byte_multiplier(hfp):
    """Multiplier > 255 — exercises the word-aware multiplier path."""
    h = hfp
    src = (
        's = "a" * 300\n'
        'len(s)'
    )
    assert tp._eval(h, src, max_steps=20_000_000) == 300


def test_list_del_past_127(hfp):
    """del l[150] removes the right element from a 200-element list."""
    h = hfp
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l.append(i)\n'
        '    i = i + 1\n'
        'del l[150]\n'
        'l[150]'
    )
    assert tp._eval(h, src, max_steps=20_000_000) == 151


def test_list_del_decrements_len_past_127(hfp):
    """After del at idx>127, len drops by exactly 1."""
    h = hfp
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l.append(i)\n'
        '    i = i + 1\n'
        'del l[180]\n'
        'len(l)'
    )
    assert tp._eval(h, src, max_steps=20_000_000) == 199


def test_long_string_literal_past_byte_cap(hfp):
    """A string literal of 300 chars survives the lexer (was truncated at 255).
    The lexer's _lgts_decode/copy loops used to be byte-only."""
    long_lit = '"' + 'k' * 300 + '"'
    src = f'len({long_lit})'
    assert tp._eval(hfp, src) == 300
