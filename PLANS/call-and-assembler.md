# CALL + minimal self-hosted assembler

Two layers:

1. **`CALL(str, a0..a3)`** — a ~30-40 byte core builtin that JSRs into a string
   of 6510 machine code (a leaf, position-independent native primitive),
   passing up to four argument-payload pointers in W0..W3.
2. **`asm.admiral`** — a minimal two-pass 6502 assembler **written in Admiral**,
   shipped on the disk, that turns assembly text into a byte string CALL can
   execute. The C64 becomes self-hosting for native extensions.

No new type, no pinning, no relocation, no ABI jump table. The whole design
rests on one rule: **the native code is a pure leaf** (it never allocates and
never calls back into Admiral), so GC cannot fire while the PC is inside it,
so the string is free to move between calls without breaking anything.

---

## Part 1 — `CALL` builtin

### Contract (extension author's view)

    CALL(code_str, arg0, arg1, arg2, arg3)   -- 0..4 args after the code string

- `code_str` is a `TYPE_STR` whose payload is 6510 machine code.
- For each arg present, CALL **derefs it to its payload pointer** and places
  that pointer in W0, W1, W2, W3 (arg0→W0 …). The extension interprets the
  bytes blind — no type or length checks. (With fixed-32 ints, "int arg = the
  4 bytes at W0"; see `fixed-32-integers.md`.)
- The extension may freely clobber W0..W3, B0..B7, A, X, Y. It **must balance
  the hardware stack** before `RTS`.
- The extension returns a 16-bit result in **W0** (lo:hi). CALL wraps it as an
  int. (Statement-form callers ignore it.)
- Rules: leaf only (no allocation, no Admiral callbacks); branches PC-relative;
  absolute operands only to fixed addresses (hardware regs, KERNAL) or ZP; the
  extension owns its own `$01` banking if it touches I/O.

### Why no save/restore is needed

`CALL` is itself a V4' builtin: its **preamble already saved the caller's
W0..W3 / B0..B7** and its **postamble restores them**. The extension trashing
W/B happens inside CALL's frame and is invisible to the Admiral code that
called CALL. A/X/Y are scratch by convention. So CALL adds *zero* save/restore
code. (Verified against `defs.asm`: W0..W3=$10-$17, B0..B7=$18-$1F, both
outside the live FSP/RSP/FP=$02-$06, allocator=$20-$2F, scope=$42-$46.)

### Why leaf-only keeps the moving string safe

GC runs only at allocation time. A leaf extension never allocates, so
`gc_compact` cannot run while the PC is inside the string → the string cannot
be relocated mid-execution. Between calls the string may move freely; CALL
re-reads `H_PTR` every time, and PI code doesn't care where it lives.
CALL allocating the **return** int happens *after* the JSR returns (we're back
in CALL's code, not in the string), so that allocation — and any GC it
triggers — is safe.

### Implementation (`builtins.asm` + `tools/build_tst.py`)

1. Register the name: add `("CALL", "builtin_call")` to the `BUILTINS` list in
   `tools/build_tst.py:32` (regenerates `src/tst_builtins.asm` at build time).
2. Write `builtin_call`:

   ```
   builtin_call:
       preamble_call(1, 5)              ; code_str + 0..4 args; MAX=5
       ; arg_get(0, W3a) -> code string handle; deref to payload base.
       arg_get(0, W0)
       jsr deref_W0_to_W2               ; W2 = code payload ptr, A = O_LEN
       ; SMC-patch the JSR target with W2.
       lda W2 : sta _call_jsr+1
       lda W2+1 : sta _call_jsr+2
       ; Marshal args 1..N into W0..W3 as PAYLOAD POINTERS.
       ; (loop: for i in 1..argc-1: arg_get(i,Wtmp); deref H_PTR(+O_HEADER);
       ;  store into W{i-1}. argc known from preamble_call's arity in B-reg.)
       ...
   _call_jsr:
       jsr $ffff                        ; SMC target = code payload
       ; Result: W0 = 16-bit return. Wrap as int.
       ; (lo16 in W0, hi16 = sign-extend or 0 → W2:W3 → alloc_inline_int)
       jmp postamble_set_rv_int32       ; (the tail added in fixed-32 Phase E)
   ```

   - `arg_get(i, reg)` and the arity count come from the `preamble_call`
     machinery (`preamble.asm:75, 226, 286`); read the arg count it stashes to
     drive the marshalling loop.
   - **JSR cannot be indirect on 6502** — hence the SMC `_call_jsr+1/+2` patch.
   - Result wrapping: define the convention as "16-bit unsigned in W0" → zero-
     extend to 32-bit inline int. (If signed results are wanted, sign-extend
     from bit 15; pick one and document.) Without fixed-32 yet, use the
     existing 1-byte/2-byte int return tails instead.
3. Size: ~30-40 bytes + the marshalling loop.

### Optional backstop (recommended)

Add a `CALL_ACTIVE` flag (one ZP byte, or reuse a free cell near
`PAUSE_BLOCKED=$49`). CALL sets it around the JSR; `gc_compact` checks it and
**refuses to compact** when set (falls back to mark+sweep only, which never
moves payloads). This turns "extension misbehaved and allocated" from silent
heap corruption into a clean `ERR_OOM` if memory is actually tight. ~10 bytes.

---

## Part 2 — minimal assembler in Admiral (`examples/asm.admiral`)

Ships as a packed `examples/*.admiral` (see CLAUDE.md: `pack_str_record.py`
serializes each as a `TYPE_STR` record loadable via `LOAD`). Usage:

    ASM = LOAD("ASM")
    CODE = ASM(SRC)            -- SRC is assembly text; CODE is a byte string
    PRINT(CALL(CODE, 5))       -- assemble then run, all on the C64

### Restricted syntax (deliberately minimal, matches the leaf-PI model)

- One instruction or one `label:` per line. `;` starts a comment.
- **Branches relative; labels feed branches only.** `loop:` resolves to a byte
  offset; `bpl loop` emits `target-(pc+2)`, must fit ±127.
- **No intra-blob `JSR`/`JMP`** (base unknown until CALL loads it; no
  relocation). Absolute operands must be literals (`$D020`, `$E000`) or ZP reg
  names.
- **Operand expressions: only `symbol` and `symbol+N`** (needed for `W0+1`).
- Predefined symbols seeded in the table: `W0=$10 W1=$12 W2=$14 W3=$16`,
  `B0=$18 … B7=$1F`, `RV=$0E`, plus common fixed addresses if desired.

### Addressing-mode classifier (operand text → mode, size)

| Operand shape | Mode | Bytes |
|---|---|---|
| (none) | implied | 1 |
| `#$NN` / `#N` | immediate | 2 |
| `#<expr` / `#>expr` | immediate lo/hi of a 16-bit value | 2 |
| `(sym),y` | (zp),y | 2 |
| `(sym,x)` | (zp,x) | 2 |
| `sym` / `sym+N` / `$NN` | zeropage (+ ,x / ,y) | 2 |
| `$NNNN` / `$NNNN,x` / `,y` | absolute (+ index) | 3 |
| `label` on a branch | relative | 2 |

### Data structures (all native Admiral)

- **Opcode table**: dict `{mnemonic: dict{mode: opcode_byte}}`. Start with the
  ~35 instructions extensions actually use; grow later. Pure data entry.
- **Symbol table**: dict seeded with ZP reg names; pass 1 adds `label:` → byte
  offset.
- **Output**: byte string built with `CHR(n)` (builtin already exists,
  `builtins.asm:295`) concatenated, or a list of ints joined at the end.

### Two-pass driver

    PASS 1: walk lines; for each, compute its byte size (mode classifier) and
            advance an offset counter; record `label -> offset` in the symbol
            dict. (Sizes only; no emission.)
    PASS 2: walk lines again; emit opcode byte + operand bytes into output.
            Branch targets now resolve from the symbol dict; compute the
            signed relative displacement and range-check it.

### Helpers needed in Admiral

- `PARSEHEX(s)` / `PARSENUM(s)` — operand text is runtime string data, so the
  assembler parses its own `$NN` / decimal (small loop; Admiral's lexer does
  not help here).
- `CHR(n)` — byte → 1-char string. **Exists** (`builtin_chr`). This is the only
  core primitive the assembler needs; if a faster `BYTES(list)->str` is wanted
  later it can be added, but `CHR`+concat is sufficient.

### Worked example (the user's source assembles correctly)

    ldy #10        -> A0 0A
    lda (W0),y     -> B1 10
    tax            -> AA
    lda #<1024     -> A9 00
    sta W0         -> 85 10
    lda #>1024     -> A9 04
    sta W0+1       -> 85 11      (symbol+N)
    lda #1         -> A9 01
    loop:                        (offset recorded)
    sta (W0),y     -> 91 10
    dey            -> 88
    bpl loop       -> 10 FB      (-5 relative)
    rts            -> 60

Output: 21 bytes, ready for `CALL`.

### Performance

Re-lex-on-call makes the assembler slow, but it runs **once** over tens of
instructions, then the result executes at native 1 MHz. A 30-line routine
assembling in a few seconds is fine — the asymmetry is the point.

---

## Build / packaging

- `tools/build_tst.py`: add `CALL`. Rebuild regenerates `tst_builtins.asm`.
- `examples/asm.admiral`: new file; `make` packs it onto `build/admiral.d64`
  via `pack_str_record.py` (per CLAUDE.md). Loadable as `LOAD("ASM")`.
- Optionally add `examples/plot.asm.admiral` or an inline `\xNN` demo string
  showing the assemble→CALL loop end-to-end.

## Tests

- `builtin_call`: a unit test driving a known tiny routine (e.g. the bit-
  reverse or "fill N bytes" leaf) via the py65 harness; assert memory effects
  and the wrapped return value. Verify W/B preservation across CALL (caller's
  W/B intact afterward).
- Assembler: assemble the worked-example source in Admiral (run under the
  interpreter test harness) and assert the exact 21-byte output; then CALL it
  and assert the memory write. Add per-addressing-mode encoding tests.
- Backstop: a test that an allocating (misbehaving) extension hits `ERR_OOM`
  cleanly rather than corrupting the heap, if the `CALL_ACTIVE` backstop lands.

## Order of execution

1. `builtin_call` + name registration + the SMC JSR + arg marshalling.
2. Result-wrapping tail (depends on fixed-32 `postamble_set_rv_int32`, or use
   existing int tails in the interim).
3. `CALL_ACTIVE` GC backstop.
4. `asm.admiral` opcode table + classifier + two-pass driver.
5. Packaging + tests.

Part 1 (CALL) is independently useful and can land before the assembler — you
can author extensions as `\xNN` string literals until `asm.admiral` exists.
