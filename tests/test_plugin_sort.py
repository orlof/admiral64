"""SORT as a disk-loaded v2 TYPE_CODE plugin — end-to-end through LOAD().

Covers the whole plugin pipeline: tools/build_plugin.py (three-base assembly
+ fixup table), the TYPE_CODE record framing, disk deserialization, the
_llp_code_call v2 probe (pin + carry-set handle return), and SYS_RELOC
re-linking after the payload moves in a GC compaction.
"""

import pathlib
import subprocess
import sys

import pytest

from test_parser import _eval, _eval_str

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUILD = ROOT / "build" / "plugin_sort.bin"


@pytest.fixture(scope="session")
def sort_record() -> bytes:
    r = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "build_plugin.py"),
         str(ROOT / "plugins" / "sort.asm"), str(BUILD)],
        cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, f"build_plugin failed:\n{r.stdout}{r.stderr}"
    return BUILD.read_bytes()


@pytest.fixture
def hs(hd, sort_record):
    hd.kernal_mock.files[b"SORT"] = sort_record
    return hd


# NOTE: name it S, not SORT — until builtin_sort is removed from the TST,
# a bare S(...) call resolves to the kernel builtin, not this plugin.
LOADS = 'S = LOAD("SORT")\n'


def test_sort_str_returns_copy(hs):
    assert _eval_str(hs, LOADS + 'S("cba")') == b"abc"


def test_sort_str_original_untouched(hs):
    src = LOADS + 's = "cba"\nS(s)\ns'
    assert _eval_str(hs, src) == b"cba"


def test_sort_str_reverse(hs):
    assert _eval_str(hs, LOADS + 'S("banana", TRUE)') == b"nnbaaa"


def test_sort_str_reverse_falsy(hs):
    assert _eval_str(hs, LOADS + 'S("cba", 0)') == b"abc"


def test_sort_empty_str(hs):
    assert _eval_str(hs, LOADS + 'S("")') == b""


def test_sort_list_in_place(hs):
    src = LOADS + 'lst = [3, 1, 2, 5, 4]\nS(lst)\nlst[0]'
    assert _eval(hs, src) == 1


def test_sort_list_returns_same_list(hs):
    src = LOADS + 'lst = [3, 1, 2]\nr = S(lst)\nr[2]'
    assert _eval(hs, src) == 3


def test_sort_list_reverse(hs):
    src = LOADS + 'lst = [3, 1, 2, 5, 4]\nS(lst, TRUE)\nlst[0]'
    assert _eval(hs, src) == 5


def test_sort_tuple_copy(hs):
    src = LOADS + 't = (3, 1, 2)\nr = S(t)\nr[0] + t[0]'
    assert _eval(hs, src) == 4  # sorted copy [1,..], original (3,..)


def test_sort_mixed_calls_survive_gc(hs):
    # Enough churn between the two calls to trigger mark/sweep/compact —
    # the payload moves and SYS_RELOC must re-link before the second call.
    src = LOADS + (
        'i = 0\n'
        'WHILE i < 40:\n'
        '  junk = "x" * 50\n'
        '  i = i + 1\n'
        'a = S("dcba")\n'
        'i = 0\n'
        'WHILE i < 40:\n'
        '  junk = "y" * 50\n'
        '  i = i + 1\n'
        'b = S("hgfe")\n'
        'a + b'
    )
    from test_str import place_str, read_str
    from conftest import RV
    handle = place_str(hs, 0x8500, list(src.encode("ascii")))
    hs.rs_push(handle)
    hs.call("parser_eval", max_steps=30_000_000)
    assert bytes(read_str(hs, hs.read_word(RV))) == b"abcdefgh"
