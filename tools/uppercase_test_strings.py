#!/usr/bin/env python3
"""One-shot helper for the charset migration ($61-$7A → $41-$5A).

For every Python string/bytes literal in a test file, walk the literal body
and uppercase **only** the substrings that are admiral-syntax tokens (keywords,
builtin/free-function names, method names, and the special `me` receiver key
+ `_` parent-link key are unaffected since `_` has no case). Other lowercase
letters (Python identifiers used as string keys, fixture scope strings,
filesystem paths, regex patterns, error messages, etc.) are left untouched.

The token list mirrors the post-migration TST/keyword tables.

Skips f-strings (their interior is parsed Python, not data).

Usage: uppercase_test_strings.py <file.py> [<file.py> ...]
"""

from __future__ import annotations

import re
import sys
import tokenize
from io import BytesIO

# Reserved words from src/lexer.asm kw_bucket_*. After migration these MUST
# be uppercase to be recognized by the lexer.
KEYWORDS = [
    "if", "or", "is", "in",
    "and", "not", "for", "del", "try", "cls",
    "elif", "else", "pass", "true", "none",
    "false", "while", "break", "raise", "print",
    "return", "except",
    "finally",
    "continue",
]

# Free-function builtins (TST entries from tools/build_tst.py BUILTINS).
BUILTINS = [
    "len", "range", "bool", "abs", "chr", "ord", "type", "int", "float", "str",
    "id", "cmp", "hex", "repr", "sort", "rnd",
    "mem", "globals", "locals", "wset", "wget", "cursor", "format",
    "rm", "dir", "save", "load", "getc", "key", "input", "edit", "peek", "poke",
]

# Method names dispatched through STR_NAME_M_* in src/statics.asm.
METHODS = [
    "upper", "lower", "find", "startswith", "endswith", "isalpha", "isdigit",
    "replace", "split", "append", "insert", "pop", "keys", "values", "create",
]

# Special receiver-binding key in led_lparen's str-call path (STR_ME).
SPECIAL = ["me"]

# Bool/None render strings (STR_TRUE/STR_FALSE/STR_NONE in statics.asm) — print
# output that tests assert against. These are case-sensitive byte comparisons
# in tests, so the post-flip output is uppercase.
RENDER = ["true", "false", "none"]

ALL_WORDS = sorted(set(KEYWORDS + BUILTINS + METHODS + SPECIAL + RENDER),
                   key=len, reverse=True)

# Word-boundary pattern: a token is preceded/followed by anything that isn't
# a Python identifier char. We match each word case-sensitively against
# lowercase. The lookbehind/lookahead handle the boundary check inside string
# literal bodies, where `_` and digits are valid identifier chars.
_WORD_RE = re.compile(
    r"(?<![A-Za-z0-9_])(" + "|".join(ALL_WORDS) + r")(?![A-Za-z0-9_])"
)


def _uppercase_string_literal(tok_string: str) -> str:
    # Strip prefix.
    i = 0
    while i < len(tok_string) and tok_string[i] not in ("'", '"'):
        i += 1
    prefix = tok_string[:i]
    quoted = tok_string[i:]
    if "f" in prefix.lower():
        return tok_string

    # Skip triple-quoted strings — these are docstrings or multi-line text
    # that contain the same English words as our keyword list (`for`, `not`,
    # `or`, `is`, `in`, `return`, ...) and would generate false positives.
    if quoted.startswith(('"""', "'''")):
        return tok_string
    q = quoted[0]
    if not (quoted.startswith(q) and quoted.endswith(q)):
        return tok_string

    body = quoted[len(q):-len(q)]

    # Build a "shadow" string by walking the body and replacing each
    # backslash-escape with same-length non-identifier chars. The escape
    # may be `\\` (Python: literal backslash, 2 body chars) or `\\X` where
    # X is a letter such as `n`/`t`/`r` (Python: literal `\` + literal X,
    # 3 body chars representing an admiral escape like `\n`). In all cases
    # the trailing letter (if any) must be neutralized so lookbehinds at
    # `\\nreturn` still see `return` as preceded by a non-letter.
    shadow_chars = list(body)
    j = 0
    while j < len(shadow_chars):
        if shadow_chars[j] == '\\' and j + 1 < len(shadow_chars):
            nxt = shadow_chars[j + 1]
            if nxt == '\\':
                shadow_chars[j] = '~'
                shadow_chars[j + 1] = '~'
                # If the chars after `\\` look like an admiral escape
                # (letter), neutralize that too.
                if j + 2 < len(shadow_chars) and shadow_chars[j + 2].isalpha():
                    shadow_chars[j + 2] = '~'
                    j += 3
                else:
                    j += 2
                continue
            # Plain `\X` (Python escape): 2 body chars for one resolved char.
            shadow_chars[j] = '~'
            shadow_chars[j + 1] = '~'
            j += 2
            continue
        j += 1
    shadow = ''.join(shadow_chars)

    out = []
    last = 0
    for m in _WORD_RE.finditer(shadow):
        s, e = m.start(), m.end()
        out.append(body[last:s])
        out.append(body[s:e].upper())
        last = e
    out.append(body[last:])
    new_body = ''.join(out)
    if new_body == body:
        return tok_string
    return prefix + q + new_body + q


def transform_file(path: str) -> bool:
    with open(path, 'rb') as f:
        source = f.read()
    try:
        tokens = list(tokenize.tokenize(BytesIO(source).readline))
    except tokenize.TokenizeError as e:
        print(f"{path}: tokenize error {e}", file=sys.stderr)
        return False

    lines = source.decode('utf-8').splitlines(keepends=True)
    edits: list[tuple[int, int, int, int, str]] = []
    for tok in tokens:
        if tok.type != tokenize.STRING:
            continue
        repl = _uppercase_string_literal(tok.string)
        if repl != tok.string:
            (sr, sc) = tok.start
            (er, ec) = tok.end
            edits.append((sr, sc, er, ec, repl))

    if not edits:
        return False

    edits.sort(reverse=True)
    out_lines = lines[:]
    for sr, sc, er, ec, repl in edits:
        si = sr - 1
        ei = er - 1
        if si == ei:
            out_lines[si] = out_lines[si][:sc] + repl + out_lines[si][ec:]
        else:
            head = out_lines[si][:sc]
            tail = out_lines[ei][ec:]
            out_lines[si] = head + repl + tail
            del out_lines[si + 1:ei + 1]

    with open(path, 'w') as f:
        f.write(''.join(out_lines))
    return True


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: uppercase_test_strings.py <file> [<file> ...]",
              file=sys.stderr)
        return 2
    for path in sys.argv[1:]:
        changed = transform_file(path)
        print(f"{path}: {'changed' if changed else 'unchanged'}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
