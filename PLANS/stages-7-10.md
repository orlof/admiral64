// -----------------------------------------------------------------------------
// Stages 7–10 — high-level plan: lexer → parser-evaluator → runtime → built-ins.
// Written before lexer deep-dive; commits the architecture so all four stages
// are designed against the same model.
// -----------------------------------------------------------------------------

# Stages 7–10 — Lexer, Parser-Evaluator, Runtime support, Built-ins

## Headline finding — the ROADMAP is partly wrong

**DCPU Admiral has no AST and no separate evaluator.** The Pratt "parser" is
the interpreter: NUDs and LEDs evaluate as they consume tokens and return
*value* handles, not syntax-node handles (parser.dasm16:850–880, 952–966,
1590–1622). Loops re-parse their body each iteration via `lexer_store` /
`lexer_restore` (parser.dasm16:473–502, 685–719). Function calls re-lex the
function's source-string body (parser.dasm16:2122).

ROADMAP currently says "Stage 8: Parser → AST" and "Stage 9: Tree-walking
evaluator." That's two stages of a model the reference implementation doesn't
use. **Merge them into one Stage 8 (parser-evaluator).** The thing we used to
call Stage 9 is actually *runtime support*: scope dicts, control sentinels,
exception machinery, function-call dispatch. Smaller and largely independent.

This is not a stylistic preference — it's what makes the byte budget work.
Building an AST first and walking it second roughly doubles the working set
(every literal becomes a node *and* a value) and adds a whole node-type system
we don't have.

Also confirmed: **no `def`, no `class`, no `lambda`, no comprehensions** in
DCPU Admiral. Functions are dict objects loaded from disk and invoked via
`()`. We adopt the same scope.

## Decisions (committed)

1. **No AST.** Pratt NUDs/LEDs evaluate immediately, return value handles.
2. **No `def` / `class` / `lambda` / comprehensions** in Stage 8. Functions
   live as `TYPE_STR` or `TYPE_DICT` callables, invoked via `()` (Stage 8) and
   `run` (Stage 10). Revisit only if real workloads demand it.
3. **Pratt dispatch via 4 parallel tables**, indexed by a small token-kind id
   (one byte): `STD_LO/HI`, `NUD_LO/HI`, `LED_LO/HI`, `LBP`. Small token-id +
   parallel low/high tables is the 6502-idiomatic shape (`lda LO,x; sta vec;
   lda HI,x; sta vec+1; jmp (vec)`). DCPU's "token id is a pointer to its
   record" trick doesn't carry; the parallel-table form is cheaper on 6502.
4. **Lexer streams; tokens are spans.** One-token-at-a-time pull model; token
   kind + start/end source indices live in ZP. No allocation on the hot path.
5. **Control flow via `TYPE_CONTROL` handles** (matches DCPU), but use a
   **singleton pool**: pre-allocated `CTRL_BREAK`, `CTRL_CONTINUE` (immutable);
   one mutable `CTRL_RETURN` whose value-slot is rewritten per return. Saves
   the per-control-flow alloc DCPU does (parser.dasm16:367–424).
6. **Scopes are dicts with `_` parent link** (matches DCPU). Reuse existing
   `TYPE_DICT`. Function call → new dict scope; `_` → global_scope (no
   closures, matching DCPU Admiral parser.dasm16:2024).
7. **Exception machinery** = saved (FP, RSP, lexer cursor) checkpoint pushed
   on a try-stack; `raise` restores and re-tokenizes to find `except`. Mirrors
   DCPU `try_fp`/`try_sp` (parser.dasm16:568–601, 295–347).
8. **GC trigger** lowered from "every 256 allocs" (DCPU) to **~32–64** for our
   ~14 KB heap. Concrete number once Stage 8 measures real churn.

## Stage breakdown

### Stage 7 — Lexer

**Purpose:** Convert source bytes → token stream. One current token in ZP
globals, parser pulls via `lexer_advance`.

**Structure:**
- ZP cells: `LEX_SRC` (handle), `LEX_POS`, `LEX_END_POS`, `LEX_TOKEN_KIND`,
  `LEX_TOKEN_START`, `LEX_TOKEN_END`, `LEX_INDENT_TARGET`, `LEX_INDENT_CURRENT`.
- 128-entry character-class table indexed by current char → 1-byte handler id.
  Either dispatch via `jmp (vec)` (one indirect per char) or a switch on the
  class id. Pick after measuring; both work. (DCPU lexer2.dasm16:138 uses raw
  function pointer in table; 6502 prefers small ids.)
- Per-handler routines: digit, letter, quote, dot, slash (comment vs op),
  punctuation (operators), whitespace, newline, EOF.
- Number scanner: int (decimal/hex/`0x`/`0b`), float (digits with `.` or `e`).
  Lexer marks the kind only; parser does the conversion. Decimal int delegates
  to `int_parse_string` (Stage 2 already has the digit→bigint path).
- Float FSM matches DCPU's bitfield states (lexer2.dasm16:544–618), but on
  6502 the state is a single byte and tests are `lda state; and #BIT; bne`.
- String literal scanner: pass-through bytes between `"`/`'`; minimal escape
  handling (`\n`, `\t`, `\\`, `\"`, `\'`, `\0`, `\xNN`). Materializes a
  `TYPE_STR` only when parser asks (`lexer_get_token_as_string`).
- Identifier scanner: greedy span; length-bucketed keyword match. Hard cap
  at 8 chars ⇒ skip lookup if longer (matches DCPU lexer2.dasm16:501).
- Indent: two counters (target/current) + synthetic INDENT/DEDENT emission on
  next-token call. EOF forces target=0 to drain open blocks.

**Estimated size:** **2.5–3 KB**.
- Char dispatch table: 128 bytes
- Keyword tables (length-bucketed): ~200 bytes
- Per-handler routines: ~1.5 KB
- Number/string/identifier scanners: ~600 bytes
- Indent state machine: ~150 bytes

**Test surface:** ~80 tests. Char-class boundaries, keyword vs identifier,
all integer bases, float FSM corners (`1.`, `.5`, `1e5`, `1.5e-3`), string
escapes, indent/dedent (mixed depths, EOF flush), unterminated string panic,
comment skip, blank-line skip.

### Stage 8 — Parser-evaluator (replaces previous Stage 8 + Stage 9)

**Purpose:** Read the lexer token stream and *execute the program* via Pratt
operator precedence. No AST is built.

**Structure:**
- 4 parallel tables × ~50 token kinds: `STD_LO`, `STD_HI`, `NUD_LO`, `NUD_HI`,
  `LED_LO`, `LED_HI`, `LBP` (1 byte each entry, LBP fits in a byte). Total
  table size: ~7 × 50 = 350 bytes.
- `parser_stmt` = `lda LEX_TOKEN_KIND; tax; jmp (STD_LO,x indirect)`. Same
  shape for `expression` driving NUD then LED loop.
- Each NUD/LED returns its value via `RV` (handle). The `expression` driver
  pushes intermediate values to `RS` between LED calls so they survive a GC
  triggered by the next allocation.
- Operator handlers reuse Stage 5 / Stage 6 work directly:
  `int_add`, `float_add`, `int_cmp`, `val_cmp`, `array_merge`, etc.
- Type dispatch in arithmetic: `lda lhs_type; ora rhs_type; cmp #...;
  beq int_path / float_path / str_path`. Matches DCPU's "OR-and-test"
  (parser.dasm16:1601–1622).
- Augmented-assign (`+=`, `-=`, …) rewrites to `lvalue = lvalue OP rvalue`
  via a tiny trampoline that calls the matching `_operation` helper directly
  (parser.dasm16:1908–2002). One trampoline + 9 single-byte `op_id` entries.
- Loops use `lexer_save` / `lexer_restore`: save (LEX_POS, indent state,
  token kind), parse-execute body, restore, advance the iterator, repeat.
- Statements: `if`/`elif`/`else`, `while`, `for…in`, `return`, `break`,
  `continue`, `pass`, `try`/`except`/`finally`, `raise`, `del`, expression-
  as-statement. **Plus** simple assignment via `=` (target detected from LHS:
  name → scope_set; subscription → array_set; reference → attr_set).

**Estimated size:** **5–6 KB**.
- Pratt driver + dispatch tables: ~700 bytes
- Operator NUD/LED routines (16 binary ops, 5 unary, 6 comparisons, 2 logical):
  ~1.6 KB
- Statement handlers (if/while/for/try/return/break/continue/pass/raise/del):
  ~1.3 KB
- Suite parser + skip-suite (indent counter): ~300 bytes
- Container literals (`{}`, `[]`, `()`, slice, attr): ~600 bytes
- Function-call dispatch (`led_lparen`): ~600 bytes
- Assignment (target classifier + 3 store paths): ~400 bytes

**Test surface:** ~120 tests. Each operator's type-combinations; precedence
chains (`a+b*c`); all statement forms; nested loops with break/continue;
try/except with raise; function call with positional+kw args; deep recursion
(stack-overflow detection); multiple assignment.

### Stage 9 — Runtime support

**Purpose:** What was previously labeled "interpreter." It's the support
layer Stage 8 calls into.

**Pieces:**
- `scope_get` / `scope_set` — dict-walk via `_` parent chain
  (stdlib.dasm16:5–103). ~150 bytes.
- `eval_name` / `eval_subscription` / `eval_reference` — for the few cases
  Stage 8 defers (lvalue resolution, late binding). ~250 bytes.
- Control sentinels: `CTRL_BREAK` / `CTRL_CONTINUE` static handles;
  `CTRL_RETURN` mutable singleton with a value slot. `is_control(handle)` =
  type-tag check. ~80 bytes.
- Exception checkpoint stack: per-try push (FP, RSP, lexer cursor) onto FS;
  `raise` pops + restores. ~250 bytes.
- Function-call dispatcher (called by `led_lparen`): allocate scope dict, set
  parent to global_scope, bind args into scope, swap lexer to function body
  string, run `parser_stmt` loop until EOF or CTRL_RETURN, restore lexer.
  ~500 bytes.
- `traceback` skeleton — line/col from lexer cursor when an unhandled
  exception escapes the REPL loop. ~150 bytes.

**Estimated size:** **1.5–2 KB**.

**Test surface:** ~40 tests. Scope chain lookup, scope shadow, function
recursion + return value, exception unwind across call frames,
break-out-of-nested-loops.

### Stage 10 — Built-ins

**Purpose:** Standard library exposed to user code.

**Structure (matches DCPU stdlib.dasm16:1165 length-bucketed match):**
- 7 × 1 length tables of `(len, name_chars..., impl_ptr)`.
- `built_in_dispatch(name_handle)` walks the right bucket; falls through to
  user-function path if no match.

**Inventory:** `print`, `input`, `len`, `range`, `type`, `str`, `int`,
`float`, `list`, `dict`, `tuple`, `bool`, `abs`, `min`, `max`, `sum`, `ord`,
`chr`, `hex`, `oct`, `bin`, `sorted`, `reversed`, `enumerate`, `zip`, `map`,
`filter`, `isinstance`. C64 hardware bridge: `peek`, `poke`, `sys` (replaces
DCPU `call`/`hwi`).

**Transcendentals (`math.sin`, `math.cos`, …)** wire to BASIC ROM via the
same bank-flip macro Stage 6 already uses. ~25 bytes per function.

**Estimated size:** **3–4 KB**.
- Dispatch table + matcher: ~250 bytes (matcher already exists for keywords)
- Each built-in: 30–200 bytes; 28 functions × ~80 average = ~2.2 KB
- Math wrappers (8 transcendentals): ~250 bytes
- C64 hw bridge: ~150 bytes

**Test surface:** ~80 tests, one or two per built-in, plus integration via
short Admiral programs once Stage 11 (REPL) lands.

## Total byte budget

| Stage | Estimate |
|---|---|
| Through Stage 6 (current) | ~7.5 KB |
| Stage 7 (lexer) | +2.5–3 KB |
| Stage 8 (parser-evaluator) | +5–6 KB |
| Stage 9 (runtime) | +1.5–2 KB |
| Stage 10 (built-ins) | +3–4 KB |
| **Through Stage 10** | **~19.5–22.5 KB** |
| Remaining for 11–17 | ~1.5–4.5 KB |

If Stage 8/10 come in high, hi-res (Stage 14) and SID (Stage 16) are first
to defer — they're already marked optional. Editor (Stage 12) is the one
non-optional post-REPL stage that's bulky; gap-buffer is dense, ~1.5 KB on
6502 plausible.

## Heap-pressure plan

Tree-walking interpreters churn allocations. DCPU's mitigations
(GC every 256, no-closure scope discipline, stack-allocated args) we adopt
wholesale. **Additionally:**

1. **Control-sentinel singletons** (decision 5 above) — eliminates the
   per-`return`/`break`/`continue` alloc. Net: 1 alloc per call, not N.
2. **Smaller GC trigger** — DCPU's 256 on a 28 KB heap is ~9 KB-of-allocs
   between GCs; we want similar absolute slack on a 14 KB heap, so trigger
   every ~64 allocs.
3. **Builtin fast path** for arithmetic — `int_add` / `float_add` etc. are
   already shaped to allocate result in-place via the bump allocator, no
   intermediate boxing.
4. **`argv` tuple avoidance for built-ins** — DCPU's `built_in_params`
   (builtin.dasm16:1736) extracts args directly from the call site without
   constructing a tuple. We do the same.

If after Stage 8 we measure heap churn that triggers GC inside expressions
(GC during operator evaluation = correctness risk for un-rooted intermediates),
we tighten the rooting story before adding more features.

## Risks

1. **The "no AST" model is unfamiliar.** Standard interpreter texts assume
   AST + tree walk. Reviewing parser.dasm16 once more before coding stage 8
   is cheaper than discovering a missing case at byte 4000.
2. **Re-parse loops** for `for`/`while` mean the lexer cursor must be
   bit-exact restorable. Indent state, current token kind, source position —
   all must be captured. One off-by-one in `lexer_restore` and a loop body's
   first iteration parses differently from later ones. Extensive lexer-
   restore tests in Stage 7.
3. **Function call cost.** Each call: alloc scope dict (~12 words) + alloc
   argv tuple (varies) + bind args + parse body. A 1000-call program is
   ~25 KB of churn, multiple GCs. May need empirical re-tuning of GC
   trigger. Trace allocation count in tests.
4. **Code-size overruns.** Estimates assume DCPU→6502 ~2× factor. If parser-
   evaluator comes in at 7+ KB, drop comprehensions (already deferred) and
   consider trimming operator precedence levels (DCPU has 16; collapsing to
   8–10 saves table entries and ~200 bytes).
5. **No def/class deviation from typical Python.** Users expect `def`. The
   workaround (functions as files invoked via `run`) needs documentation
   when REPL ships.

## Resolved scope (locked)

- **`def` / `class` / `lambda` / comprehensions** — **dropped.** Match DCPU.
  Functions live as dict objects loaded from disk and called via `()`.
- **Read-slicing `a[start:stop]`** (and the open-ended forms `a[:n]`,
  `a[n:]`) — **in scope** for Stage 8. Inherits from DCPU `led_lbrack`
  (parser.dasm16:2164–2276).
- **Slice step `a[::n]`** — **deferred.** Adds parse branch + strided copy +
  reverse handling, ~150–250 bytes. Not worth it now.
- **Slice assignment `a[2:5] = [...]`** — **deferred.** Needs payload
  realloc + tail shift, ~200 bytes plus edge cases. Stage 8 builds the
  `TYPE_SUBSCRIPTION` handle with start/stop already, so this is a purely
  additive feature later (new arm in the assign dispatcher).
- **`global` / `nonlocal`** — not added. `scope_set` walks the parent chain
  to find an existing binding; matches DCPU.
- **Error reporting** — panic on first syntax error. Matches DCPU.

## Implementation order

Standard critical path (one stage at a time, testable in isolation):

1. **Stage 7 lexer**, ~80 tests. py65-only. Done when full keyword/operator
   coverage and indent/dedent are right.
2. **Stage 8a parser-evaluator core**: literals, names, arithmetic,
   comparison, boolean ops, container literals, indexing, attribute access.
   No control flow yet. Tests: feed expressions, inspect resulting handles.
3. **Stage 8b control flow**: `if`, `while`, `for`, `break`, `continue`,
   `pass`. Plus suite parser. Tests with multi-line programs.
4. **Stage 9 runtime**: scopes, function-call dispatcher, exceptions.
5. **Stage 8c functions + try/except**: now we have the runtime, finish
   `led_lparen`, `std_try`/`std_raise`, `std_return`.
6. **Stage 10 built-ins**: minimal set first (`print`, `len`, `range`, `int`,
   `str`, `type`); rest as needed.

After Stage 10 we can run end-to-end Admiral programs in py65. Stage 11
(REPL) makes it interactive.

## Doc updates this plan implies

- **ROADMAP.md**: relabel Stage 8 as "Parser-evaluator (combined)", relabel
  Stage 9 as "Runtime support (scopes, control sentinels, exceptions,
  function-call dispatch)". Update Stage 10 inventory if `def`/`class` are
  formally dropped. Update "Largest single module" annotation.
- **ARCHITECTURE.md**: once Stage 7/8 land, add a new section explaining the
  parser-IS-evaluator model, the 4-parallel-table dispatch, and the
  control-sentinel singleton scheme. Don't add now — wait until the code
  exists to reference.
