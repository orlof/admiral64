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


# --- string methods on 300-char inputs --------------------------------------

def test_str_upper_long(hfp):
    """str.upper on a 300-char string folds every letter, returns len 300."""
    src = 'len(("abc" * 100).upper())'
    assert tp._eval(hfp, src) == 300


def test_str_upper_long_first_byte(hfp):
    """str.upper preserves position 0 ('a' → 'A' = 0x41)."""
    src = '("abc" * 100).upper()[0]'
    assert tp._eval(hfp, src) == 0x41   # 'A'


def test_str_upper_long_byte_past_127(hfp):
    """str.upper output at idx > 127 must hold the upper-cased byte."""
    src = '("abc" * 100).upper()[200]'
    # cycle: pos 200 → pos%3 = 2 → 'c' → 'C' = 0x43
    assert tp._eval(hfp, src) == 0x43


def test_str_lower_long(hfp):
    """str.lower on a 300-char string returns len 300."""
    src = 'len(("ABC" * 100).lower())'
    assert tp._eval(hfp, src) == 300


def test_str_lower_long_byte_past_127(hfp):
    """str.lower output at idx > 127 — byte 200 = pos%3=2 = 'C' → 'c' = 0x63."""
    src = '("ABC" * 100).lower()[200]'
    assert tp._eval(hfp, src) == 0x63


def test_str_find_long_haystack(hfp):
    """find a needle past the byte boundary in a 300-char string."""
    src = '("a" * 200 + "needle").find("needle")'
    assert tp._eval(hfp, src) == 200


def test_str_find_with_start_past_127(hfp):
    """find with start arg past the byte boundary (200) finds match at 250."""
    src = '("X" * 250 + "Y").find("Y", 200)'
    assert tp._eval(hfp, src) == 250


def test_str_find_with_end_past_127(hfp):
    """find with end arg past the byte boundary still searches up to it."""
    src = '("X" * 250 + "Y").find("Y", 0, 251)'
    assert tp._eval(hfp, src) == 250


def test_str_find_with_end_excludes_match_past_127(hfp):
    """end_excl past 127 still excludes the match exactly at end."""
    src = '("X" * 250 + "Y").find("Y", 0, 250)'
    assert tp._eval(hfp, src) == -1


def test_str_replace_many_matches(hfp):
    """Replace with > 127 matches — match counter must be word-wide."""
    src = 'len(("a" * 300).replace("a", "BC"))'
    # 300 single-char matches, each replaced by 2 chars → 600 bytes
    assert tp._eval(hfp, src, max_steps=10_000_000) == 600


def test_str_replace_long_input_grows(hfp):
    """Replace shrinks the string by the right amount on long input."""
    src = 'len(("abc" * 100).replace("b", ""))'
    # 100 matches deleted; result is 200 chars
    assert tp._eval(hfp, src, max_steps=10_000_000) == 200


def test_str_split_many_segments(hfp):
    """Split producing > 127 segments — segment-count must be word-wide."""
    src = 'len(("a, " * 200 + "end").split(", "))'
    # 200 separators → 201 segments
    assert tp._eval(hfp, src, max_steps=10_000_000) == 201


def test_str_split_long_segment(hfp):
    """A single segment longer than 256 — segment-length math must be word-wide."""
    src = 'len(("a" * 300 + "," + "b" * 50).split(","))'
    # Two segments — verify count
    assert tp._eval(hfp, src) == 2


def test_str_split_first_long_segment_byte_count(hfp):
    """The first 300-byte segment from split has length 300, not 44."""
    src = 'len(("a" * 300 + "," + "b" * 50).split(",")[0])'
    assert tp._eval(hfp, src) == 300


def test_str_startswith_long_prefix(hfp):
    """startswith with a prefix that crosses the byte boundary works."""
    src = '("a" * 250).startswith("a" * 200)'
    assert tp._eval(hfp, src) == 1


def test_str_startswith_long_prefix_mismatch(hfp):
    """startswith returns False when the prefix differs at byte 200."""
    src = '("a" * 199 + "b" + "a" * 50).startswith("a" * 200)'
    assert tp._eval(hfp, src) == 0


def test_str_endswith_long_suffix(hfp):
    """endswith with a suffix > 127 works."""
    src = '("a" * 250).endswith("a" * 200)'
    assert tp._eval(hfp, src) == 1


def test_str_endswith_long_suffix_mismatch(hfp):
    """endswith returns False when the suffix differs."""
    src = '("a" * 199 + "b" + "a" * 50).endswith("a" * 200)'
    assert tp._eval(hfp, src) == 0


def test_str_isalpha_long(hfp):
    """isalpha on a 300-letter string returns True."""
    src = '("a" * 300).isalpha()'
    assert tp._eval(hfp, src) == 1


def test_str_isalpha_long_with_late_digit(hfp):
    """isalpha returns False when a digit appears past the byte boundary."""
    src = '("a" * 200 + "1" + "a" * 50).isalpha()'
    assert tp._eval(hfp, src) == 0


def test_str_isdigit_long(hfp):
    """isdigit on a 300-digit string returns True."""
    src = '("5" * 300).isdigit()'
    assert tp._eval(hfp, src) == 1


def test_str_isdigit_long_with_late_letter(hfp):
    """isdigit returns False when a letter appears past the byte boundary."""
    src = '("5" * 200 + "x" + "5" * 50).isdigit()'
    assert tp._eval(hfp, src) == 0


def test_str_concat_past_byte_cap(hfp):
    """Concatenating two strings whose sum exceeds 255 chars yields full word len."""
    src = 'len("a" * 200 + "b" * 100)'
    assert tp._eval(hfp, src) == 300


def test_str_concat_byte_at_join(hfp):
    """The byte right at the join boundary holds the second operand's first byte."""
    src = '("a" * 200 + "b" * 100)[200]'
    assert tp._eval(hfp, src) == 0x62   # 'b'


def test_str_index_past_127(hfp):
    """Indexing a 300-char string at position 200 returns the right byte."""
    # "0123456789" * 30: pos 200 → 200 % 10 = 0 → '0' = 0x30
    src = '("0123456789" * 30)[200]'
    assert tp._eval(hfp, src) == 0x30


def test_str_in_long_haystack(hfp):
    """`needle in long_str` finds a match past the byte boundary."""
    src = '"needle" in ("X" * 250 + "needle")'
    assert tp._eval(hfp, src) == 1


def test_str_in_long_haystack_no_match(hfp):
    """`needle in long_str` returns False when no match exists."""
    src = '"needle" in ("X" * 300)'
    assert tp._eval(hfp, src) == 0


# --- 300-element list -------------------------------------------------------

def test_list_repeat_300_indexing_past_127(hfp):
    """[1,2,3]*100 has 300 elements; indexing at 250 follows the cycle."""
    src = '([1,2,3] * 100)[250]'
    # 250 % 3 = 1 → element 1 = 2
    assert tp._eval(hfp, src) == 2


def test_list_concat_long(hfp):
    """list_a + list_b past the byte boundary preserves total length."""
    src = 'len([1] * 200 + [2] * 100)'
    assert tp._eval(hfp, src) == 300


def test_list_concat_byte_at_join(hfp):
    """list-concat boundary element is the first of the right operand."""
    src = '([1] * 200 + [2] * 100)[200]'
    assert tp._eval(hfp, src) == 2


def test_list_in_long(hfp):
    """`x in long_list` finds a match past the byte boundary."""
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l.append(i)\n'
        '    i = i + 1\n'
        '180 in l'
    )
    assert tp._eval(hfp, src, max_steps=20_000_000) == 1


def test_list_eq_distinguishes_long_lists(hfp):
    """Two 200-element lists differing only past byte 127 compare unequal."""
    src = (
        'a = [0] * 200\n'
        'b = [0] * 199 + [1]\n'
        'a == b'
    )
    assert tp._eval(hfp, src, max_steps=20_000_000) == 0


def test_list_eq_long_equal(hfp):
    """Two identical 200-element lists compare equal."""
    src = (
        'a = [7] * 200\n'
        'b = [7] * 200\n'
        'a == b'
    )
    assert tp._eval(hfp, src, max_steps=20_000_000) == 1


def test_list_for_loop_count_past_127(hfp):
    """Iterate a 200-element list and count elements seen."""
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l.append(i)\n'
        '    i = i + 1\n'
        'c = 0\n'
        'for x in l:\n'
        '    c = c + 1\n'
        'c'
    )
    assert tp._eval(hfp, src, max_steps=50_000_000) == 200


def test_list_insert_past_127(hfp):
    """list.insert at idx > 127 places item correctly."""
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l.append(i)\n'
        '    i = i + 1\n'
        'l.insert(150, 999)\n'
        'l[150]'
    )
    assert tp._eval(hfp, src, max_steps=20_000_000) == 999


def test_list_insert_increments_len_past_127(hfp):
    """After insert at idx > 127, len grows by exactly 1."""
    src = (
        'l = []\n'
        'i = 0\n'
        'while i < 200:\n'
        '    l.append(i)\n'
        '    i = i + 1\n'
        'l.insert(150, 999)\n'
        'len(l)'
    )
    assert tp._eval(hfp, src, max_steps=20_000_000) == 201


# --- 300-element tuple ------------------------------------------------------

def test_tuple_repeat_300_len(hfp):
    """(1,2,3)*100 has 300 elements."""
    src = 'len((1,2,3) * 100)'
    assert tp._eval(hfp, src) == 300


def test_tuple_repeat_300_indexing_past_127(hfp):
    """((1,2,3)*100)[250] follows the 3-cycle: 250%3=1 → 2."""
    src = '((1,2,3) * 100)[250]'
    assert tp._eval(hfp, src) == 2


def test_tuple_eq_distinguishes_long_tuples(hfp):
    """Two 300-element tuples differing past byte 127 compare unequal."""
    src = (
        'a = (1,) * 300\n'
        'b = (1,) * 299 + (2,)\n'
        'a == b'
    )
    assert tp._eval(hfp, src, max_steps=20_000_000) == 0


def test_tuple_eq_long_equal(hfp):
    """Two identical 300-element tuples compare equal."""
    src = (
        'a = (5,) * 300\n'
        'b = (5,) * 300\n'
        'a == b'
    )
    assert tp._eval(hfp, src, max_steps=20_000_000) == 1


# --- 300-entry dict ---------------------------------------------------------

# Dict tests use the `h` fixture (full ~30 KB heap, no BASIC ROM) — `hfp`'s
# handle table at $A000 leaves only ~6 KB and a 300-entry dict (key+val ints
# + pair tuples + handles) doesn't fit there.

def test_dict_300_entries_len(h):
    """A dict with 300 entries reports len 300."""
    src = (
        'd = <>\n'
        'i = 0\n'
        'while i < 300:\n'
        '    d[i] = i * 2\n'
        '    i = i + 1\n'
        'len(d)'
    )
    assert tp._eval(h, src, max_steps=200_000_000) == 300


def test_dict_get_past_127(h):
    """dict[k] for a key whose bin-search index is > 127 returns right value."""
    src = (
        'd = <>\n'
        'i = 0\n'
        'while i < 300:\n'
        '    d[i] = i * 2\n'
        '    i = i + 1\n'
        'd[200]'
    )
    assert tp._eval(h, src, max_steps=200_000_000) == 400


def test_dict_get_past_byte_at_high_key(h):
    """dict[k] with k > 255 (key value past byte boundary) works."""
    src = (
        'd = <>\n'
        'i = 0\n'
        'while i < 300:\n'
        '    d[i] = i * 2\n'
        '    i = i + 1\n'
        'd[280]'
    )
    assert tp._eval(h, src, max_steps=200_000_000) == 560


def test_dict_del_past_127(h):
    """del d[k] where k's slot is > 127 shrinks len by 1."""
    src = (
        'd = <>\n'
        'i = 0\n'
        'while i < 300:\n'
        '    d[i] = i * 2\n'
        '    i = i + 1\n'
        'del d[200]\n'
        'len(d)'
    )
    assert tp._eval(h, src, max_steps=200_000_000) == 299


def test_dict_del_past_127_remaining_intact(h):
    """After del at idx > 127, neighbouring entries stay intact."""
    src = (
        'd = <>\n'
        'i = 0\n'
        'while i < 300:\n'
        '    d[i] = i * 2\n'
        '    i = i + 1\n'
        'del d[200]\n'
        'd[201]'
    )
    assert tp._eval(h, src, max_steps=200_000_000) == 402


def test_dict_in_membership_long(h):
    """`k in d` for k whose slot is > 127 returns True."""
    src = (
        'd = <>\n'
        'i = 0\n'
        'while i < 300:\n'
        '    d[i] = i\n'
        '    i = i + 1\n'
        '250 in d'
    )
    assert tp._eval(h, src, max_steps=200_000_000) == 1


# --- range with values past the signed-byte boundary ----------------------

def test_range_200_value_past_127_is_positive(h):
    """range(200)[150] must be 150, not -106 (1-byte payload sign-extends)."""
    assert tp._eval(h, "range(200)[150]", max_steps=10_000_000) == 150


def test_range_200_value_at_128_is_positive(h):
    """range(200)[128] = 128 (was reading as -128 with 1-byte payload)."""
    assert tp._eval(h, "range(200)[128]", max_steps=10_000_000) == 128


def test_range_200_sum(h):
    """sum(range(200)) = 0+1+...+199 = 19900 — wraps detect any negatives."""
    src = (
        's = 0\n'
        'for i in range(200):\n'
        '    s = s + i\n'
        's'
    )
    assert tp._eval(h, src, max_steps=200_000_000) == 199 * 200 // 2


# --- range(start, end) and range(start, end, step) -------------------------

def test_range_two_arg_basic(h):
    """range(3, 7) → [3, 4, 5, 6]"""
    assert tp._eval(h, "len(range(3, 7))") == 4
    assert tp._eval(h, "range(3, 7)[0]") == 3
    assert tp._eval(h, "range(3, 7)[3]") == 6


def test_range_two_arg_empty_when_start_ge_end(h):
    """range(5, 5) and range(7, 5) → empty."""
    assert tp._eval(h, "len(range(5, 5))") == 0
    assert tp._eval(h, "len(range(7, 5))") == 0


def test_range_three_arg_step_2(h):
    """range(0, 10, 2) → [0, 2, 4, 6, 8]"""
    assert tp._eval(h, "len(range(0, 10, 2))") == 5
    assert tp._eval(h, "range(0, 10, 2)[3]") == 6


def test_range_three_arg_descending(h):
    """range(10, 0, -1) → [10, 9, ..., 1]"""
    assert tp._eval(h, "len(range(10, 0, -1))") == 10
    assert tp._eval(h, "range(10, 0, -1)[0]") == 10
    assert tp._eval(h, "range(10, 0, -1)[9]") == 1


def test_range_three_arg_descending_step_negative_2(h):
    """range(10, 0, -2) → [10, 8, 6, 4, 2]"""
    assert tp._eval(h, "len(range(10, 0, -2))") == 5
    assert tp._eval(h, "range(10, 0, -2)[2]") == 6


def test_range_step_zero_returns_empty(h):
    """range(0, 5, 0) → empty list, no infinite loop."""
    assert tp._eval(h, "len(range(0, 5, 0))", max_steps=10_000_000) == 0


def test_range_descending_when_start_less_than_end(h):
    """range(0, 10, -1) → empty (sgn(step) wrong direction)."""
    assert tp._eval(h, "len(range(0, 10, -1))") == 0


def test_range_ascending_when_start_greater_than_end(h):
    """range(10, 0, 1) → empty."""
    assert tp._eval(h, "len(range(10, 0, 1))") == 0


def test_range_bignum_values_2arg(h):
    """range(300, 305) — values past byte boundary in start/end."""
    assert tp._eval(h, "len(range(300, 305))") == 5
    assert tp._eval(h, "range(300, 305)[0]") == 300
    assert tp._eval(h, "range(300, 305)[4]") == 304


def test_range_bignum_step(h):
    """range(0, 1000, 100) — step > 255."""
    assert tp._eval(h, "len(range(0, 1000, 100))") == 10
    assert tp._eval(h, "range(0, 1000, 100)[5]") == 500


def test_range_two_arg_negative_start(h):
    """range(-3, 3) → [-3, -2, -1, 0, 1, 2]"""
    assert tp._eval(h, "len(range(-3, 3))") == 6
    assert tp._eval(h, "range(-3, 3)[0]") == -3
    assert tp._eval(h, "range(-3, 3)[5]") == 2


def test_range_negative_to_positive_step_2(h):
    """range(-4, 5, 2) → [-4, -2, 0, 2, 4]"""
    assert tp._eval(h, "len(range(-4, 5, 2))") == 5
    assert tp._eval(h, "range(-4, 5, 2)[2]") == 0


def test_range_for_loop_descending(h):
    """`for i in range(5, 0, -1)` accumulates 5+4+3+2+1 = 15."""
    src = (
        's = 0\n'
        'for i in range(5, 0, -1):\n'
        '    s = s + i\n'
        's'
    )
    assert tp._eval(h, src) == 15


def test_range_no_args_is_arity_error(h):
    """range() panics ERR_ARITY."""
    h.rs_push(tp.place_str(h, 0x8500, list(b"range()")))
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)
    assert h.mpu.memory[0x27] == 0x06   # ERR_ARITY


def test_range_four_args_is_arity_error(h):
    """range(0, 1, 2, 3) panics ERR_ARITY."""
    h.rs_push(tp.place_str(h, 0x8500, list(b"range(0, 1, 2, 3)")))
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)
    assert h.mpu.memory[0x27] == 0x06   # ERR_ARITY


def test_range_string_arg_is_type_error(h):
    """range('hi') panics ERR_TYPE."""
    h.rs_push(tp.place_str(h, 0x8500, list(b'range("hi")')))
    h.call("parser_eval", expect_panic=True, max_steps=2_000_000)
    assert h.mpu.memory[0x27] == 0x05   # ERR_TYPE


def test_range_huge_bignum_two_steps(h):
    """range(12345678901234567890, 12345678901234567892) has length 2.

    Stresses bignum start/end handling — neither fits in 32 bits, let
    alone a byte. The asked-for case from the previous conversation."""
    src = (
        'r = range(12345678901234567890, 12345678901234567892)\n'
        'len(r)'
    )
    assert tp._eval(h, src, max_steps=20_000_000) == 2


def test_range_huge_bignum_first_element(h):
    """range(12345678901234567890, ...)[0] returns the start value back."""
    src = (
        'r = range(12345678901234567890, 12345678901234567892)\n'
        'r[0] - 12345678901234567890'
    )
    assert tp._eval(h, src, max_steps=20_000_000) == 0


def test_range_huge_bignum_second_element(h):
    """range(N, N+2)[1] = N+1."""
    src = (
        'r = range(12345678901234567890, 12345678901234567892)\n'
        'r[1] - 12345678901234567891'
    )
    assert tp._eval(h, src, max_steps=20_000_000) == 0
