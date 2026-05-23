# Writing native extensions for Admiral64

Admiral has a value type, `TYPE_CODE`, whose payload is **position-independent
6510 machine code**. Call it like any other function: `f(args)` and Admiral
JSRs into the bytes. This lets you drop down to native speed for inner loops
(graphics, fast scans, hardware pokes) without rebuilding the interpreter.

```
DOUBLE = CODE("\xA0\x00\xB1\x12\x0A\x85\x10\xA9\x00\x85\x11\x60")
PRINT(DOUBLE(21))             -- 42
```

A `TYPE_CODE` value is just bytes plus a type tag — build one from a string
literal with `CODE("\xNN...")`, generate one with the `asm.admiral` assembler
(`A.GO()` returns `TYPE_CODE`), or `LOAD` it from disk.

---

## Calling: `code(arg1, ..., arg5)`

- **`code`** — any `TYPE_CODE` value. Admiral SMC-patches a JSR with the
  payload's first byte and jumps to it.
- **`arg1..arg5`** — 0 to 5 positional arguments. Each argument's **handle
  address** is placed in one of the ZP registers below.
- **Returns** — the 16-bit value your routine leaves in `W0`, zero-extended to
  a non-negative inline integer (0..65535).

| Slot | Holds |
|------|-------|
| `W0` (`$10:$11`) | **your code's own load address** (handy for `JMP (zp)` loops) |
| `W1` (`$12:$13`) | arg 1 handle |
| `W2` (`$14:$15`) | arg 2 handle |
| `W3` (`$16:$17`) | arg 3 handle |
| `B0:B1` (`$18:$19`) | arg 4 handle (16-bit indirect via `(B0),Y`) |
| `B2:B3` (`$1A:$1B`) | arg 5 handle (16-bit indirect via `(B2),Y`) |
| `B4..B7` (`$1C-$1F`) | free scratch |

More than 5 args → `ERR_ARITY`. The call dispatcher itself is in `parser.asm`
(`_llp_code_call`); the `CODE(str)` factory is `builtin_code` in `builtins.asm`.

---

## The ABI

### Zero-page pseudo-registers (the "safe set")

Your routine may freely use these as scratch — Admiral's state does **not** live
here across a code call:

| Name | ZP addr | Width |
|------|---------|-------|
| `W0`..`W3` | `$10`..`$17` | 16-bit each |
| `B0`..`B7` | `$18`..`$1F` | 8-bit each (contiguous, so `B0:B1` and `B2:B3` work as 16-bit indirect ptrs) |

`A`, `X`, `Y` are scratch too. **Do not touch any other zero-page address** —
`$02-$06` (stack pointers), `$20-$2F` (allocator), `$42-$46` (scope), and the
BASIC FP workspace (`$57-$70`) are load-bearing. Staying inside `W`/`B`/`A`/`X`/
`Y` is the whole contract.

### Reading arguments

Each arg slot holds the **handle address** of the argument. How you read the
data depends on the argument's type:

- **Integer** — the value lives *inline* in the handle: 4 little-endian bytes at
  `(slot)+0..3` (low byte first). For a small int just read the low byte:

  ```asm
  ldy #0
  lda (W1),y          ; low byte of int arg 1
  ```

- **String** (or list/dict/tuple) — the handle's first two bytes are a pointer
  to the heap object; the object's payload starts `O_HEADER` (2) bytes in, with
  a 16-bit length at offset 0:

  ```asm
  ldy #0
  lda (W1),y : sta $30        ; H_PTR lo  (use any free ZP for the deref ptr)
  iny
  lda (W1),y : sta $31        ; H_PTR hi
  ; ($30)+0..1 = length, ($30)+2.. = bytes
  ```

### Returning a value

Leave a 16-bit result in `W0` (`$10` lo, `$11` hi) and `RTS`. The dispatcher
reads it and hands back a non-negative inline int. If your routine is a pure
side-effect (e.g. plotting a pixel), wrap the user-facing method body to
discard the result — see how `gfx_pack.py` appends `\nNONE` to keep the REPL
quiet.

---

## The rules

1. **Leaf only.** Your code must **not allocate** and must **not call back into
   Admiral**. Admiral's garbage collector only runs during allocation; because
   a leaf never allocates, the GC cannot fire while your code is executing, so
   the code blob cannot be relocated out from under the running PC. (Between
   calls the blob may move freely — the dispatcher re-finds it every time.)

2. **Position-independent.** The blob can sit anywhere in the heap, so:
   - Branches (`BNE`, `BCC`, …) are fine — they're PC-relative.
   - **No `JSR`/`JMP` to your own labels** and no absolute references into your
     own bytes — the absolute address isn't known until load time.
   - Absolute addressing to *fixed* locations is fine: hardware registers
     (`$D000`+), KERNAL, zero page.
   - For loops bigger than ±127 bytes: use `W0` (your own load address) +
     assembly-time offset to build an indirect-JMP target. See
     [Big loops](#big-loops-using-w0) below.

3. **Balance the hardware stack.** Every `PHA`/`PHP` paired before `RTS`. The
   dispatcher pushes the return address; an unbalanced routine returns into
   garbage.

4. **Own your banking.** Steady state is `$01 = $34` (BASIC/KERNAL/I/O all
   banked *out*; the heap can live under those ROMs). Plain RAM and zero page
   are reachable as-is. To touch I/O — VIC (`$D000-$D02E`), color RAM
   (`$D800`), SID, CIA — flip `$01` to `$35` (or `$36` for KERNAL) yourself
   and restore it before returning. Reads/writes of the bitmap region in
   graphics mode are plain RAM and need no flip.

---

## Worked examples

**Return a constant** — `LDA #42 ; STA W0 ; LDA #0 ; STA W0+1 ; RTS`:

```
F = CODE("\xA9\x2A\x85\x10\xA9\x00\x85\x11\x60")
F()                          -- 42
```

**Double an int argument** — `arg1` is in `W1`:

```
;  LDY #0 ; LDA ($12),Y ; ASL ; STA $10 ; LDA #0 ; STA $11 ; RTS
F = CODE("\xA0\x00\xB1\x12\x0A\x85\x10\xA9\x00\x85\x11\x60")
F(21)                        -- 42
```

**Add two int arguments** — `arg1` in `W1`, `arg2` in `W2`:

```
;  LDY #0 ; LDA ($12),Y ; CLC ; ADC ($14),Y ; STA $10 ; LDA #0 ; STA $11 ; RTS
F = CODE("\xA0\x00\xB1\x12\x18\x71\x14\x85\x10\xA9\x00\x85\x11\x60")
F(30, 12)                    -- 42
```

---

## Big loops: using `W0`

If your routine's per-iteration body is more than ±127 bytes, a backward
branch from the loop tail to the loop top can't reach. You can't use
`JMP loop_top` either — that's an absolute address into your own relocatable
code.

The fix: `W0` carries your own load address on entry. Add an assembly-time
constant offset to compute a pointer to your loop label, store it in fixed
RAM, and finish each iteration with `JMP (zp)` — an indirect jump through
fixed RAM, which *is* PI-safe.

```asm
routine_start:
        clc
        lda W0
        adc #<(loop_top - routine_start)
        sta DLOOP            ; some fixed RAM cell (e.g. in the graphics
        lda W0+1             ; reserved region, or any non-load-bearing addr)
        adc #>(loop_top - routine_start)
        sta DLOOP+1
        ; … one-time setup; W0 may be repurposed now …
loop_top:
        ; … big iteration body, branches anywhere inside …
        jmp (DLOOP)          ; only "JMP" PI code is allowed to use
```

The worked example is `HIRES_DRAW` in `tools/gfx.asm` — see how it uses one
`DLOOP` cell for both the dispatch relay (`hd_x_relay`) and the loop tail.

---

## Authoring

- **By hand**: write the bytes as a `\xNN` string literal, then wrap with
  `CODE(...)` to mark it callable.
- **With the assembler**: `asm.admiral` (a two-pass 6510 assembler written in
  Admiral) turns assembly text into a `TYPE_CODE` value — write `LDA`, `STA`,
  labels and branches instead of hex. `A.GO()` returns `TYPE_CODE` directly,
  ready to call.
- **From disk**: `SAVE` a `TYPE_CODE` value (or a dict containing one), `LOAD`
  it in later sessions. See `tools/pack_object.py` for how the graphics
  extensions get pre-baked dicts with `TYPE_CODE` slots straight onto the disk.

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
| Screen RAM | `$DC00–$DFE7` | per-8×8-cell fg/bg colors (1000 B) |
| Bitmap | `$E000–$FF3F` | 320×200 pixels (8000 B) |
| Row table + scratch | `$FF40–$FFF9` | 25-word bitmap-row table + draw scratch |
| Vectors | `$FFFA–$FFFF` | IRQ/NMI/RESET (untouched) |

Three disk libraries provide the modes — each a dict of methods over native
`TYPE_CODE` primitives, generated by `tools/gfx_pack.py` from `tools/gfx.asm`:

Two ways to invoke each operation:
- **Wrapper method** (e.g. `H.COLOR`) — a `TYPE_STR` lambda that returns NONE
  (so the REPL stays quiet). String-lambdas bind args by **keyword**:
  `H.COLOR(FG=1, BG=6)`. Positional `H.COLOR(1, 6)` errors with ERR_LEX.
- **Native slot** (e.g. `H._COLOR`) — the underlying `TYPE_CODE`, callable
  positionally and a touch faster: `H._COLOR(1, 6)`. Returns the 16-bit `W0`
  the routine left, which the REPL will auto-print (often a stale pointer).

```
REBOOT(TRUE)                 -- enter the graphics config (do this first)
H = LOAD("HIRES")            -- mono 320x200 — file IS the dict, no ()
H.SHOW()                     -- VIC -> hi-res (row table at $FF40 pre-built)
H.COLOR(FG=1, BG=6)          -- kwarg form, REPL-quiet
H.CLEAR()                    -- zero the bitmap   (CLS is a reserved word)
H.PLOT(X=160, Y=100)         -- set a pixel
H.DRAW(X0=0, Y0=0, X1=319, Y1=199)   -- Bresenham line
LOAD("TEXT").SHOW()          -- restore the text display
```

Multicolor (160×200, 4 colors per cell — `00`=`$D021` bg, `01`/`10` from the
screen RAM, `11` from color RAM):

```
M = LOAD("MC")
M.SHOW()
M.COLOR(C01=1, C10=2, C11=7)
M.PLOT(X=80, Y=100, INK=2)              -- ink 0..3
M.DRAW(X0=0, Y0=0, X1=159, Y1=199, INK=3)
```

> `hires` / `mc` / `text` on the disk are **serialized dicts** containing both
> `TYPE_CODE` slots (`_SHOW`, `_PLOT`, …) and `TYPE_STR` wrappers (`SHOW`,
> `PLOT`, …) — `LOAD` deserializes the object and you use it directly. Other
> examples (`asm`, `master`, `mastermind`) ship as `TYPE_STR` source you call
> with `()` to execute. The build picks the right packer per file
> (`OBJECT_EXAMPLES` in the Makefile).
