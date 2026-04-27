"""Tests for the lexer (Stage 7).

Each test places a source string in the heap (via place_str), pushes the
handle on RS, and calls lexer_init. Then it pulls tokens via lexer_next
and verifies LEX_TOKEN_KIND + the (start, end) span.

Token kind values are read from the assembly symbol table so tests stay
in sync with src/defs.asm renames.
"""

from __future__ import annotations

import pytest

from conftest import RV, TYPE_STR
from test_str import place_str, read_str


# ZP cells (must stay in sync with src/defs.asm).
LEX_SRC_HANDLE = 0x35
LEX_PTR = 0x37
LEX_END = 0x39
LEX_TOKEN_START = 0x3B
LEX_TOKEN_END = 0x3D
LEX_TOKEN_KIND = 0x3F
LEX_INDENT_TARGET = 0x40
LEX_INDENT_CURRENT = 0x41

# Token kinds (must stay in sync with src/defs.asm).
TK_EOF = 0x00
TK_NEWLINE = 0x01
TK_INDENT = 0x02
TK_DEDENT = 0x03
TK_INT = 0x04
TK_HEX = 0x05
TK_BIN = 0x06
TK_FLOAT_LIT = 0x07
TK_STR = 0x08
TK_NAME = 0x09
TK_LPAREN = 0x0A
TK_RPAREN = 0x0B
TK_LBRACK = 0x0C
TK_RBRACK = 0x0D
TK_LCURLY = 0x0E
TK_RCURLY = 0x0F
TK_COMMA = 0x10
TK_COLON = 0x11
TK_SEMICOLON = 0x12
TK_DOT = 0x13
TK_AT = 0x14
TK_PLUS = 0x15
TK_MINUS = 0x16
TK_STAR = 0x17
TK_SLASH = 0x18
TK_DSLASH = 0x19
TK_PERCENT = 0x1A
TK_POWER = 0x1B
TK_LSHIFT = 0x1C
TK_RSHIFT = 0x1D
TK_AMP = 0x1E
TK_PIPE = 0x1F
TK_CARET = 0x20
TK_TILDE = 0x21
TK_LT = 0x22
TK_LE = 0x23
TK_GT = 0x24
TK_GE = 0x25
TK_EQ = 0x26
TK_NEQ = 0x27
TK_ASSIGN = 0x28
TK_PLUSEQ = 0x29
TK_MINUSEQ = 0x2A
TK_STAREQ = 0x2B
TK_SLASHEQ = 0x2C
TK_DSLASHEQ = 0x2D
TK_PERCENTEQ = 0x2E
TK_POWEREQ = 0x2F
TK_LSHIFTEQ = 0x30
TK_RSHIFTEQ = 0x31
TK_AMPEQ = 0x32
TK_PIPEEQ = 0x33
TK_CARETEQ = 0x34
TK_IF = 0x35
TK_ELIF = 0x36
TK_ELSE = 0x37
TK_WHILE = 0x38
TK_FOR = 0x39
TK_IN = 0x3A
TK_BREAK = 0x3B
TK_CONTINUE = 0x3C
TK_PASS = 0x3D
TK_RETURN = 0x3E
TK_TRY = 0x3F
TK_EXCEPT = 0x40
TK_FINALLY = 0x41
TK_RAISE = 0x42
TK_DEL = 0x43
TK_AND = 0x44
TK_OR = 0x45
TK_NOT = 0x46
TK_IS = 0x47
TK_TRUE = 0x48
TK_FALSE = 0x49
TK_NONE_KW = 0x4A

ERR_LEX = 0x04


# --- helpers -----------------------------------------------------------------

def _place_source(h, text: str, addr: int = 0x7000) -> int:
    """Place a string source at addr; push handle on RS; return handle addr."""
    payload = list(text.encode("ascii"))
    handle = place_str(h, addr, payload)
    h.rs_push(handle)
    return handle


def _init_and_run(h, text: str):
    """Place source, init lexer (which lexes the first token)."""
    _place_source(h, text)
    h.call("lexer_init")


def _next(h):
    h.call("lexer_next")


def _kind(h) -> int:
    return h.mpu.memory[LEX_TOKEN_KIND]


def _span(h) -> bytes:
    start = h.read_word(LEX_TOKEN_START)
    end = h.read_word(LEX_TOKEN_END)
    return bytes(h.mpu.memory[start:end])


def _drive(h, text: str) -> list[tuple[int, bytes]]:
    """Init lexer on text, return list of (kind, span_bytes) including EOF."""
    _init_and_run(h, text)
    out = [(_kind(h), _span(h))]
    while out[-1][0] != TK_EOF:
        _next(h)
        out.append((_kind(h), _span(h)))
    return out


# --- A: char dispatch / single-char punctuation ------------------------------

@pytest.mark.parametrize("ch,kind", [
    ("(", TK_LPAREN), (")", TK_RPAREN),
    ("[", TK_LBRACK), ("]", TK_RBRACK),
    ("{", TK_LCURLY), ("}", TK_RCURLY),
    (",", TK_COMMA), (":", TK_COLON), (";", TK_SEMICOLON),
    ("@", TK_AT), ("~", TK_TILDE),
])
def test_punct_single(h, ch, kind):
    toks = _drive(h, ch)
    assert toks[0][0] == kind
    assert toks[0][1] == ch.encode()
    assert toks[1][0] == TK_EOF


def test_dot_is_dot_when_not_followed_by_digit(h):
    toks = _drive(h, ".x")
    assert toks[0][0] == TK_DOT
    assert toks[1][0] == TK_NAME


def test_illegal_char_panics(h):
    _place_source(h, "?")
    h.call("lexer_init", expect_panic=True)
    assert h.mpu.memory[0x27] == ERR_LEX


def test_high_bit_byte_panics(h):
    """Byte $80+ is illegal — early high-bit check triggers _lh_recover."""
    payload = [0x80]
    handle = place_str(h, 0x7000, payload)
    h.rs_push(handle)
    h.call("lexer_init", expect_panic=True)
    assert h.mpu.memory[0x27] == ERR_LEX


# --- B: multi-char operators / augmented-assigns -----------------------------

@pytest.mark.parametrize("text,kind", [
    ("+",   TK_PLUS),    ("+=",  TK_PLUSEQ),
    ("-",   TK_MINUS),   ("-=",  TK_MINUSEQ),
    ("*",   TK_STAR),    ("*=",  TK_STAREQ),
    ("**",  TK_POWER),   ("**=", TK_POWEREQ),
    ("/",   TK_SLASH),   ("/=",  TK_SLASHEQ),
    ("//",  TK_DSLASH),  ("//=", TK_DSLASHEQ),
    ("%",   TK_PERCENT), ("%=",  TK_PERCENTEQ),
    ("&",   TK_AMP),     ("&=",  TK_AMPEQ),
    ("|",   TK_PIPE),    ("|=",  TK_PIPEEQ),
    ("^",   TK_CARET),   ("^=",  TK_CARETEQ),
    ("<",   TK_LT),      ("<=",  TK_LE),
    (">",   TK_GT),      (">=",  TK_GE),
    ("<<",  TK_LSHIFT),  ("<<=", TK_LSHIFTEQ),
    (">>",  TK_RSHIFT),  (">>=", TK_RSHIFTEQ),
    ("=",   TK_ASSIGN),  ("==",  TK_EQ),
    ("!=",  TK_NEQ),
])
def test_operator_kinds(h, text, kind):
    toks = _drive(h, text)
    assert toks[0][0] == kind
    assert toks[0][1] == text.encode()


def test_bang_alone_panics(h):
    _place_source(h, "!")
    h.call("lexer_init", expect_panic=True)
    assert h.mpu.memory[0x27] == ERR_LEX


def test_plus_followed_by_non_eq(h):
    """`+x` should lex `+` then `x`, not `+=`."""
    toks = _drive(h, "+x")
    assert toks[0][0] == TK_PLUS
    assert toks[1][0] == TK_NAME
    assert toks[1][1] == b"x"


# --- C: numbers --------------------------------------------------------------

@pytest.mark.parametrize("text", ["0", "1", "9", "10", "1234", "999999999999"])
def test_int_decimal(h, text):
    toks = _drive(h, text)
    assert toks[0][0] == TK_INT
    assert toks[0][1] == text.encode()


@pytest.mark.parametrize("text", ["0x0", "0xff", "0xFF", "0xDeadBeef", "0X1A"])
def test_int_hex(h, text):
    toks = _drive(h, text)
    assert toks[0][0] == TK_HEX
    assert toks[0][1] == text.encode()


@pytest.mark.parametrize("text", ["0b0", "0b1", "0b101", "0B1010"])
def test_int_bin(h, text):
    toks = _drive(h, text)
    assert toks[0][0] == TK_BIN
    assert toks[0][1] == text.encode()


@pytest.mark.parametrize("text", [
    "1.0", "1.", ".5", "1e5", "1e+5", "1e-5", "1.5e2", "1.5e+2", "0.5",
])
def test_float_literal(h, text):
    toks = _drive(h, text)
    assert toks[0][0] == TK_FLOAT_LIT
    assert toks[0][1] == text.encode()


@pytest.mark.parametrize("text", ["1e+", "1e", "1e-"])
def test_float_malformed_panics(h, text):
    _place_source(h, text)
    h.call("lexer_init", expect_panic=True)
    assert h.mpu.memory[0x27] == ERR_LEX


def test_float_dot_then_letter(h):
    """`1.e` lexes as `1.` (float) followed by `e` (name) — no panic."""
    toks = _drive(h, "1.e")
    assert toks[0][0] == TK_FLOAT_LIT
    assert toks[0][1] == b"1."
    assert toks[1][0] == TK_NAME
    assert toks[1][1] == b"e"


def test_dotted_number_then_dot(h):
    """`1.2.3` lexes as float `1.2` followed by `.3` (which is also a float)."""
    toks = _drive(h, "1.2.3")
    assert toks[0][0] == TK_FLOAT_LIT
    assert toks[0][1] == b"1.2"
    assert toks[1][0] == TK_FLOAT_LIT
    assert toks[1][1] == b".3"


# --- D: strings --------------------------------------------------------------

def test_str_empty(h):
    toks = _drive(h, '""')
    assert toks[0][0] == TK_STR
    assert toks[0][1] == b""


def test_str_simple(h):
    toks = _drive(h, '"hello"')
    assert toks[0][0] == TK_STR
    assert toks[0][1] == b"hello"


def test_str_single_quote(h):
    toks = _drive(h, "'a'")
    assert toks[0][0] == TK_STR
    assert toks[0][1] == b"a"


def test_str_mixed_quotes(h):
    toks = _drive(h, "\"it's\"")
    assert toks[0][0] == TK_STR
    assert toks[0][1] == b"it's"


def test_str_with_escapes(h):
    """Span includes the raw backslash-escape sequences (decode is deferred)."""
    toks = _drive(h, '"a\\nb"')
    assert toks[0][0] == TK_STR
    assert toks[0][1] == b"a\\nb"


def test_str_hex_escape(h):
    toks = _drive(h, '"\\xff"')
    assert toks[0][0] == TK_STR
    assert toks[0][1] == b"\\xff"


def test_str_unterminated_panics(h):
    _place_source(h, '"abc')
    h.call("lexer_init", expect_panic=True)
    assert h.mpu.memory[0x27] == ERR_LEX


def test_str_lf_inside_panics(h):
    _place_source(h, '"a\nb"')
    h.call("lexer_init", expect_panic=True)
    assert h.mpu.memory[0x27] == ERR_LEX


def test_str_bad_escape_panics(h):
    """`\\q` is not a recognized escape."""
    _place_source(h, '"\\q"')
    h.call("lexer_init", expect_panic=True)
    assert h.mpu.memory[0x27] == ERR_LEX


def test_str_bad_hex_panics(h):
    """`\\xZZ` — invalid hex digit."""
    _place_source(h, '"\\xGG"')
    h.call("lexer_init", expect_panic=True)
    assert h.mpu.memory[0x27] == ERR_LEX


# --- E: identifiers + keywords -----------------------------------------------

ALL_KEYWORDS = [
    ("if", TK_IF), ("elif", TK_ELIF), ("else", TK_ELSE),
    ("while", TK_WHILE), ("for", TK_FOR), ("in", TK_IN),
    ("break", TK_BREAK), ("continue", TK_CONTINUE), ("pass", TK_PASS),
    ("return", TK_RETURN),
    ("try", TK_TRY), ("except", TK_EXCEPT), ("finally", TK_FINALLY),
    ("raise", TK_RAISE), ("del", TK_DEL),
    ("and", TK_AND), ("or", TK_OR), ("not", TK_NOT), ("is", TK_IS),
    ("True", TK_TRUE), ("False", TK_FALSE), ("None", TK_NONE_KW),
]


@pytest.mark.parametrize("kw,kind", ALL_KEYWORDS)
def test_keyword(h, kw, kind):
    toks = _drive(h, kw)
    assert toks[0][0] == kind
    assert toks[0][1] == kw.encode()


@pytest.mark.parametrize("text", [
    "iff", "els", "else_", "_while", "whilex", "ifx", "Iff",
])
def test_near_miss_is_name(h, text):
    toks = _drive(h, text)
    assert toks[0][0] == TK_NAME
    assert toks[0][1] == text.encode()


@pytest.mark.parametrize("text", [
    "breakable", "whileness", "continuee", "abcdefghi",  # > 8 chars
])
def test_long_identifier_skips_keyword_lookup(h, text):
    toks = _drive(h, text)
    assert toks[0][0] == TK_NAME
    assert toks[0][1] == text.encode()


@pytest.mark.parametrize("text", ["foo_bar_3", "_x", "x9", "ABC", "_"])
def test_identifier_chars(h, text):
    toks = _drive(h, text)
    assert toks[0][0] == TK_NAME
    assert toks[0][1] == text.encode()


# --- F: indent / dedent ------------------------------------------------------

def _kinds(toks):
    return [t[0] for t in toks]


def test_simple_indent(h):
    toks = _drive(h, "if x:\n    y\n")
    assert _kinds(toks) == [
        TK_IF, TK_NAME, TK_COLON, TK_NEWLINE,
        TK_INDENT, TK_NAME, TK_NEWLINE,
        TK_DEDENT, TK_EOF,
    ]


def test_two_level_indent(h):
    src = "if a:\n    if b:\n        c\n"
    toks = _drive(h, src)
    assert _kinds(toks) == [
        TK_IF, TK_NAME, TK_COLON, TK_NEWLINE,
        TK_INDENT, TK_IF, TK_NAME, TK_COLON, TK_NEWLINE,
        TK_INDENT, TK_NAME, TK_NEWLINE,
        TK_DEDENT, TK_DEDENT, TK_EOF,
    ]


def test_dedent_back_to_zero(h):
    src = "if a:\n    if b:\n        c\nq\n"
    toks = _drive(h, src)
    # ... INDENT b INDENT c NEWLINE DEDENT DEDENT NEWLINE q NEWLINE EOF
    expected_tail = [TK_DEDENT, TK_DEDENT, TK_NAME, TK_NEWLINE, TK_EOF]
    assert _kinds(toks)[-len(expected_tail):] == expected_tail


def test_blank_line_inside_block(h):
    """A blank line in a block doesn't emit DEDENT/INDENT bursts."""
    src = "if a:\n    x\n\n    y\n"
    toks = _drive(h, src)
    # No DEDENT between x's NEWLINE and y; the two y-block statements are
    # both at indent 4.
    kinds = _kinds(toks)
    indent_count = kinds.count(TK_INDENT)
    dedent_count = kinds.count(TK_DEDENT)
    assert indent_count == 1
    assert dedent_count == 1


def test_comment_only_line_inside_block(h):
    src = "if a:\n    x\n    # c\n    y\n"
    kinds = _kinds(_drive(h, src))
    assert kinds.count(TK_INDENT) == 1
    assert kinds.count(TK_DEDENT) == 1


def test_eof_flushes_dedents(h):
    """Source ending mid-block (no trailing newline) still emits DEDENTs."""
    src = "if a:\n    x"   # no trailing \n
    kinds = _kinds(_drive(h, src))
    # Whatever comes before, the tail must include a DEDENT then EOF.
    assert TK_DEDENT in kinds
    assert kinds[-1] == TK_EOF


def test_comment_at_top_level(h):
    """Lone comment-only file — should produce just NEWLINE/EOF, no indents."""
    src = "# just a comment"
    kinds = _kinds(_drive(h, src))
    assert TK_INDENT not in kinds
    assert TK_DEDENT not in kinds


# --- G: integration / full programs ------------------------------------------

def test_assignment_program(h):
    src = "x = 1 + 2\n"
    toks = _drive(h, src)
    assert _kinds(toks) == [
        TK_NAME, TK_ASSIGN, TK_INT, TK_PLUS, TK_INT,
        TK_NEWLINE, TK_EOF,
    ]
    assert toks[0][1] == b"x"
    assert toks[2][1] == b"1"
    assert toks[4][1] == b"2"


def test_function_call_like(h):
    src = "foo(x, y)\n"
    toks = _drive(h, src)
    assert _kinds(toks) == [
        TK_NAME, TK_LPAREN, TK_NAME, TK_COMMA, TK_NAME, TK_RPAREN,
        TK_NEWLINE, TK_EOF,
    ]


def test_for_in_range(h):
    src = "for i in range(10):\n    pass\n"
    toks = _drive(h, src)
    assert _kinds(toks) == [
        TK_FOR, TK_NAME, TK_IN, TK_NAME, TK_LPAREN, TK_INT, TK_RPAREN,
        TK_COLON, TK_NEWLINE,
        TK_INDENT, TK_PASS, TK_NEWLINE,
        TK_DEDENT, TK_EOF,
    ]


# --- H: lexer_get_token_as_string --------------------------------------------

def _materialize(h) -> bytes:
    """Call lexer_get_token_as_string and read back the resulting TYPE_STR."""
    h.call("lexer_get_token_as_string")
    handle = h.read_word(RV)
    return bytes(read_str(h, handle))


def test_get_token_as_string_name(h):
    _init_and_run(h, "foo")
    assert _kind(h) == TK_NAME
    assert _materialize(h) == b"foo"


def test_get_token_as_string_int(h):
    _init_and_run(h, "1234")
    assert _kind(h) == TK_INT
    assert _materialize(h) == b"1234"


def test_get_token_as_string_str_simple(h):
    _init_and_run(h, '"hello"')
    assert _kind(h) == TK_STR
    # Span excludes quotes; v1 doesn't escape-decode.
    assert _materialize(h) == b"hello"


def test_get_token_as_string_str_decodes_escape(h):
    r"""Backslash-n decodes to a literal newline byte."""
    _init_and_run(h, '"a\\nb"')
    assert _kind(h) == TK_STR
    assert _materialize(h) == b"a\nb"


@pytest.mark.parametrize("src,expected", [
    (r'"\n"', b"\n"),
    (r'"\t"', b"\t"),
    (r'"\r"', b"\r"),
    (r'"\\"', b"\\"),
    (r'"\""', b'"'),
    (r'"\0"', b"\x00"),
    (r'"\xff"', b"\xff"),
    (r'"\xAB"', b"\xab"),
    (r'"\x41B"', b"AB"),       # \x41 = 'A', then literal 'B'
    (r'"a\nb\tc"', b"a\nb\tc"),
])
def test_get_token_as_string_decodes_all_escapes(h, src, expected):
    _init_and_run(h, src)
    assert _kind(h) == TK_STR
    assert _materialize(h) == expected


def test_get_token_as_string_two_in_a_row(h):
    """After materializing one token, advancing must still work — pointers
    must rebase correctly across the alloc."""
    _init_and_run(h, "alpha beta")
    assert _kind(h) == TK_NAME
    assert _materialize(h) == b"alpha"
    _next(h)
    assert _kind(h) == TK_NAME
    # Span pointers must have rebased to whatever new payload base str_alloc
    # left us with — verified by being able to materialize "beta" too.
    assert _materialize(h) == b"beta"


def test_get_token_as_string_preserves_lex_state(h):
    """Materialization must not corrupt LEX_PTR / indent state, etc."""
    _init_and_run(h, "if x:\n    y\n")
    # First token: TK_IF
    assert _kind(h) == TK_IF
    assert _materialize(h) == b"if"
    # Lex stream continues unchanged.
    _next(h); assert _kind(h) == TK_NAME
    _next(h); assert _kind(h) == TK_COLON
    _next(h); assert _kind(h) == TK_NEWLINE
    _next(h); assert _kind(h) == TK_INDENT
    _next(h); assert _kind(h) == TK_NAME
    assert _materialize(h) == b"y"
