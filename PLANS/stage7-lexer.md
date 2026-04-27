// -----------------------------------------------------------------------------
// Stage 7 — lexer (detailed implementation plan).
// Reference: dcpu-admiral/src/lexer2.dasm16 (640 lines).
// -----------------------------------------------------------------------------

# Stage 7 — Lexer (detailed plan)

Read this together with `stages-7-10.md`. That file commits the architecture
(parser-evaluator, no AST, etc.); this file commits the *lexer's internal
shape*.

## Model

One current token in ZP. Parser pulls via `lexer_advance`. Token = span,
not value: `(kind, start_ptr, end_ptr)`. The parser materializes
strings/numbers from the substring on demand via `lexer_get_token_as_string`
or by re-scanning the span with `int_parse`.

Source is a `TYPE_STR` heap object. We deref it once on `lexer_init` and
keep absolute payload pointers in ZP. Span pointers are absolute, not
indices — saves a 16-bit add on every byte access. **Risk**: a GC compact
moves payloads. Mitigation: source-string handle is kept on RS as a root,
so it's never collected, and after any allocation that could trigger GC
we re-deref. Allocations during lexing happen only in
`lexer_get_token_as_string` (parser-driven, infrequent).

## ZP layout (extends the partition in `defs.asm`)

| Name | Addr | Size | Purpose |
|---|---|---|---|
| `LEX_SRC_HANDLE` | $35 | 2B | Source `TYPE_STR` handle (kept as a GC root by the caller) |
| `LEX_PTR` | $37 | 2B | Current scan cursor — absolute pointer into payload |
| `LEX_END` | $39 | 2B | One-past-last absolute pointer (EOF when LEX_PTR == LEX_END) |
| `LEX_TOKEN_START` | $3B | 2B | Absolute pointer to first byte of current token |
| `LEX_TOKEN_END` | $3D | 2B | Absolute pointer to one-past-last byte of current token |
| `LEX_TOKEN_KIND` | $3F | 1B | TK_* token kind |
| `LEX_INDENT_TARGET` | $40 | 1B | Indent level the lexer wants to emit toward (set on newline) |
| `LEX_INDENT_CURRENT` | $41 | 1B | Indent level we've actually emitted (drives INDENT/DEDENT bursts) |

13 bytes; range $35..$41. Free pool $35..$56 → 8 bytes still available
for parser/runtime later.

## Token kinds (`TK_*` in `defs.asm`)

Numbered 0..N-1 so dispatch can be array-indexed. **Keep kinds dense and
under 128** so a single byte suffices and tables stay small.

```
End-of-stream / structure
  TK_EOF=0, TK_NEWLINE=1, TK_INDENT=2, TK_DEDENT=3

Literals
  TK_INT=4, TK_HEX=5, TK_BIN=6, TK_FLOAT=7, TK_STR=8, TK_NAME=9

Punctuation (single-char)
  TK_LPAREN=10, TK_RPAREN=11, TK_LBRACK=12, TK_RBRACK=13,
  TK_LCURLY=14, TK_RCURLY=15, TK_COMMA=16, TK_COLON=17,
  TK_SEMICOLON=18, TK_DOT=19, TK_AT=20

Arithmetic / bitwise (operator tokens)
  TK_PLUS=21, TK_MINUS=22, TK_STAR=23, TK_SLASH=24,
  TK_DSLASH=25, TK_PERCENT=26, TK_POWER=27,
  TK_LSHIFT=28, TK_RSHIFT=29,
  TK_AMP=30, TK_PIPE=31, TK_CARET=32, TK_TILDE=33

Comparison + assign
  TK_LT=34, TK_LE=35, TK_GT=36, TK_GE=37, TK_EQ=38, TK_NEQ=39, TK_ASSIGN=40

Augmented-assign (kept contiguous so parser can detect "is augass?" by
range test)
  TK_AUGASS_BASE=41
  TK_PLUSEQ=41, TK_MINUSEQ=42, TK_STAREQ=43, TK_SLASHEQ=44,
  TK_DSLASHEQ=45, TK_PERCENTEQ=46, TK_POWEREQ=47,
  TK_LSHIFTEQ=48, TK_RSHIFTEQ=49,
  TK_AMPEQ=50, TK_PIPEEQ=51, TK_CARETEQ=52
  TK_AUGASS_LAST=52

Keywords
  TK_IF=53, TK_ELIF=54, TK_ELSE=55, TK_WHILE=56, TK_FOR=57, TK_IN=58,
  TK_BREAK=59, TK_CONTINUE=60, TK_PASS=61, TK_RETURN=62,
  TK_TRY=63, TK_EXCEPT=64, TK_FINALLY=65, TK_RAISE=66, TK_DEL=67,
  TK_AND=68, TK_OR=69, TK_NOT=70, TK_IS=71,
  TK_TRUE=72, TK_FALSE=73, TK_NONE=74

Total: 75 kinds. Headroom to ~128 for parser-internal sentinels (e.g.,
TK_TUPLE_COMMA equivalent if needed).
```

`TK_AUGASS_BASE..TK_AUGASS_LAST` is laid out so the parser-evaluator can
test `if (kind - TK_AUGASS_BASE) < 12` and use the offset as an index into
a per-op fanout table. Stage 8 work; documented here so the lexer's
ordering doesn't need to change later.

## Char dispatch

128-entry parallel low/high jump table indexed by source char (high bit =
illegal char → `lex_recover` for bytes ≥ $80). Each entry is the absolute
address of a per-char handler.

```
ldy #0
lda (LEX_PTR),y         ; current char
bmi recover             ; 0x80+ → illegal
tax
lda lex_jmp_lo,x
sta vec
lda lex_jmp_hi,x
sta vec+1
jmp (vec)
```

Cost: ~13 bytes per dispatch site, 1 indirect jump. We have **one**
dispatch site (in `_lex_dispatch_current`); per-char handlers tail-jump
to a common `_lex_finish` epilogue.

Tables: 128 × 2 × 1B = 256 bytes. Per-char handlers reuse where possible
(all single-char punctuation goes through one shared `_lex_punct1`
helper that takes the kind in A).

For chars ≥ $80 we don't store a slot — the early `bmi` branch above
handles them. This saves 256 bytes vs. a 256-entry table.

## Per-char handlers (compressed plan)

| Char(s) | Handler | Logic |
|---|---|---|
| `$00` (NUL) | `lex_eof` | Set kind = TK_EOF, force indent target = 0, finish |
| LF (`$0A`) / CR (`$0D`) | `lex_newline` | Set kind = TK_NEWLINE; consume the byte; scan following bytes counting leading spaces; collapse blank/comment-only lines (loop back to "scan following bytes"); set INDENT_TARGET |
| ` ` (space) | `lex_whitespace` | Should never be reached — `_lex_skip_whitespace` runs *before* dispatch |
| `#` | `lex_comment` | Skip to EOL, then fall through to `lex_newline` |
| `"` `'` | `lex_string` | See string scanner |
| `_`, `A-Z`, `a-z` | `lex_letter` | Greedy span; bucket-by-length keyword match |
| `0-9` | `lex_digit` | See number scanner |
| `.` | `lex_dot` | If next is digit → fall into float; else TK_DOT |
| `(` `)` `[` `]` `{` `}` `,` `:` `;` `~` `@` | one each | TK_LPAREN, etc. — `_lex_punct1` w/ kind |
| `+` `-` `%` `&` `|` `^` | `lex_simple_augass` | `TK_X`, then if next == `=`, `TK_XEQ`. Single shared routine; kind table indexed by char |
| `*` | `lex_star` | `**` → TK_POWER (then `**=` → TK_POWEREQ); `*=` → TK_STAREQ; else TK_STAR |
| `/` | `lex_slash` | `//` → TK_DSLASH (then `//=` → TK_DSLASHEQ); `/=` → TK_SLASHEQ; else TK_SLASH |
| `<` | `lex_less` | `<<` → TK_LSHIFT (then `<<=` → TK_LSHIFTEQ); `<=` → TK_LE; else TK_LT |
| `>` | `lex_greater` | `>>` → TK_RSHIFT (then `>>=` → TK_RSHIFTEQ); `>=` → TK_GE; else TK_GT |
| `=` | `lex_equal` | `==` → TK_EQ; else TK_ASSIGN |
| `!` | `lex_bang` | `!=` → TK_NEQ; else recover |

## Number scanner

Decimal/hex/binary/float distinguished after first 1–2 chars:

```
lex_digit (first char in 0-9):
  if first == '0':
    advance; peek next
    if 'x' or 'X' → lex_hex (consume hex digits)
    if 'b' or 'B' → lex_bin (consume 0/1 digits)
  fall through to integer_loop:
    consume digits while digit
    if peek == '.' or 'e' or 'E' → lex_float
    else: kind = TK_INT, finish

lex_dot (when first char is '.'):
  peek next; if digit → lex_float; else kind = TK_DOT
```

Float FSM (mirrors DCPU lexer2.dasm16:544–618 but with state in 1 byte and
`AND #BIT` / `BNE` instead of DCPU's `IFB`):

```
States (bit values, can OR together for membership tests):
  FP_START         = $01
  FP_DIGIT_WHOLE   = $02
  FP_DECIMAL_POINT = $04
  FP_DIGIT_FRAC    = $08
  FP_E             = $10
  FP_EXP_SIGN      = $20
  FP_EXP_DIGIT     = $40

Transitions on next char:
  digit: stay in current digit-class (whole/frac/exp_digit), or transition
         from {decimal_point→digit_frac}, {e/exp_sign→exp_digit}
  '.':   only valid from {start, digit_whole}; goto decimal_point
  'e','E': only valid from {digit_whole, digit_frac}; goto e
  '+','-': only valid from {e}; goto exp_sign
  other: finish

End validity check: must be in {digit_whole, digit_frac, exp_digit} —
otherwise recover (e.g. "1.e" or "1e+" without trailing digit).
```

Lexer marks kind `TK_FLOAT` only — Stage 8 calls `str_to_float` (which we
already have a slot for, deferred from Stage 6) on the span. **Action
item**: Stage 6 deferred `str_to_float`. We need it for Stage 8, not
Stage 7 — lexer just marks the span. Note in `ARCHITECTURE.md` deferred-
optimizations to upgrade priority before Stage 8.

## String scanner

```
lex_string:
  remember opening quote (LEX_TOKEN_START points to char *after* quote)
  loop:
    advance; read byte
    if byte == 0 or LEX_PTR >= LEX_END: recover (unterminated)
    if byte == LF: recover (no multiline strings — matches DCPU)
    if byte == '\\': handle escape, see below
    if byte == opening_quote: kind = TK_STR; finish (LEX_TOKEN_END = ptr
      to closing quote — i.e. excludes it; cursor advances past it)
```

**Escape handling**: DCPU has no escapes (lexer2.dasm16:526-541 is a raw
loop). We add minimal escapes since the cost is small (~50 bytes) and
useful: `\n`, `\t`, `\\`, `\"`, `\'`, `\0`, `\xNN`. **But** the lexer
doesn't *resolve* escapes — it just validates them and marks the span.
Resolution is in `lexer_get_token_as_string`, which copies the span
through an escape-decoder while building the TYPE_STR.

This keeps the hot path simple: lexer pass = recognize; escape decode
= materialization-time. Cost on lexer side: ~30 bytes (one-byte
look-ahead after `\\`); cost on materialization side: ~80 bytes (copy
loop with escape decode). Net win vs. eager decode: we don't allocate
TYPE_STR for strings the parser never asks to materialize (e.g. dead
code under `if False:`).

## Identifier scanner + keyword lookup

```
lex_letter:
  greedy span: while next char is letter/digit/underscore, advance
  set LEX_TOKEN_END = LEX_PTR
  compute length = LEX_TOKEN_END - LEX_TOKEN_START (8-bit ok up to 255 chars
    — we cap at 8 anyway)
  if length > 8: kind = TK_NAME, finish
  bucket = keyword_bucket_table[length-1]
  walk bucket: for each (chars[len], kind) record:
    if length-byte memcmp matches → kind = that kind, finish
  no match → kind = TK_NAME, finish
```

**Bucket layout**: per-length bucket is a flat run of records, each
record = `length × char_byte` then `kind_byte`. Sentinel `$00` byte
marks end of bucket. (Length is implicit per bucket — we know we're
looking at length-3 keywords, so each record is 3 chars + 1 kind = 4
bytes.)

Two parallel low/high tables index buckets by length:
```
kw_bucket_lo:  .byte <kw1, <kw2, <kw3, ..., <kw8
kw_bucket_hi:  .byte >kw1, >kw2, >kw3, ..., >kw8
```

(Length 1 has no keywords — bucket is just the sentinel.)

Estimated bucket-data size (chars + kind per record + sentinel per
bucket): ~115 bytes total.

## Indent / dedent

Two counters, no stack. Matches DCPU exactly.

```
lexer_next entry:
  if INDENT_CURRENT > INDENT_TARGET:
    decrement INDENT_CURRENT; emit TK_DEDENT; return
  if INDENT_CURRENT < INDENT_TARGET:
    increment INDENT_CURRENT; emit TK_INDENT; return
  ; counters match — fall through to normal scan
  skip_whitespace; dispatch
```

Newline handler scans the next line's leading spaces:

```
lex_newline:
  emit TK_NEWLINE this call (span = the LF byte)
  advance; count leading spaces into a local
  peek next char:
    if LF       → newline-restart (blank line; ignore the space count)
    if '#'      → skip to EOL, newline-restart
    if NUL/EOF  → don't change INDENT_TARGET; force = 0 on EOF anyway
    else        → set INDENT_TARGET = local
  finish (cursor sits at the first non-space, non-comment char of next line)
```

EOF (NUL) handler: `INDENT_TARGET = 0`, kind = TK_EOF. The next several
calls drain DEDENTs until counters match, then EOF is emitted thereafter.

Tabs: not supported (matches DCPU). A `\t` byte hits `lex_recover`.

## API surface

Public V4' routines:

| Name | Args | Returns | Notes |
|---|---|---|---|
| `lexer_init` | source handle on RS | — | Deref handle, set LEX_PTR/LEX_END, zero indent counters, advance to first token |
| `lexer_advance` | A = expected kind | — | Compare A to LEX_TOKEN_KIND; mismatch → `recover`. Then `lexer_next`. |
| `lexer_next` | — | — | Scan next token into LEX_TOKEN_KIND/START/END |
| `lexer_save` | — | RV = checkpoint handle | Bundle (LEX_*) state into a 13-byte TYPE_DATA blob |
| `lexer_restore` | checkpoint handle on RS | — | Unpack and write back |
| `lexer_get_token_as_string` | — | RV = TYPE_STR handle | Allocate TYPE_STR, copy LEX_TOKEN_START..LEX_TOKEN_END through escape decoder for TK_STR (raw copy for TK_NAME / TK_INT / TK_HEX / TK_FLOAT) |

`lexer_save` uses TYPE_DATA — but we deferred TYPE_DATA in Stage 5d.
**Workaround**: until TYPE_DATA lands, lexer_save returns a small TYPE_STR
(13 bytes). Functionally identical for our needs (opaque blob), and
straightforward to migrate.

Re-derefs after allocation: `lexer_get_token_as_string` allocates a
TYPE_STR, which can trigger GC, which compacts payload pointers. After
the allocation, we re-deref `LEX_SRC_HANDLE` and rebuild `LEX_PTR` /
`LEX_END` / `LEX_TOKEN_*` from saved offsets. **Mechanism**: at start of
`lexer_get_token_as_string`, save the four pointers as offsets-from-
payload-base; after the `str_alloc` that may relocate, recompute
absolute pointers from the (possibly moved) payload base. Cost: ~30
bytes.

## Files

- `src/lexer.asm` — main file. ~600–700 lines of source, all of Stage 7.
- `src/defs.asm` — additions: ZP cells, TK_* constants, char-class
  dispatch tables (or those go in lexer.asm — decide while implementing).
- `src/admiral.asm` — add `#import "lexer.asm"`.
- `tests/test_lexer.py` — ~80 tests, see surface below.

## Test surface

Group A — char dispatch:
- Each punctuation char emits the right TK_*.
- Illegal chars (`?`, `\\`, NUL beyond EOF) → recover panic.

Group B — multi-char operators:
- `+`, `+=`, `-`, `-=`, `*`, `**`, `**=`, `*=`, `/`, `//`, `//=`, `/=`,
  `%`, `%=`, `&`, `&=`, `|`, `|=`, `^`, `^=`, `<`, `<<`, `<<=`, `<=`,
  `>`, `>>`, `>>=`, `>=`, `=`, `==`, `!=`. Plus `~`. (32 cases.)

Group C — numbers:
- Decimal: `0`, `1`, `1234`, `4294967296` (longer than 32 bits).
- Hex: `0x0`, `0xff`, `0xFF`, `0xDeadBeef`.
- Bin: `0b0`, `0b101`, `0b1111111111111111`.
- Float: `1.0`, `1.`, `.5`, `1e5`, `1e+5`, `1e-5`, `1.5e2`, `1.5e+2`.
- Float errors: `1.e`, `1e+`, `1.2.3` (this last lexes as `1.2` + `.3`).

Group D — strings:
- Empty `""`. ASCII `"hello"`. Single-quote `'a'`. Mixed quotes
  `"it's"`, `'a"b'`. Escapes `"\n"`, `"\t"`, `"\\"`, `"\""`,
  `"\xff"`, `"\0"`. Unterminated → recover. LF inside → recover.

Group E — identifiers + keywords:
- All 23 keywords (`if`, `elif`, …, `none`) emit their TK_*.
- Near-misses: `iff`, `els`, `else_`, `_while`, `whilex` → all TK_NAME.
- Length-9+ identifiers: `breakable`, `whileness` → TK_NAME (skip
  bucket entirely).
- Identifier with underscore + digit: `foo_bar_3`, `_x`, `_`.

Group F — indent / dedent:
- Single block: `if x:\n    y` → IF NAME COLON NEWLINE INDENT NAME …
- Two-level: `if x:\n    if y:\n        z` → INDENT INDENT
- Pop two: `if x:\n    if y:\n        z\nq` → DEDENT DEDENT NEWLINE NAME
- Blank line inside block: `if x:\n    y\n\n    z` (no DEDENT/INDENT
  bursts; blank line is invisible to indent state).
- Comment-only line: `if x:\n    y\n    # c\n    z` (same — invisible).
- EOF flush: `if x:\n    y` (with no trailing newline) → final EOF
  drains DEDENTs.

Group G — save / restore:
- Lex three tokens; save; lex two more; restore; lex one — the lexed
  token after restore must equal what would have come third.
- Save inside an indented block; restore after walking past EOF; the
  restored state must continue to emit DEDENTs correctly.

Group H — `lexer_get_token_as_string`:
- TK_NAME `foo` → TYPE_STR `"foo"`.
- TK_INT `123` → TYPE_STR `"123"`.
- TK_STR `"a\nb"` → TYPE_STR with bytes `'a' $0A 'b'` (3 bytes).
- TK_STR with `\xff` escape → TYPE_STR with byte $ff.
- Allocation triggers GC: surround with junk allocations to force
  compact, then materialize. Span pointers must rebase correctly.

## Estimated size

| Component | Bytes |
|---|---|
| ZP cells | 0 (in partition; just label allocation) |
| Char dispatch table (lo+hi 128) | 256 |
| Per-char handlers (40 small + 6 medium) | ~900 |
| Number scanner (digit + hex + bin + float FSM) | ~500 |
| String scanner + escape validator | ~150 |
| Identifier scanner + keyword match | ~150 |
| Keyword bucket data | ~120 |
| Keyword bucket pointer tables (lo+hi 8) | 16 |
| Newline + indent state machine | ~250 |
| Save / restore | ~120 |
| Get-token-as-string + escape decoder | ~150 |
| **Total estimate** | **~2.6 KB** |

In line with the high-level plan's 2.5–3 KB estimate.

## Open issues

- `lexer_save`/`lexer_restore` use TYPE_DATA in DCPU; we substitute
  TYPE_STR until Stage 5d lands. Note in deferred-optimizations.
- `str_to_float` was deferred at Stage 6. It's needed by Stage 8 for
  TK_FLOAT literals. Promote in `ARCHITECTURE.md`'s deferred section.
- Tab character: silently mapped to recover. If real `code/*.admiral`
  files use tabs we'll need a tab→spaces normalization pass on load —
  not now.
- CR handling: DCPU treats `$11` (DC1 / XON) as newline (lexer2 line
  494). Likely terminal artifact. We map LF *and* CR to newline; CRLF
  is detected by "newline followed immediately by another newline" and
  collapsed in the blank-line loop.
