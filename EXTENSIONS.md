# Writing native extensions for Admiral64

Admiral can call hand-written 6510 machine code held in an ordinary string, via
the `CALL` builtin. This lets you drop down to native speed for inner loops
(graphics, fast scans, hardware pokes) without rebuilding the interpreter.

```
DOUBLE = "\xA0\x00\xB1\x10\x0A\x85\x10\xA9\x00\x85\x11\x60"
PRINT(CALL(DOUBLE, 21))      -- 42
```

A code string is just bytes — load it from disk (`LOAD`), build it inline with
`\xNN` escapes, or generate it with the `asm.admiral` assembler.

---

## `CALL(code, a0, a1, a2, a3)`

- **`code`** — a `TYPE_STR` whose payload is position-independent 6510 machine
  code. `CALL` JSRs into its **first payload byte**.
- **`a0..a3`** — 0 to 4 further arguments. Each argument's **handle address** is
  placed in `W0`, `W1`, `W2`, `W3` respectively (`a0`→`W0`, …). Arguments not
  supplied leave the corresponding register undisturbed.
- **Returns** — the 16-bit value your routine leaves in `W0`, zero-extended to a
  non-negative inline integer (0..65535).

`CALL` itself costs nothing to set up beyond the JSR: it is a normal V4'
builtin, so its frame saves and restores the *caller's* `W`/`B` registers. Your
routine may trash anything it likes.

---

## The ABI

### Zero-page pseudo-registers (the "safe set")

Your routine may freely use these as scratch — Admiral's state does **not** live
here across a `CALL`:

| Name | ZP addr | Width |
|------|---------|-------|
| `W0` | `$10`   | 16-bit |
| `W1` | `$12`   | 16-bit |
| `W2` | `$14`   | 16-bit |
| `W3` | `$16`   | 16-bit |
| `B0`..`B7` | `$18`..`$1F` | 8-bit each (contiguous) |

`A`, `X`, `Y` are scratch too. **Do not touch any other zero-page address** —
`$02-$06` (stack pointers), `$20-$2F` (allocator), `$42-$46` (scope), and the
BASIC FP workspace (`$57-$70`) are load-bearing. Staying inside `W`/`B`/`A`/`X`/
`Y` is the whole contract.

`$FB:$FC` is a special slot: on entry, `CALL` leaves your code's **own load
address** there — see [Big loops](#big-loops-the-fbfc-base-address) below. You
may overwrite it freely after reading it.

### Reading arguments

Each `Wn` holds the **handle address** of argument *n*. How you read the data
depends on the argument's type:

- **Integer** — the value lives *inline* in the handle: 4 little-endian bytes at
  `(Wn)+0..3` (low byte first). For a small int just read the low byte:

  ```asm
  ldy #0
  lda (W0),y          ; low byte of int arg 0
  ```

- **String** (or list/dict/tuple) — the handle's first two bytes are a pointer
  to the heap object; the object's payload starts `O_HEADER` (2) bytes in, with
  a 16-bit length at offset 0:

  ```asm
  ldy #0
  lda (W0),y : sta $30        ; H_PTR lo  (use any free ZP for the deref ptr)
  iny
  lda (W0),y : sta $31        ; H_PTR hi
  ; ($30)+0..1 = length, ($30)+2.. = bytes
  ```

### Returning a value

Leave a 16-bit result in `W0` (`$10` lo, `$11` hi) and `RTS`. `CALL` reads it
and hands back a non-negative inline int. If your routine is a pure side-effect
(e.g. plotting a pixel), the return value is ignored — just leave `W0` as-is.

---

## The rules

1. **Leaf only.** Your code must **not allocate** and must **not call back into
   Admiral**. Admiral's garbage collector only runs during allocation; because a
   leaf never allocates, the GC cannot fire while your code is executing, so the
   code string cannot be relocated out from under the running PC. (Between calls
   the string may move freely — `CALL` re-finds it every time.)

2. **Position-independent.** The string can sit anywhere in the heap, so:
   - Branches (`BNE`, `BCC`, …) are fine — they're PC-relative.
   - **No `JSR`/`JMP` to your own labels** and no absolute references into your
     own bytes — the absolute address isn't known until load time.
   - Absolute addressing to *fixed* locations is fine: hardware registers
     (`$D000`+), KERNAL, zero page.
   - Internal data tables / loops bigger than the ±127 branch range: read your
     own base from `$FB:$FC` ([below](#big-loops-the-fbfc-base-address)).

3. **Balance the hardware stack.** Every `PHA`/`PHP` paired before `RTS`. `CALL`
   pushes the return address; an unbalanced routine returns into garbage.

4. **Own your banking.** Steady state is `$01 = $34` (BASIC/KERNAL/I/O all
   banked *out*; the heap can live under those ROMs). Plain RAM and zero page
   are reachable as-is. To touch I/O — VIC (`$D000-$D02E`), color RAM (`$D800`),
   SID, CIA — flip `$01` to `$35` (or `$36` for KERNAL) yourself and restore it
   before returning. Reads/writes of the bitmap region in graphics mode are
   plain RAM and need no flip.

---

## Worked examples

**Return a constant** — `LDA #42 ; STA W0 ; LDA #0 ; STA W0+1 ; RTS`:

```
F = "\xA9\x2A\x85\x10\xA9\x00\x85\x11\x60"
CALL(F)                      -- 42
```

**Double an int argument** — read `(W0),Y`, shift, store back to `W0`:

```
;  LDY #0 ; LDA ($10),Y ; ASL ; STA $10 ; LDA #0 ; STA $11 ; RTS
F = "\xA0\x00\xB1\x10\x0A\x85\x10\xA9\x00\x85\x11\x60"
CALL(F, 21)                  -- 42
```

**Add two int arguments** — `a0` in `W0`, `a1` in `W1`:

```
;  LDY #0 ; LDA ($10),Y ; CLC ; ADC ($12),Y ; STA $10 ; LDA #0 ; STA $11 ; RTS
F = "\xA0\x00\xB1\x10\x18\x71\x12\x85\x10\xA9\x00\x85\x11\x60"
CALL(F, 30, 12)              -- 42
```

---

## Big loops: the `$FB:$FC` base address

If your routine's per-iteration body is more than ~120 bytes, a backward branch
from the loop tail to the loop top can't reach (6502 branches are signed 8-bit).
You can't use `JMP loop_top` either — that's an absolute address into your own
relocatable code.

`CALL` solves this by leaving the routine's **own load address** in `$FB:$FC`
at entry. With that you can build a runtime pointer to your loop label and
finish each iteration with `JMP (zp)` — an indirect jump through fixed RAM,
which *is* PI-safe. The expression `loop_top - routine_start` is an
assembly-time constant your assembler computes:

```asm
routine_start:
        clc
        lda $FB
        adc #<(loop_top - routine_start)
        sta DLOOP            ; some fixed RAM cell (e.g. in the graphics
        lda $FC              ; reserved region, or any non-load-bearing addr)
        adc #>(loop_top - routine_start)
        sta DLOOP+1
        ; … one-time setup …
loop_top:
        ; … big iteration body, branches anywhere inside …
        jmp (DLOOP)          ; only "JMP" PI code is allowed to use
```

After reading `$FB:$FC` you may overwrite it. The full worked example is
`HIRES_DRAW` in `tools/gfx.asm`.

---

## Authoring

- **By hand**: write the bytes as a `\xNN` string literal (above), or `POKE`
  them into a buffer.
- **With the assembler**: `asm.admiral` (a two-pass 6510 assembler written in
  Admiral) turns assembly text into a code string — write `LDA`, `STA`, labels
  and branches instead of hex.
- **From disk**: assemble once, `SAVE` the string, `LOAD` it in later sessions.

See `PLANS/call-and-assembler.md` for the design rationale.

---

## Graphics: hi-res & multicolor bitmap

Bitmap graphics live in a separate **memory configuration** entered with
`REBOOT(TRUE)` (a core builtin). That reserves the top ~9 KB of RAM for a VIC
bank-3 bitmap; the heap ceiling drops from `$FFF8` to `$DC00` (~21 KB heap).
`REBOOT(FALSE)` returns to the full-heap text config. REBOOT is a warm restart
(the workspace is wiped — `SAVE` first; programs/data persist on disk).

Graphics memory (graphics config only):

| Region | Address | Use |
|--------|---------|-----|
| Color matrix | `$DC00–$DFE7` | per-8×8-cell colors (1000 B) |
| Bitmap | `$E000–$FF3F` | 320×200 pixels (8000 B) |
| Row table + scratch | `$FF40–$FFF9` | 25-word bitmap-row table + draw scratch |
| Vectors | `$FFFA–$FFFF` | IRQ/NMI/RESET (untouched) |

Three disk libraries provide the modes (each a dict of methods over `CALL`-asm
primitives; generated by `tools/gfx_pack.py` from `tools/gfx.asm`):

```
REBOOT(TRUE)                 -- enter the graphics config (do this first)
H = LOAD("HIRES")            -- mono 320x200 — file IS the dict, no ()
H.SHOW()                     -- VIC -> hi-res ($FF40 row table is pre-built)
H.COLOR(FG=1, BG=6)          -- white on blue, per 8x8 cell
H.CLEAR()                    -- zero the bitmap   (CLS is a reserved word)
H.PLOT(X=160, Y=100)         -- set a pixel       (x 0..319, y 0..199)
H.DRAW(X0=0, Y0=0, X1=319, Y1=199)   -- Bresenham line
LOAD("TEXT").SHOW()          -- restore the text display (REPL visible again)
```

Multicolor (160×200, 4 colors per cell — `00`=`$D021` bg, `01`/`10` from the
matrix, `11` from color RAM):

```
M = LOAD("MC")
M.SHOW()
M.COLOR(C01=1, C10=2, C11=7)
M.PLOT(X=80, Y=100, INK=2)   -- ink 0..3
M.DRAW(X0=0, Y0=0, X1=159, Y1=199, INK=3)
```

> `hires` / `mc` / `text` on the disk are **serialized dicts**, not source —
> `LOAD` deserializes the object and you use it directly. Other examples
> (`asm`, `master`, `mastermind`) ship as source strings; you still call them
> with `()` to execute. The build picks the right packer per file (see
> `OBJECT_EXAMPLES` in the Makefile).

Notes:
- Methods take **keyword args** (e.g. `H.PLOT(X=.., Y=..)`) — Admiral binds
  string-function args by name.
- `SHOW`/`CLEAR`/`COLOR`/`PLOT` are native `CALL`-asm (fast). `DRAW` is an
  Admiral-level Bresenham over `PLOT` — fine for short lines, slower for long
  ones (the loop is interpreted).
- The graphics display replaces the text screen, so the REPL prompt isn't
  visible while a bitmap mode is showing — call `TEXT.SHOW()` to get it back.
  These libraries are meant to be driven from a program.
- The routines and their VIC register values are documented in `tools/gfx.asm`.
