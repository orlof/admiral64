# Stage 6 — Float (BASIC ROM-backed)

## Context

Add `TYPE_FLOAT` so the lexer/parser can emit literal floats (`3.14`) and
the runtime can do arithmetic. Decision (this stage): **use C64 BASIC ROM
floating-point routines**. No Admiral compatibility — the 48-bit DCPU format
is dropped. Save/load artifacts will not round-trip with DCPU Admiral, and
that's fine: nobody is moving `.d64` images between platforms.

Wins: ~0 bytes of FP code in our binary, transcendentals (SIN/COS/SQR/LOG/EXP/
ATN) come free from BASIC ROM, and `defs.asm:8-21` already reserved
`$57-$8F` for BASIC's FP workspace — the codebase is wired for this.

## Decisions

### Heap object: 5 bytes, MS-Basic format

Type tag `TYPE_FLOAT = $27`. Heap object: `O_LEN=5` + 5 raw bytes in MS-Basic
in-memory layout (1 exponent + 4 mantissa, hidden-bit form, sign in bit 7 of
first mantissa byte). Identical to what BASIC reads/writes via MOVFM/MOVMF.

GC: leaf type. `_gc_trace_array` is not invoked; `gc_mark` dispatcher just
sets `FLAG_MARKED` and skips recursion (same as TYPE_STR/TYPE_INT).

### Bank switching strategy

`$01 = $36` is the steady state (BASIC out, KERNAL + I/O in). Each binary
FP op:

1. **`$01=$36`:** copy 5 bytes from left-operand heap object → FAC2 ZP
   (`$69-$6E`), unpacking the sign bit from mantissa-bit-7 to the FAC2
   sign byte.
2. **`$01=$36`:** same copy from right-operand heap object → FAC1 ZP
   (`$61-$66`).
3. **`$01=$37`:** bank BASIC ROM in.
4. **`jsr FADDT`** (or FSUBT / FMULTT / FDIVT) — register-form variants
   that operate on FACs already loaded.
5. **`$01=$36`:** bank BASIC out.
6. Allocate a fresh `TYPE_FLOAT`. Pack 5 bytes from FAC1 (folding sign
   byte into mantissa-bit-7) into the new heap object's payload.

Steady state across an op: bank stays `$36` except for the brief window
in steps 3-5 (IRQ-safe — KERNAL is mapped in both states; only BASIC
ROM toggles).

**No scratch buffer needed.** FACs are plain ZP RAM, accessible regardless
of bank state. Heap reads/writes happen entirely in `$36` mode. The
cassette buffer (`$0334-$03FB`) is left untouched and remains available
for future use (e.g., disk I/O at Stage 13).

### Packed vs unpacked FP format

In-memory ("packed", 5 bytes — the format we store in heap objects):
```
byte 0: exponent (excess-128; $00 means value is zero)
byte 1: bit 7 = sign, bits 6..0 = high 7 bits of mantissa (hidden 1 implicit)
byte 2..4: mantissa low bits
```

In FAC ZP ("unpacked", 6 bytes):
```
$61/$69:  exponent
$62/$6A:  bit 7 = explicit hidden 1, bits 6..0 = high 7 bits of mantissa
$63-$65 / $6B-$6D: mantissa low bits
$66/$6E:  sign byte ($00 positive, $FF negative)
```

Pack/unpack is two LDA/AND/ORA/STA sequences plus a zero-exponent fast
path. Centralized in `_fp_unpack_to_fac1`, `_fp_unpack_to_fac2`,
`_fp_pack_from_fac1` helpers in `float.asm`. ~25 bytes each.

### ZP layout for FP

Already reserved in `defs.asm:8-21`:
- `$57-$60` — BASIC FP temporaries
- `$61-$66` — FAC1 (5 bytes + sign-padding byte)
- `$69-$6E` — FAC2 (same)
- `$73-$8A` — CHRGET routine (used by BASIC's str→float parser)
- `$FB-$FE` — spare; we do **not** repurpose since BASIC's `STR$`/`VAL`
  paths may touch it indirectly.

We store nothing in `$57-$8F` ourselves — the partition stays clean, no
save/restore around FP calls.

### Comparison semantics

No FCOMP — it's a memory-form-only routine, and using it would require
a scratch slot. Instead, compute `left - right` via FSUBT and inspect
the result:
- `$61` (FAC1 exponent) == `$00` → equal, return A=$00
- `$66` (FAC1 sign byte) bit 7 set → result negative → left < right, A=$FF
- else → result positive → left > right, A=$01

Costs one extra "alloc-free" call (FSUBT trashes FAC1 but we don't keep
the result). Saves the scratch slot and the FCOMP call. Maps directly
onto `val_cmp` return convention. **No epsilon.** Equality is bit-exact.

### val_eq + val_cmp dispatch

Add `TYPE_FLOAT` arms to both. `val_eq`: bytewise compare the 5-byte
payloads (no need to call BASIC for equality — bit-exact equality of
MS-Basic floats is bytewise equality, since the format has a unique
representation per value, including a defined zero where exp=0 forces
mantissa=0). `val_cmp`: route to FCOMP wrapper.

**Cross-type INT vs FLOAT:** promote INT to float via int_to_float, then
fall into FLOAT/FLOAT path. Mirrors Python's numeric tower. Heterogeneous
INT/FLOAT comparisons must work (the parser doesn't enforce types).

### `int_to_float` algorithm

Our INT is variable-length two's-complement (Admiral-style heap bigint).
BASIC's `GIVAYF` at `$B391` takes a 16-bit signed int in A/Y → FAC1. So:

- INT fits in 16 bits → load into A/Y, `jsr GIVAYF`.
- INT exceeds 16 bits → manual loop: start with FAC1=0, then for each
  byte from MSB to LSB: FAC1 = FAC1 * 256 + byte, using FMUL by a 256
  constant + FADD. Slow but correct, and bigints in user code rarely
  exceed 32 bits in practice.

### `float_to_int` algorithm

`QINT` at `$BC9B` truncates FAC1 to a 32-bit signed integer at `$62-$65`.
Then we copy those 4 bytes into a fresh TYPE_INT heap object (variable-
length, trim leading sign-extension bytes to canonical form via existing
`int_normalize` helper if present, else inline). If FAC1 is out of 32-bit
range, BASIC raises ?ILLEGAL QUANTITY — we trap by checking range first
(compare FAC1 against ±2^31 floats stored as static MS-Basic constants).
If overflow, return error code `ERR_OVERFLOW = $03` (new) via the existing
`error_handler` path.

### `float_to_str` and `str_to_float`

- `float_to_str`: `FOUT` at `$BDDD` writes a null-terminated ASCII string
  to `$0100` (BASIC's input buffer). We allocate a TYPE_STR sized to the
  string length (≤ ~14 bytes) and copy. Output is C64 BASIC's standard FP
  format ("3.14159265", "1.5E-10", etc.).
- `str_to_float`: copy our TYPE_STR bytes into BASIC's input buffer at
  `$0200` (CHRGET reads from there), then `jsr FIN` at `$BCF3`. Returns in
  FAC1; we store to a fresh TYPE_FLOAT.

Both straightforward wrappers. Need to be careful about CHRGET's pointer
state (`$7A-$7B`) — set before FIN, ignore after.

### BASIC entry points used (verify before committing)

We only use **register-form** routines — no memory-form variants.

| Addr   | Name    | Purpose                                |
|--------|---------|----------------------------------------|
| $B391  | GIVAYF  | int (A=lo, Y=hi) → FAC1                |
| $B867  | FADDT   | FAC1 = FAC2 + FAC1                     |
| $B853  | FSUBT   | FAC1 = FAC2 - FAC1 (also used by cmp)  |
| $BA2E  | FMULTT  | FAC1 = FAC2 * FAC1                     |
| $BB0F  | FDIVT   | FAC1 = FAC2 / FAC1                     |
| $BFB4  | NEGOP   | FAC1 = -FAC1                           |
| $BC9B  | QINT    | FAC1 → 32-bit int at $62-$65           |
| $BCF3  | FIN     | parse ASCII at CHRGET ptr → FAC1       |
| $BDDD  | FOUT    | FAC1 → ASCII at $0100                  |
| $BF7B  | SQR     | sqrt(FAC1) (transcendentals, later)    |
| $E26B  | SIN     | sin(FAC1)                              |
| $E264  | COS     | cos(FAC1)                              |
| $E097  | RND     | (when crypto/builtin needs)            |

These are well-documented and stable across PAL/NTSC KERNAL revs.
**Verify each address in VICE before committing the wrapper** — exact
labels vary slightly across BASIC ROM disassembly sources.

## Files

### New — `src/float.asm`

V4' wrappers. All preserve W/B regs, return result handle in RV (or write
into existing handle layout), pop args from RS as usual.

- `float_alloc` — allocate empty 5-byte TYPE_FLOAT, payload = 0.0 bytes.
- `_fp_unpack_to_fac1` (leaf) — given heap-object pointer in W2, write 6
  unpacked bytes to FAC1 (`$61-$66`). All in `$36` mode. ~25 bytes.
- `_fp_unpack_to_fac2` (leaf) — same, target FAC2 (`$69-$6E`). ~25 bytes.
- `_fp_pack_from_fac1` (leaf) — given fresh heap-object pointer in W2,
  write 5 packed bytes from FAC1. ~20 bytes.
- `_basic_call(addr)` macro — `lda #$37; sta $01; jsr addr; lda #$36; sta $01`.
- `float_add`/`float_sub`/`float_mul`/`float_div` — V4', pops 2 from RS,
  pushes result. Sequence: unpack left → FAC2, unpack right → FAC1,
  `_basic_call(FADDT/FSUBT/FMULTT/FDIVT)`, alloc result, pack FAC1.
- `float_neg` — V4', pops 1, returns negated. Unpack to FAC1,
  `_basic_call(NEGOP)`, pack out.
- `float_cmp` — V4', pops 2, returns A=$FF/$00/$01. Unpack left → FAC2,
  unpack right → FAC1, `_basic_call(FSUBT)`, then test `$61`/`$66`.
  No allocation.
- `int_to_float` — V4', pops INT, pushes FLOAT. 16-bit fast path via
  GIVAYF; 32+ via byte-by-byte FMULTT loop.
- `float_to_int` — V4', pops FLOAT, pushes INT. Range-check first.
- `float_to_str` — V4', pops FLOAT, pushes STR.
- `str_to_float` — V4', pops STR, pushes FLOAT. On parse failure, push
  `NONE` (or panic? deferred — for now, NONE).

Total estimated size: ~400 bytes of 6502.

### Modify — `src/defs.asm`

```asm
.const TYPE_FLOAT = $27

// BASIC ROM entry points (full table in float.asm header)
.const BASIC_GIVAYF = $B391
.const BASIC_FADDT  = $B867
.const BASIC_FSUBT  = $B853
.const BASIC_FMULTT = $BA2E
.const BASIC_FDIVT  = $BB0F
.const BASIC_NEGOP  = $BFB4
.const BASIC_QINT   = $BC9B
.const BASIC_FIN    = $BCF3
.const BASIC_FOUT   = $BDDD

// FAC ZP locations (already reserved by ZP partition; named here for
// readability in float.asm)
.const FAC1 = $61    // 6 bytes: exp, m0..m3, sign
.const FAC2 = $69    // 6 bytes: exp, m0..m3, sign

.const ERR_OVERFLOW = $03
```

### Modify — `src/val.asm`

- `val_eq`: add TYPE_FLOAT arm — bytewise 5-byte compare. Add INT/FLOAT
  cross-arm — promote INT, recurse.
- `val_cmp`: add TYPE_FLOAT arm — call `float_cmp` (bypassing the V4'
  wrapper since we have W0/W1 with handles already). Add INT/FLOAT
  cross-arm — promote INT, recurse.

### Modify — `src/gc.asm`

`gc_mark` dispatcher: TYPE_FLOAT is leaf, `bra _gm_done` after setting
mark bit. Same shape as TYPE_INT/STR.

### Modify — `src/admiral.asm`

`#import "float.asm"` after `int.asm`.

### Modify — `src/statics.asm`

Add `FLOAT_ZERO` (5 bytes of $00 — MS-Basic zero is exp=0, mantissa
ignored), `FLOAT_ONE` (`$81 $00 $00 $00 $00` — exp=129 i.e. 2^0, mantissa
1.0 with hidden bit). Pre-allocated handles for cheap reuse from the
parser/eval.

Note: keeping these as pre-allocated *handles* (in the static handle
region) means user code can compare with `is FLOAT_ZERO` cheaply, but
arithmetic still allocates fresh handles per op. That's fine.

### New — `tests/test_float.py`

py65-based, with BASIC ROM loaded into `$A000-$BFFF` from VICE install.

Conftest helper: `load_basic_rom(memory)` reads
`/Applications/vice-arm64-gtk3-3.9/VICE.app/Contents/Resources/share/vice/C64/basic-901226-01.bin`
(8 KB) into `memory[0xA000:0xC000]`. Skip the test module with
`pytest.importorskip` analog if the ROM isn't present (CI portability).

Test surface (~30 tests):
- `float_alloc` produces 5-byte payload, type tag $27, FLAG_MARKED clear.
- `int_to_float`(0/1/-1/256/-256/2^15/2^15-1) round-trips via float_to_int.
- `int_to_float`(2^16) doesn't overflow (use 32-bit BASIC path).
- `float_to_int`(NaN/Inf-equivalent / out-of-int32-range) → ERR_OVERFLOW.
- Add/sub/mul/div: 1.5+2.5=4.0, 10/4=2.5, 1/3 produces expected MS-Basic
  bytes, etc.
- `float_cmp`: 1.0 < 2.0 → $FF; 1.0 == 1.0 → $00; 2.0 > 1.0 → $01.
- `val_eq`(int 1, float 1.0) → True (cross-type promotion).
- `val_cmp`(int 1, float 1.5) → $FF.
- `float_to_str` / `str_to_float` round-trip on "3.14", "1E-5", "-0.5",
  "0".
- Negative-zero handling (MS-Basic represents zero as exp=0; sign bit in
  mantissa is undefined for zero — equality should still hold).
- GC: alloc 100 floats with no roots, gc_collect frees all.

### New — `tests/test_float_vice.md`

Manual VICE checklist: type a few literal expressions (`?3.14*2`, `?SQR(2)`,
etc.) into a tiny REPL stub or use the BASIC interpreter as oracle, compare
to our float_to_str output for the same operands. Catches any entry-point
address mismatch py65+ROM-blob doesn't.

## Verification

### py65 regression

`uv run pytest -q` — all existing tests pass; new `test_float.py` adds ~30.

### VICE smoke

Build with `kickass`, run in VICE, exercise via a tiny test harness in
`admiral.asm` that does `int_to_float(7); float_div(_, int_to_float(2));
float_to_str(_); print_str(_)` and prints "3.5". Or — once REPL is up at
Stage 11 — just type it.

### BASIC oracle

For trickier cases (denormals, large exponents, repeating-decimal display),
type the same expression at the BASIC `READY.` prompt in VICE and compare
strings. BASIC's printer is what we're calling, so they should match
exactly.

## Not included

- **Float statics in lexer output.** Lexer isn't here yet; for now,
  programmatic `int_to_float(7)` is the only path to creating a float.
- **Transcendentals as user-visible builtins.** Wrapper code is trivial
  but won't be exposed until Stage 10 (`import math`).
- **Denormal handling.** MS-Basic doesn't have denormals; underflow → 0.
  We accept that.
- **NaN/Inf.** MS-Basic raises ?OVERFLOW instead of producing Inf; we trap
  to `ERR_OVERFLOW`. No silent NaN propagation.
- **48-bit Admiral float port.** Decision recorded: dropped.
- **Tagged small floats.** Always heap-allocated. Optimization deferred.

## Risks

- **Entry-point drift.** BASIC ROM addresses are stable for the standard
  C64 (`basic-901226-01.bin`), which is what every emulator and real
  hardware ships. Pi1541 / cartridge replacements don't touch BASIC ROM.
  Low risk.
- **CHRGET ZP corruption.** `str_to_float` uses CHRGET (`$73-$8A`). If
  any of our code accidentally writes there, FIN will misparse. Guarded
  by the ZP partition; verify at code review.
- **Bank-switch interrupts.** CIA1 IRQ fires at 60 Hz. KERNAL stays
  mapped in both `$36` and `$37` configs, so the IRQ vector at `$FFFE`
  resolves identically — interrupts are safe across the bank flip. Verify
  with a stress test that runs IRQ-heavy code (`screen_init` color RAM
  fill while a tight FP loop runs).
- **py65 BASIC ROM emulation accuracy.** py65 is just a 6502 CPU; loading
  BASIC ROM bytes into RAM emulates the *code paths* but not C64 hardware
  side effects (e.g., BASIC ROM doesn't touch I/O registers in FP code,
  so this should be fine — but verify by running each new wrapper in
  both py65 and VICE).
- **Heap object at $A000-$BFFF.** Already addressed via FP_SCRATCH staging.
  Any *new* code that wants to read heap during a BASIC call needs the
  same treatment. Document this in `float.asm` header.

## References

- BASIC ROM disassembly: any of the standard C64 BASIC disassemblies
  (Mapping the 64, the PRG, etc.). Entry-point addresses in the table
  above sourced from `mapping the c64` Appendix L.
- `defs.asm:8-21` — ZP partition already commits to BASIC FP layout.
- `src/int.asm` — INT alloc + variable-length payload pattern, mirror for
  float's leaf-shape.
- `src/val.asm` — dispatcher pattern for adding TYPE_FLOAT arms.
- `src/gc.asm` — leaf-type pattern (TYPE_INT/STR) to mirror.
