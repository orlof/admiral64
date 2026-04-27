# Admiral C64 — feature-parity roadmap

Bring every user-facing DCPU Admiral feature to the C64 port: REPL, Python-ish
language, gap-buffer editor, disk filesystem with object-graph save/load,
hi-res graphics, crypto/PRNG. Same semantics, different hardware substrate
(KERNAL + 1541 + VIC-II + SID instead of LEM1802 + M35FD + Generic Keyboard).

> **What lives in this document.** Stage-level feature progress: what's done, what's next, and the rationale for stage ordering. Read this when you want to know *what to ship next*.
>
> **What lives elsewhere:**
> - **`ARCHITECTURE.md`** — how the codebase is built (ZP layout, ABI, GC) and code-level *deferred optimizations* (small polish items tied to specific routines).
> - **`PLANS/stage*.md`** — implementation plans for in-flight or recently-completed stages.
>
> Rule of thumb: a feature ("port the lexer") goes here. A code-quality follow-up ("merge the two unpack helpers, save 30 bytes") goes in `ARCHITECTURE.md`'s *Deferred optimizations* section, not here.

**Non-goals**: KaiComm HIC/RCI (no C64 analog — leave stubbed), DCPU
bit-exactness (semantics, not byte counts), DCPU's hardware detection
ceremony (C64 is fixed).

**Constraint**: 64 KB RAM total, ~30 KB for code + heap after KERNAL mapping.
Realistically Admiral C64 fits in ~24 KB if disciplined and willing to defer
hi-res / SID. Watch code size from Stage 8 onward.

---

## Status

| Stage | Status | Tests | Notes |
|---|---|---|---|
| 1. Foundation (memory map, stacks, ABI, allocator, GC) | ✅ done | — | |
| 2. Numbers + strings (TYPE_INT, arithmetic, TYPE_STR, int_to_str) | ✅ done | — | |
| 3. Hardware (screen, keyboard, print, boot banner) | ✅ done | — | py65 + VICE |
| 4. val_eq + TYPE_BOOL + TYPE_NONE singletons | ✅ done | +21 | |
| 5a. TYPE_TUPLE + tri-color GC tracing | ✅ done | +25 | |
| 5b. TYPE_LIST + grow + heap_carve_payload | ✅ done | +18 | |
| 5c. TYPE_DICT + val_cmp + array.asm refactor | ✅ done | +39 | sorted-array, binary search |
| 5d. TYPE_ARRAY (typed buffers) + TYPE_DATA (opaque bytes) | ⏸ deferred | — | Add when disk I/O demands it |
| 6. Float (BASIC ROM-backed, 5-byte MS-Basic format) | ✅ done | +116 | str_to_float deferred; INT/FLOAT promotion deferred. See PLANS/stage6-float.md |
| 7. Lexer | ✅ done | +134 | Span-not-value tokens, level-based indent stack, length-bucketed keyword match. lexer_save/restore + lexer_get_token_as_string deferred to Stage 8. See PLANS/stage7-lexer.md |
| 8. Parser-evaluator (combined) | ✅ expression-level done | +226 | Pratt + all literals + all operators (arithmetic, comparison, boolean, identity, bitwise, shifts), parens, indexing, mixed int/float arith, square-and-multiply pow. Statement-level dispatch lives in Stage 9. |
| 9. Runtime support | ✅ 9a + 9b + 9c (functions) | +63 | Scopes, all control flow (if/elif/else/while/for/break/continue/pass), `return`. **String-as-function (Admiral pattern)**: TYPE_STR is callable via `led_lparen`'s TYPE_STR arm — body re-lexed in fresh scope, kwargs bound, CTRL_RETURN extracted. `add = "return a + b"; add(a=1, b=2)` works. Pending: positional args / `argv`, parent scope chain, exceptions. |
| 10. Built-ins | 🟡 print + len + range | +27 | `print expr` (statement-level). `len(x)` for str/list/tuple/dict, `range(n)` returns a list (Py2-style), via TYPE_BUILTIN handles bound in global_scope at `parser_eval` start + `led_lparen` LED for call syntax. Pending: `type`, `str`, `int`, `input`, `abs`, etc. |
| 11. REPL + line editor (input, history, blink) | ⏸ pending | — | First "running language" milestone |
| 12. Gap-buffer editor (`edit()`) | ⏸ pending | — | |
| 13. Disk + object-graph serialization | ⏸ pending | — | KERNAL 1541; save/load |
| 14. Hi-res graphics (bank 3 migration) | ⏸ pending | — | Optional; 4 KB cost |
| 15. Crypt + PRNG (LFSR + Hummingbird-2) | ⏸ pending | — | |
| 16. SID sound | ⏸ pending | — | Optional |
| 17. Polish (custom IRQ, .d64 image, cold-start) | ⏸ pending | — | |

**Current**: 1010/1010 tests, ~18.6 KB binary. **Full Admiral prototyping**: dicts ARE objects, methods are strings, `obj.method(args)` binds `me = obj`, `me.x = v` mutates the receiver. A bank-account object with deposit/withdraw runs end-to-end. Pending: positional args, multi-line `{...}` literals, `try`/`except`, more built-ins, REPL.

---

## Critical-path order

```
Stage 4 ──┐
          ├─→ 5a → 5b → 5c (containers) ──→ 7 (lexer) ──→ 8 (parser) ──→ 9 (eval) ──→ 10 (builtins) ──→ 11 (REPL)
Stage 6 ──┘                                                                                                  │
                                                                                                             ▼
                                                                                          12 (editor) ←──────┤
                                                                                          13 (disk)   ←──────┤
                                                                                          14 (hires)  ←──────┤
                                                                                          15 (crypt)  ←──────┘
                                                                                          16 (SID, optional)
                                                                                          17 (polish)
                                                                                          5d (deferred)
```

- **4 → 5 → 7→8→9→10→11** is the critical path to a usable Admiral. Anything else is dead until you can type `2+2` and see `4`.
- **6 (float)** can run in parallel with 7 (lexer). Both feed 8.
- **12, 13, 14, 15** are independent post-REPL.

---

## Stage details (pending stages only)

### Stage 5d — TYPE_ARRAY + TYPE_DATA *(deferred)*

- **TYPE_ARRAY**: typed fixed-width numeric buffer (`array_int8`, `array_int16`, `array_byte`). Payload is N raw values of one element-size, NOT handles. No handle-per-element overhead.
- **TYPE_DATA**: opaque byte buffer; same shape as TYPE_STR but distinct tag for binary blobs.

Both are leaf types — no GC tracing of children, no recursive val_eq. ~100 lines combined. Skipping until something demands it (likely disk I/O at Stage 13).

### Stage 6 — Float

5-byte MS-Basic float (C64 native: 8-bit exp + 32-bit hidden-bit mantissa). Wrap BASIC ROM FP routines: FADD/FSUB/FMUL/FDIV, comparison, `int_to_float`, `float_to_int`, `float_to_str`, `str_to_float`. Transcendentals (sin/cos/sqrt/exp/log/atn) **come for free** from BASIC ROM — wire them when the parser exposes `import math`.

**Decision recorded:** use BASIC ROM, drop Admiral float compatibility. Save/load artifacts will not round-trip with DCPU Admiral. See `c64/PLANS/stage6-float.md` for details.

### Stage 7 — Lexer

Port `lexer2.dasm16`. Token stream from a TYPE_STR source. Tokens: numbers (int/float/hex/oct/bin), strings with escapes, identifiers, keywords, operators, punctuation, indent/dedent, newline. Significant indentation → emit synthetic INDENT/DEDENT tokens. Output: TYPE_LIST of TYPE_TUPLE(kind, value, line, col).

### Stage 8 — Parser *(largest stage)*

Pratt expression parser + statement parser, one-pass. Output: recursive TYPE_TUPLE AST. Handles literals, identifiers, calls, attribute access, indexing, slicing, all unary/binary/logical/bitwise/comparison ops, `if/elif/else`, `while`, `for…in`, `def`, `class`, `return`, `break`, `continue`, `try/except/finally`, assignment + augmented, multiple assignment.

**Open question**: keep `class` and comprehensions, or trim to a Python subset? Cutting saves ~30%. **Recommend**: keep classes, defer comprehensions.

### Stage 9 — Interpreter *(second-largest)*

Tree-walking evaluator. Scopes are dicts (`global_scope`, `current_scope`). Functions are first-class (closures). Exception machinery via `try_fp/try_sp` checkpoints saved into RS. Control flow uses `RV` sentinels (`CTRL_RETURN`, `CTRL_BREAK`, `CTRL_CONTINUE`). Calls via V4': caller pushes args, dispatcher builds new scope, binds params, recursively evals body.

### Stage 10 — Built-ins

`print`, `input`, `len`, `range`, `type`, `str`, `int`, `float`, `list`, `dict`, `tuple`, `bool`, `abs`, `min`, `max`, `sum`, `ord`, `chr`, `hex`, `oct`, `bin`, `sorted`, `reversed`, `enumerate`, `zip`, `map`, `filter`, `isinstance`. Plus C64 replacements for DCPU hw bridge: `peek`, `poke`, `sys` (call 6502 routine; replaces DCPU `call`/`hwi`).

### Stage 11 — REPL + line editor

`input()` — line editor with cursor movement, backspace, history scroll. REPL loop: prompt → read → lex → parse → eval → display. Tracebacks on uncaught exceptions. Cursor blink belongs here (raster IRQ at frame ~250 toggles `$0400+offset` between `$A0` and underlying char). Replaces the static `screen_show_cursor`.

### Stage 12 — Gap-buffer editor

Port `edit2.dasm16`. Backing: heap-allocated TYPE_DATA. Cursor model: line/col + gap position. Movement, insert/delete, save/load, status line, simple search. Entry point `edit(path)` from the language. C64 specifics: cursor keys, RUN/STOP, F-keys, color line.

### Stage 13 — Disk + object-graph serialization

KERNAL wrappers (SETLFS/SETNAM/OPEN/CHKIN/CHKOUT/CHRIN/CHROUT/CLRCHN/CLOSE/READST). `dir()`, `read_file(path)`, `write_file(path, data)`.

Object-graph serialization is the heavy lift. Two-pass:
1. **Mark**: DFS from root, assign each reachable handle a sequential ID, dedup via existing `FLAG_MARKED`.
2. **Emit**: write manifest of `(id, type, len, payload-with-handle-refs-replaced-by-ids)`. References inside payloads written as `(REF, id)` entries.

`load` reverses: read manifest, materialize handles in order, fix up references in second pass.

### Stage 14 — Hi-res graphics

Bank 3 migration: screen → `$C000`, charset copied to `$C800`, bitmap at `$E000` "under" KERNAL ROM (VIC sees RAM, CPU sees ROM). 4 KB cost. Then port `hires.dasm16`: line, rect, fill, blit, pixel get/set, mode switch. Sprite layer is C64-gain (Admiral has no DCPU equivalent).

### Stage 15 — Crypt + PRNG

LFSR (~30 LOC). Hummingbird-2 (~200 LOC mechanical port from `crypt.dasm16`). Matters for serialization integrity at Stage 13.

### Stage 16 — SID sound *(optional)*

Admiral has Speaker via generic device. C64 SID is more capable but the parity surface is "tone, frequency, duration, voice." Can ship without.

### Stage 17 — Polish

Bundle `admiral.prg` + sample programs onto a `.d64`. Custom IRQ for cursor blink + jiffy. Clean cold-start path that survives `RUN` after a previous session.

---

## Risks & unknowns

- **Code size.** Admiral is ~30 KB of DCPU-16 (16-bit instructions). 6502 is denser per opcode but ~2× the code for the same logic. Realistic fit: ~24 KB only if disciplined and willing to defer hi-res / SID. Measure each module's output size from Stage 8 onward.
- **Parser correctness.** Admiral's parser is the only spec for the language. Plan: treat the existing Admiral REPL as a black-box oracle — feed identical strings to both, diff outputs, until they match for a curated test corpus.
- **Float exactness.** Resolved (Stage 6): use BASIC ROM's 5-byte MS-Basic format. `save` artifacts will *not* round-trip with DCPU Admiral — accepted because (a) nobody is moving disk images between platforms, and (b) BASIC ROM gives us transcendentals (sin/cos/sqrt/log/exp) for ~0 bytes of our own code.
- **GC churn during eval.** Tree-walking interpreters allocate a *lot*. May need `gc_collect` at every statement boundary. Worth measuring once Stage 9 is up.

---

## Test strategy

py65 stays the workhorse. Each stage adds `tests/test_<module>.py`. End-to-end Admiral programs become possible at Stage 11 — add `tests/programs/*.admiral` with expected stdout, run them through a `repl_runner` fixture. VICE stays the manual smoke check after each visible-output stage (11, 12, 14).
