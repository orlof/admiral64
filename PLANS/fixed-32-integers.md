# Fixed 32-bit integers (inline in handle)

Replace Admiral's variable-length signed integers with fixed 32-bit two's-
complement integers stored **inline in the handle** — no separate heap object.

## Motivation

- Collapse ~1,800 lines of variable-length int code (`src/int_*.asm`) to
  ~600-800 lines of fixed-width straight-line code → ~800-1,400 bytes of PRG
  reclaimed (PRG currently sits a hair under `$8000`).
- Eliminate the per-int heap allocation: every arithmetic result fits in the
  8-byte handle, so no `NEXT_DATA` carve, no int payload for GC to sweep/move.
- Make the payload-pointer extension ABI exact: "an int arg is the 4 bytes at
  the handle" with no length to carry (see `call-and-assembler.md`).

## Confirmed semantics (user decision)

- **Range: -2³¹ .. 2³¹-1**, two's-complement. Arbitrary precision is gone
  (deliberate regression).
- **Arithmetic overflow (`+ - * ** <<`): wraps mod 2³²** — no trap. Smallest /
  hardware-native; enables bit/hash idioms.
- **float→int out of range: wraps to low 32 bits** (consistent with above).
- **Out-of-range literals: wrap silently** (`0xFFFFFFFF` → -1).
- **`hex()` / display of negatives: sign-magnitude** (`hex(-1)` → "-0x1").
- Only **division by zero** still panics (ERR_DIV_ZERO).

## Cost / tradeoff

- **Range caps at -2³¹ .. 2³¹-1.** Today Admiral does arbitrary precision
  (`int_to_str.asm` references `2**1000`). This is a deliberate language
  regression — values wrap rather than trap.
- On-disk format changes (see Phase F). Old `.d64` int records won't load
  unless we keep a compat reader.

## Representation

The handle struct (`defs.asm:160-165`) is:

    H_PTR   = 0  (2 bytes)
    H_SIZE  = 2  (2 bytes)
    H_NEXT  = 4  (2 bytes)
    H_TYPE  = 6  (1 byte)
    H_FLAGS = 7  (1 byte)

For `TYPE_INT`, **H_PTR (bytes 0-1) holds the low 16 bits and H_SIZE (bytes
2-3) the high 16 bits** of a little-endian 32-bit two's-complement value.
Because bytes 0-3 are contiguous, loading the value is four reads at the
handle address:

    ; W0 = int handle → W2:W3 = 32-bit value (W2=$14..$15, W3=$16..$17 contiguous)
    ldy #0
    lda (W0),y : sta W2
    iny : lda (W0),y : sta W2+1
    iny : lda (W0),y : sta W3
    iny : lda (W0),y : sta W3+1

ZP scratch is convenient: **W0:W1 ($10-$13) and W2:W3 ($14-$17) are each four
contiguous bytes**, so they serve as two 32-bit accumulators.

`H_NEXT`, `H_TYPE`, `H_FLAGS` keep their meaning — inline-int handles still
live on the GC reserved list and are reclaimed normally.

## Discriminator

Every int is inline; FLOAT stays boxed (5-byte payload), BOOL/NONE stay
statics. So `H_TYPE == TYPE_INT` is itself the "inline, no payload" marker —
no new flag bit needed. Only GC compact must learn to skip `TYPE_INT`.

---

## Phasing

### Phase A — allocator + GC foundation (no behavior change yet)

1. **`alloc_inline_int` in `alloc.asm`.** Acquire a handle (reuse `FREE_HEAD`
   or carve from `NEXT_HANDLE`, same as `alloc`) but **do not bump
   `NEXT_DATA`** and **do not write an O_LEN header**. Write the 32-bit value
   into bytes 0-3, `H_TYPE = TYPE_INT`, `H_FLAGS = 0`, append to RESERVED.
   - in: value in W2:W3 (lo16:hi16). out: RV = handle.
   - Reuse the handle-acquire + RESERVED-append tail of `alloc`; factor that
     tail into a shared label so both `alloc` and `alloc_inline_int` use it.
2. **GC compact skip.** In `gc_compact`'s reserved-list walk (`gc.asm`), before
   treating `H_PTR` as a heap address, test `H_TYPE`; if `TYPE_INT`, skip the
   payload copy and the `GC_DEST` advance entirely (an inline int owns no heap
   bytes). The ascending-`H_PTR` invariant among real-payload handles is
   preserved because inline ints are simply not moved.
3. **`gc_sweep` and `gc_mark` need no change — VERIFIED.**
   - `gc_sweep` (`gc.asm:255-360`) touches only `H_NEXT` and `H_FLAGS`; it
     never reads `H_PTR`/`H_SIZE` ("Data payloads are NOT reclaimed here",
     line 246). Inline-int value bits are invisible to it. Safe as-is.
   - `gc_mark` treats `TYPE_INT` as a leaf (`gc.asm:122-133`) and only ever
     dereferences `H_PTR` inside `_gc_trace_array`, which is reached for
     container types only. An int's `H_PTR` is never dereferenced. Safe as-is.
   - The compact skip in A.2 is therefore the **only** GC change required.
4. **Statics become inline** (`statics.asm`). Replace the boxed `INT_0` /
   `INT_1` / `INT_10` (handle + `_OBJ`) with inline-form handles:

       INT_0:  .word 0      ; H_PTR  = value lo16
               .word 0      ; H_SIZE = value hi16
               .word 0      ; H_NEXT
               .byte TYPE_INT, 0
       INT_1:  .word 1 : .word 0 : .word 0 : .byte TYPE_INT, 0
       INT_10: .word 10: .word 0 : .word 0 : .byte TYPE_INT, 0

   Drop the `_OBJ` labels.

### Phase B — shared int value helpers (`handle.asm` / new `int_util.asm`)

Add the small primitives every rewritten op will lean on:

- `int_load_W0 -> W2:W3` — read the 32-bit value of the handle in W0.
  (`int_load_W1 -> W2:W3` variant if convenient.)
- `int_store_W2W3 -> RV` — `jsr alloc_inline_int` (thin alias / fallthrough).
- `int_sign_W2W3` — A = $00 / $FF from bit 31 (top bit of W3+1).
- Rewrite `int_to_unsigned_byte_W0` (`handle.asm:145`): success iff bytes 1-3
  are zero and byte 0 < 128-or-not-per-policy; return byte 0 in A. Far simpler
  than the current length-walk.
- `sign_byte_W2` / `sign_byte_W3` (`handle.asm:113-132`) lose their callers
  inside int ops; keep only if other code uses them, else delete.

### Phase C — rewrite the arithmetic (`src/int_*.asm`)

All become fixed 4-byte. Operand load → W0:W1 / W2:W3, compute, store via
`alloc_inline_int`. Delete `int_normalize.asm` entirely (no normalization).

| File | New shape |
|---|---|
| `int_add.asm` | 4-byte ADC chain. Detect signed overflow (operands same sign, result differs) → `ERR_OVERFLOW`. |
| `int_sub.asm` | 4-byte SBC chain + overflow check. |
| `int_negate.asm` | two's-complement of 4 bytes; `$80000000` negate overflows. |
| `int_cmp.asm` | compare sign bits; if equal, unsigned 4-byte compare MSB→LSB. Returns A=$FF/$00/$01 (unchanged interface, used by `val.asm:298`). |
| `int_mul.asm` | sign-extract → magnitudes; 32×32→64 schoolbook with the existing **mult9** 8×8 kernel (`int_mul.asm:158`) as inner loop (16 kernel calls); take low 32 bits; overflow if the high 32 bits aren't sign-extension of bit 31; reapply sign. |
| `int_divmod.asm` | 32-bit restoring division (32-iteration shift-subtract). Both quotient and remainder. `ERR_DIV_ZERO` on zero divisor (already coded). |
| `int_div.asm` / `int_mod.asm` | thin wrappers over `int_divmod` (unchanged role). |
| `int_shift.asm` | `<<` / `>>` by N (read shift count via `int_to_unsigned_byte`); arithmetic right shift preserves sign; left shift past bit 31 → overflow or wrap (pick policy, document). |
| `int_bitwise.asm` | 4-byte AND/OR/XOR/NOT, straight-line. |
| `int_pow.asm` | repeated squaring on 32-bit, overflow-checked each multiply. |
| `int_sgn.asm` | sign of W3 top bit + zero test. |
| `int_normalize.asm` | **deleted.** |

Kernel notes:
- **mul:** keep `int_mul.asm:158-173` (mult9) verbatim as the 8×8 kernel; the
  outer structure shrinks from variable-length bookkeeping to a fixed 4×4 byte
  grid. Optional future: square-table kernel (~40 cyc) once a 512-byte LUT can
  be parked under banked-out ROM.
- **divmod:** classic restoring division — shift dividend left into a remainder
  accumulator, conditionally subtract divisor, set quotient bit. 32 iterations,
  no loops over variable length.

### Phase D — parser + value layer

1. **`nud_int` / `nud_hex` / `nud_bin`** (`parser.asm:1547+`): parse the digit
   span into a 32-bit accumulator directly, allocate one inline int at the end.
   This replaces the per-digit `int_mul`+`int_add` allocation storm in
   `int_parse.asm` — fold the parse into the new fixed-width helpers (overflow
   on a too-long literal → `ERR_OVERFLOW`). `int_parse.asm` shrinks to a span →
   32-bit accumulator routine.
2. **`val.asm` `_vc_int`** (`val.asm:298`): unchanged — still `jsr int_cmp`.
3. **Index/subscript reads** (`parser.asm` `led_lbrack`, slice path ~2852,
   2895): wherever an index int is read via `deref`+payload, switch to
   `int_to_unsigned_byte_W0` / `int_load`. Audit every `cmp #TYPE_INT` site
   (`parser.asm:1348,1359,1380,1409,1418,1796`) for payload assumptions.

### Phase E — builtins (`builtins.asm`, ~27 `TYPE_INT` refs)

- `builtin_chr` (293): read low byte via inline load instead of `deref`.
- `builtin_ord` (327): now produces an inline int (use a set-rv-from-W2:W3
  tail; add `postamble_set_rv_int32` analogous to `postamble_set_rv_uint8_b0`).
- `builtin_int` (345): STR/BOOL/FLOAT/INT → inline int.
- `builtin_hex` (1552): read 4 bytes, render.
- `builtin_peek` / `builtin_poke` (1777): addr/val via `int_to_unsigned_byte`
  + a 16-bit address load (bytes 0-1).
- `builtin_abs`, `builtin_cmp`, `builtin_sort`, `builtin_rnd`,
  `builtin_range`, `builtin_len` (returns inline int), `builtin_id`,
  `builtin_mem`: convert any place that builds or reads an int payload.
- Add the postamble tail `postamble_set_rv_int32` (W2:W3 → `alloc_inline_int`
  → RV) in `preamble.asm` next to the existing int-return tails (426-437).

### Phase F — float bridge + disk

1. **`float.asm`** `int_to_float` (558) / `float_to_int` (681): both currently
   walk a variable-length magnitude. Rewrite for fixed 4 bytes — `int_to_float`
   becomes "GIVAYF the low 16, FADDT the scaled high 16" (two BASIC calls);
   `float_to_int` extracts mantissa/exponent into a 32-bit value with
   overflow → `ERR_OVERFLOW`.
2. **`disk.asm`** serialization (455+): a scalar int record currently emits
   `H_SIZE - O_HEADER` payload bytes. For inline ints there is no payload —
   emit a fixed 4-byte record from bytes 0-3, and the deserializer constructs
   an inline int. **Decision:** either (a) bump the disk format version and
   write 4 bytes always, or (b) keep a variable-length compat *reader* for old
   images (≈30 lines) while always *writing* the new 4-byte form. Recommend (b)
   for one release, then drop.

### Phase G — tests

- `tests/conftest.py` fixtures (`h`, `hfp`, `hd`) unchanged.
- Existing int tests asserting big-int behavior (`2**1000`, >32-bit values)
  must be rewritten to assert `ERR_OVERFLOW` instead.
- Add boundary tests: `2³¹-1`, `-2³¹`, overflow on add/mul/shift/pow,
  divmod sign rules, round-trip through `STR`/`INT`, disk save/load of
  `2³¹-1` and a negative.
- Run full `make test` (~1,600 tests) — expect many int-internal tests to
  need value updates, not logic changes.

## Order of execution

A → B → C (one op at a time, each independently testable) → D → E → F → G.
Phases A-B are pure additions and safe to land first. Each op in C can be
converted and tested in isolation against the old behavior for in-range values
before the big-int tests are retired in G.

## Risk notes

- **GC `H_PTR` aliasing — AUDITED, resolved.** The risk was "does any GC or
  list-walk code deref a `TYPE_INT` handle's `H_PTR`?" Findings: `gc_sweep`
  (H_NEXT/H_FLAGS only) and `gc_mark` (INT is a leaf) are safe untouched;
  `gc_compact` is the sole offender (it rewrites H_PTR and would corrupt the
  value) and is fixed by the A.2 skip. `_relink_to_tail` (`alloc.asm:407`) and
  alloc's RESERVED append use H_NEXT only. No other reserved-list walkers
  exist. The inline-in-handle approach is safe.
- **Overflow policy** must be consistent across add/sub/mul/shift/pow and
  documented in `README.md` (the file is the user-facing reference; CLAUDE.md
  requires keeping it in sync).
- Keep `B1` (boxed fixed-4-byte) in your back pocket: if the inline-handle GC
  audit turns up something nasty, falling back to "always-4-byte heap object"
  keeps every `deref` path working and still buys the code-size win, just not
  the allocation win.
