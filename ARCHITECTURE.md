# Architecture

Structural reference for the C64 port of Admiral: register file, stacks, ABI, heap layout, calling convention, and leaf helpers.

> **What lives in this document.** Static structural facts about the codebase as it is *right now*: ZP layout, calling convention, GC mechanics, file responsibilities, and known implementation-level deferred optimizations. Read this when you need to *understand the codebase*.
>
> **What lives elsewhere:**
> - **`ROADMAP.md`** — feature-stage progress and what's next on the spine to a working REPL. Read when you need to *know what to ship*.
> - **`PLANS/stage*.md`** — detailed implementation plans for in-flight or recently-completed stages. Read when you're *implementing a stage*.
>
> Anything that's a per-feature stage (lexer, parser, REPL, disk) belongs in ROADMAP. Anything that's a code-level polish item ("merge these two helpers", "swap algorithm X for Y") belongs in this document's *Deferred optimizations* section.

## Zero-page pseudo-register file

The 6502's zero page ($00-$FF) is treated as an extended register file. Names below are `.const` aliases defined in `src/defs.asm`.

| Name | ZP addr | Size | Purpose |
|---|---|---|---|
| `FSP` | $02 | 2B | Frame stack pointer — top of FS (moves on `fs_push`/`fs_pop`) |
| `RSP` | $04 | 2B | Root stack pointer — top of RS (moves on `rs_push`/`rs_pop`) |
| `FP` | $06 | 2B | Frame base pointer — stable base of current routine's frame (set by preamble) |
| `RV` | $0E | 2B | Return value — volatile; not saved/restored across calls |
| `W0`..`W3` | $10..$17 | 2B × 4 | Word pseudo-registers — 16-bit scalars, pointers for `(zp),y` indirection |
| `B0`..`B7` | $18..$1F | 1B × 8 | Byte pseudo-registers — lengths, counters, small scalars |
| `NEXT_HANDLE` | $20 | 2B | Bump allocator: next free handle slot (grows DOWN) |
| `NEXT_DATA` | $22 | 2B | Bump allocator: next free data byte (grows UP) |
| `ALLOC_SIZE` | $24 | 2B | Alloc input: caller-preset payload size (0..$FFFF) |
| `ALLOC_TYPE` | $26 | 1B | Alloc input: caller-preset type tag |
| `ERROR_CODE` | $27 | 1B | Fatal-error code written before `jmp error_handler`. $00 = none; `ERR_OOM` = $01; `ERR_DIV_ZERO` = $02; `ERR_OVERFLOW` = $03; `ERR_LEX` = $04; `ERR_TYPE` = $05; `ERR_ARITY` = $06; `ERR_DISK` = $07 |
| `FREE_HEAD` | $28 | 2B | Head of free-handle list ($0000 = empty); chained via H_NEXT, LIFO |
| `ALLOC_GC_TRIED` | $2A | 1B | Internal: marks that alloc already ran gc_collect this call (once-only retry) |
| `RESERVED_HEAD` | $2B | 2B | Head of the live-handle list ($0000 = empty). Chained via H_NEXT; appended at tail by alloc, kept in H_PTR-ascending order |
| `RESERVED_TAIL` | $2D | 2B | Tail of the live-handle list ($0000 = empty) |
| `GC_DEST` | $2F | 2B | `gc_compact` walker: current destination for live data. Also reused by `screen_scroll_up` as the dst pointer to `mem_copy_down` (GC re-inits it at the start of every compact, so sharing is safe). |
| `RV2` | $31 | 2B | Secondary return value — volatile; used by dual-return routines (e.g. `int_divmod` returns quotient in RV, remainder in RV2). **Word — occupies $31-$32.** |
| `SCREEN_ROW` | $33 | 1B | Current screen cursor row (0..24). |
| `SCREEN_COL` | $34 | 1B | Current screen cursor column (0..39). |

**Register discipline** (V4'):
- `W0..W3` and `B0..B7` are **preserved across V4' calls** via `preamble`/`postamble` (saved to the frame, restored on return).
- `RV` is **volatile**: callee writes the word return, caller reads it before making further calls that might clobber it.
- `RV2` is **volatile** and used only by dual-return routines. Same discipline as `RV` — read it before the next call that could clobber it.
- `A` is volatile byte return / byte arg slot.
- **Never split a `Wn` into byte halves** — if you need bytes, use `Bn`. Preamble saves all 16 bytes at `$10..$1F` contiguously.

## Stacks

| Stack | Location | Top pointer | Base pointer | GC-visible? | Purpose |
|---|---|---|---|---|---|
| **HW stack** | $0100-$01FF | 6502 S register | — | no | JSR/RTS return addresses + preamble's scratch PHA/PLA |
| **FS** (frame stack) | $2000-$23FF | `FSP` | `FP` (per-routine base) | no | Preamble frames, caller-pushed non-handle args, body-level scratch |
| **RS** (root stack) | $2400-$24FF | `RSP` | — | **yes** | Live handle pointers — caller-pushed handle args, intermediate roots. GC linearly scans. |

Both software stacks grow DOWN. Pointer (top) = "most recently pushed word"; empty = region-end. Push pre-decrements the top pointer; pop post-increments.

`FP` is distinct from `FSP`: it's the stable base of the current routine's frame, set once by preamble and not moved during the body. Bodies access saved regs via `(FP, 0..15)` and caller's non-handle args via `(FP, 22..)`. Bodies can freely `fs_push`/`fs_pop` without disturbing `FP`.

## Handle struct (8 bytes)

Offsets from a handle address; constants in `src/defs.asm`.

| Offset | Name | Size | Meaning |
|---|---|---|---|
| 0 | `H_PTR` | 2B | Pointer to the heap object (at the object's start — includes length header) |
| 2 | `H_SIZE` | 2B | Bytes reserved in the heap for this object (capacity) |
| 4 | `H_NEXT` | 2B | Linked-list pointer — reserved for GC free/reserved lists |
| 6 | `H_TYPE` | 1B | Type tag (pure value; no bits stuffed into it) |
| 7 | `H_FLAGS` | 1B | GC state + future bits |

`SIZEOF_HANDLE` = 8.

**Invariant**: handles never move in memory. Only the heap data they point to moves during GC compaction.

### Flag bits (`H_FLAGS`)

| Bit | Name | Meaning |
|---|---|---|
| $80 | `FLAG_MARKED` | Mark-sweep GC mark bit |
| $40 | `FLAG_GRAY` | Reserved for tri-color marker (marked but children untraced) |
| $20 | `FLAG_PINNED` | Reserved — don't relocate data during compact |
| $00..$10 | free | Available for future use |

## Heap object layout

Every heap object — ints, strings, lists, dicts, whatever — opens with the same 2-byte length header.

```
[len_lo, len_hi, payload ...]
```

| Offset | Name | Size | Meaning |
|---|---|---|---|
| 0 | `O_LEN` | 2B | Type-specific used-count: bytes for bigints, elements for lists, entries for dicts |
| 2 | `O_HEADER` | — | Constant = 2. Offset where payload starts. |

**Distinction**: `O_LEN` (object) = used count; `H_SIZE` (handle) = reserved capacity. For immutable objects they coincide; for resizable containers they diverge.

## Type tags (placeholder scheme)

Pure enumerated values for now. When container/numeric group tests become
performance-critical, these may move to a bitfield layout — the numbers will
change but the names are stable.

| Name | Value | Type |
|---|---|---|
| `TYPE_INT`   | $20 | signed variable-length integer |
| `TYPE_STR`   | $21 | byte string; payload is raw bytes, O_LEN = byte count |
| `TYPE_BOOL`  | $22 | singletons `TRUE` / `FALSE` (statics.asm). Payload byte distinguishes them so a hypothetical fresh bool still byte-compares correctly. |
| `TYPE_NONE`  | $23 | singleton `NONE` (statics.asm). Empty payload. |
| `TYPE_TUPLE` | $24 | immutable handle sequence. **O_LEN is element count, not byte count** — payload bytes are 2 × O_LEN. Children are 16-bit handle pointers; null slots are stored as `$0000`. |
| `TYPE_LIST`  | $25 | mutable handle sequence; same payload shape as tuple. **Capacity ≥ O_LEN**: `H_SIZE - O_HEADER == 2 * capacity`, `O_LEN == used count`. Append uses slack capacity; on overflow, `_array_grow` reallocates the payload (data only, no new handle) via `heap_carve_payload` and rewires `H_PTR` + `H_SIZE`. The old payload bytes become orphan and are reclaimed by the next gc_compact. |
| `TYPE_DICT`  | $26 | sorted array of (key, value) 2-tuples. **Same payload shape as list** — only the type tag and the per-mutation algorithm differ. Lookup is binary search by key (val_cmp on tuple slot `DICT_KEY=0`). Insertion: bin-search for slot, then `array_insert` (or overwrite on hit). Deletion: bin-search, then `array_del`. O(log n) lookup, O(n) modification. Mirrors Admiral's `dict2.dasm16`. |
| `TYPE_FLOAT` | $27 | 5-byte MS-Basic packed float. Heap object O_LEN = 5; payload is `[exp, sign+m_hi, m_2, m_3, m_4]` (sign in bit 7 of byte 1, hidden 1 implicit). Leaf type — no GC tracing of children. Operations wrap BASIC ROM FP routines (FAC1 @ $61-$66, FAC2 @ $69-$6E). Bank flip via `inc $01` / `dec $01` so A/X/Y survive the switch. |

### Container types share one substrate (`array.asm`)

Tuple, list, and dict all have the same payload layout (N × 16-bit handle pointers, `O_LEN` = element count). The shared primitives live in `array.asm`; type-specific files are thin wrappers:

| Operation | Lives in | Aliased as |
|---|---|---|
| `_array_alloc_init` (alloc + zero + fix O_LEN) | `array.asm` | called by `tuple_alloc`, `list_alloc`, `dict_alloc` |
| `array_get` | `array.asm` | `tuple_get` = `list_get` (co-located labels) |
| `array_len` | `array.asm` | `tuple_len` = `list_len` = `dict_len` |
| `array_set` / `array_set_leaf` | `array.asm` | `list_set`, `tuple_set_leaf` |
| `array_append` | `array.asm` | `list_append` |
| `array_insert` / `array_del` | `array.asm` | `list_insert`, `list_del`; used by `dict_set` / `dict_del` for sorted-position mutation |
| `_array_shift_up_leaf` / `_array_shift_down_leaf` | `array.asm` | private helpers for insert / del |
| `_array_grow` | `array.asm` | private; doubles capacity (min 4 elements) via `heap_carve_payload` |
| `_gc_trace_array` | `gc.asm` | gc_mark dispatch for all three container types |
| Element-wise val_eq / val_cmp recursion | `val.asm` | all three via type-tag dispatch |

Type-specific files are tiny:
- `tuple.asm` — only `tuple_alloc`.
- `list.asm` — only `list_alloc`. Mutation surface (`list_set`, `list_append`, `list_insert`, `list_del`) is co-located labels in `array.asm`.
- `dict.asm` — `dict_alloc`, `_dict_bin_search`, `dict_get`, `dict_set`, `dict_del`. Reuses `array_insert`/`array_del`/`array_set_leaf` for storage; only the binary-search overlay is dict-specific.

### Generic 3-way comparison: `val_cmp`

Mirrors Admiral's `val_cmp` (`stdlib.dasm16:158`):

1. Same handle → `0`.
2. Different types → numeric type-tag compare (`$FF` if a's tag is lower, `$01` if higher).
3. Same type → per-type body:
   - `TYPE_INT` / `TYPE_BOOL` → `int_cmp` (signed, byte-by-byte from MSB)
   - `TYPE_STR` → byte-wise lexicographic (unsigned). Shorter prefix is "less".
   - `TYPE_TUPLE` / `TYPE_LIST` / `TYPE_DICT` → element-wise recursion. First non-zero result wins; if all common-prefix elements match, the shorter sequence is "less".
   - `TYPE_NONE` / unknown → `0`.

Returned in A as `$FF` (a<b), `$00` (a==b), or `$01` (a>b). Args consumed.

### `RESERVED` list invariant: H_PTR-ascending

`gc_compact` walks the live-handle list once in alloc-tail order and slides each handle's payload down to fill gaps. The walk is correct iff every handle's `H_PTR` is at or above `GC_DEST` when it's processed — i.e., the list is in `H_PTR`-ascending order.

Plain `alloc` preserves this naturally (NEXT_DATA only grows up, so each new handle is appended with the highest `H_PTR`). But `_array_grow` calls `heap_carve_payload` to reassign an *existing* handle's `H_PTR` to a new (higher) address — and that handle was already somewhere in the middle of `RESERVED`. Without intervention, compact would later copy the regrown handle's payload over not-yet-processed bytes belonging to handles with lower `H_PTR` that come *after* it in the list, silently corrupting the heap.

Fix: after the H_PTR/H_SIZE rewrite, `_array_grow` calls `_relink_to_tail` (`alloc.asm`) to unlink the handle from its current `RESERVED` position and append it to the tail. The new `H_PTR` is by construction the highest among all live handles, so the tail position keeps the list sorted.

### Generic equality (`val_eq`, val.asm)

Type-agnostic equality with four short-circuits, in order:

1. **Handle identity** — same address → equal. Catches all singleton compares (TRUE/TRUE, NONE/NONE, INT_0/INT_0, etc.) without touching the heap.
2. **Type tag mismatch** → not equal. (`TYPE_INT [$00] != TYPE_BOOL [$00]` because the tags differ.)
3. **Length mismatch** → not equal. (For normalized ints, different byte length implies different value by the normalization invariant.)
4. **Byte-by-byte payload compare** — straight `cmp (W2),y` / `cmp (W3),y` loop from MSB down.

This skeleton handles every leaf type (int, str, bool, none, future data). Containers will need a recursive comparator on top — but the four-step short-circuit chain stays as the entry point.

## Memory map

Target C64 runtime config: `$01 = $36` — LORAM=0 (BASIC ROM off), HIRAM=1 (KERNAL on), CHAREN=1 (I/O at $D000). Set by `boot:` in `admiral.asm` before running the inits.

### Full address space

| Range | Size | Role |
|---|---|---|
| `$0000-$0001` | 2 B | CPU port / bank config — never stored to for data |
| `$0002-$0056` | 85 B | **Our ZP** — pseudo-register file + allocator + (future) GC state |
| `$0057-$008F` | 57 B | **Reserved for BASIC FP workspace** — FAC1 @ $61, FAC2 @ $69, CHRGET routine @ $73-$8A. Untouched so FP routines work without save/restore when BASIC is flipped on. |
| `$0090-$00FA` | 107 B | KERNAL ZP — screen editor, keyboard, IEC. Untouched. |
| `$00FB-$00FE` | 4 B | Spare ZP |
| `$00FF` | 1 B | BASIC float-to-ASCII scratch |
| `$0100-$01FF` | 256 B | HW stack (6502) |
| `$0200-$03FF` | 512 B | KERNAL workspace + vectors |
| `$0400-$07FF` | 1 KB | **VIC-II text screen** ($0400-$07E7 used; screen codes, NOT PETSCII) |
| `$0801-$7FFF` | ~30 KB | Our code + BSS. `$0801` holds the BASIC upstart (`10 SYS2061`); `boot:` at `$080D`. |
| `$8000-$83FF` | 1 KB | **FS** — frame stack (~45 nested 22-byte frames) |
| `$8400-$87FF` | 1 KB | **RS** — root stack (512 handle slots) |
| `$8800-$CFFF` | ~18 KB | **Heap** — data grows UP from $8800, handles grow DOWN from $D000 (just below VIC I/O) |
| `$D000-$DFFF` | 4 KB | I/O: VIC-II ($D000-$D3FF, incl. `$D020` border = `$0D` light green, `$D021` bg = `$05` dark green), SID, CIAs, Color RAM ($D800-$DBE7 — 4-bit per cell, dual-ported, default `$0D`) |
| `$E000-$FFFF` | 8 KB | KERNAL ROM |

The code segment is capped at `$8000` — `admiral.asm` ends with a KickAss `.if (* > $8000) { .error }` guard so an overflow into stack/heap territory fails the build.

### Heap constants (`defs.asm`)

| Constant | Value | Role |
|---|---|---|
| `HEAP_DATA_START` | `$8800` | Data heap grows UP from here |
| `HEAP_HANDLE_START` | `$D000` | Handle table grows DOWN from here |

### Stack constants (`stacks.asm`)

| Constant | Value | Role |
|---|---|---|
| `FS_BEGIN` | `$8000` | Frame stack low bound (inclusive) |
| `FS_END` | `$8400` | Frame stack high bound (empty FSP sentinel) |
| `RS_BEGIN` | `$8400` | Root stack low bound |
| `RS_END` | `$8800` | Root stack high bound (empty RSP sentinel) |

### BASIC FP interop

BASIC ROM is not mapped during normal operation. To call BASIC's floating-point routines (FAC1 @ `$61-$66`, FAC2 @ `$69-$6E`, FMULTT @ `$BA2B`, etc.) we bracket the JSR with a one-byte bank flip:

```asm
inc $01               // BASIC on  ($36 → $37)
jsr <fp routine>
dec $01               // BASIC off ($37 → $36)
```

`inc`/`dec` over `lda #imm; sta $01` because the latter clobbers A — register-form binary FP ops (FADDT, FMULTT, FDIVT) need `A = FAC1 exp` *at JSR time*, and GIVAYF takes `A = high byte` / `Y = low byte` of the input integer. `inc $01` preserves all three registers.

The `$57-$8F` ZP reservation means BASIC's FP workspace finds its scratch intact across flips. CHRGET at `$73-$8A` was installed by BASIC's power-on init (we boot via the normal KERNAL reset → BASIC init → SYS chain) and remains valid even while BASIC ROM is unmapped. FP errors jump through `$0300` (IERROR); we don't redirect this yet, so out-of-range inputs to QINT etc. would be undefined behavior. `float_div` and `float_to_int` pre-check for the cases that would trigger BASIC's error vector and panic with `ERR_DIV_ZERO` / `ERR_OVERFLOW` instead.

**WARNING — `FIN` ($BCF3) clobbers ZP $22-$2F.** BASIC's ASCII-to-float routine uses INDEX1/INDEX2 (`$22-$25`) and adjacent slots as scratch during its multiply-by-10 digit accumulator. Our allocator state (`NEXT_DATA` `$22`, `ALLOC_SIZE` `$24`, `RESERVED_HEAD` `$2B`, `GC_DEST` `$2F`, etc.) lives in that exact range. **`str_to_float` saves and restores `$22-$2F` around the FIN call.** The other FP routines we wrap (FADDT, FMULTT, FDIVT, NEGOP, QINT, FOUT, GIVAYF) appear NOT to touch this range — confirmed empirically — but if a new BASIC ROM call is added to the codebase, verify it doesn't write below $57 or save/restore around it. Long-term cleaner fix: relocate allocator state to ZP $42+ (in the safe `$35-$56` window).

### VIC-II / graphics — currently bank 0, future bank 3

Current configuration: VIC-II reads its DRAM from bank 0 ($0000-$3FFF), the
default at reset. Screen RAM is at `$0400`, character ROM is visible to VIC at
`$1000`/`$9000` (it's always shadowed there from VIC's bus perspective, even
when the CPU sees I/O at `$D000` — CHAREN controls the CPU view, not the
VIC view). Color RAM is always at `$D800-$DBFF` regardless of bank. KERNAL is
kept mapped for disk I/O and the 60 Hz IRQ that drives keyboard scanning.

For hi-res graphics later we'll migrate VIC to bank 3 (`$C000-$FFFF`):

| Region | Role after migration |
|---|---|
| `$C000-$C3FF` | screen RAM (1 KB) |
| `$C800-$CFFF` | custom charset in RAM (2 KB) — ROM charset is NOT visible to VIC in bank 3, so a boot-time copy from `$D000` via a temporary I/O-off bank config is required |
| `$E000-$FFFF` | 8 KB hi-res bitmap "under KERNAL" — VIC sees RAM, CPU sees KERNAL ROM. Classic C64 trick. |

The migration is a screen-base change plus ~30 lines of boot code. Deferred
until hi-res is an actual requirement — current text mode uses ROM charset
for free.

## Calling convention (V4')

Every V4' routine wraps its body as:

```asm
my_routine:
    preamble_args(H, N)       // H handle args on RS, N non-handle args on FS
    // ... body — freely uses W/B regs, rs_push/fs_push, calls sub-routines ...
    // write result to RV (word) and/or A (byte) before exit
    jmp postamble
```

### Frame on FS (22 bytes)

Allocated by preamble, addressed via `FP`:

| Offset | Content |
|---|---|
| 0..15 | Saved W0-W3, B0-B7 |
| 16..17 | `target_RSP` = RSP-at-entry + 2·H (pre-arg-push RSP) |
| 18..19 | Saved caller's FP |
| 20..21 | `target_FSP` = FSP-at-entry + 2·N (pre-arg-push FSP) |
| 22.. | Caller-pushed non-handle args (accessed via `fs_peek_arg`) |

### Callee-pops, symmetric for both stacks

Postamble restores `RSP → target_RSP`, `FSP → target_FSP`, `FP → saved_caller_FP`. Effect: **both stacks return to their values from BEFORE the caller pushed args**. Caller-pushed args and any intermediate `rs_push`/`fs_push` the body did are all swept together.

`RV` is a ZP slot, not on any stack — it passes transparently through postamble, so results can be forwarded through nested calls without re-pushing.

### Responsibilities

**Caller**:
- Push handle args to RS (order: deepest first; last push is callee's "arg 0").
- Push non-handle args to FS (same ordering rule).
- `jsr callee`.
- Read RV / A on return.
- No cleanup — callee auto-consumed everything.

**Callee**:
- `preamble_args(H, N)` with exact arg counts.
- Body reads handle args via `rs_peek_at(reg, depth)`, non-handle args via `fs_peek_arg(reg, depth)` (both 0-indexed from top).
- Body freely pushes intermediates; they'll be swept by postamble.
- Write result to RV (and/or A) before exit.
- `jmp postamble`.

### The "no-GC window" invariant

`alloc` returns its new handle in `RV` only — **it does not push to RS**. The caller is responsible for rooting:

```asm
lda #<size
sta ALLOC_SIZE
lda #>size
sta ALLOC_SIZE+1
jsr alloc_int         // RV = new handle (NOT rooted)
rs_push(RV)           // root — must be the NEXT action, no jsr between
```

Between `jsr alloc_int` returning and the `rs_push(RV)`: no `jsr`, no macro that expands to a `jsr`. The window is 3–4 instructions, trivially auditable. Violating it means the fresh handle is only referenced by RV at the moment a sub-call could trigger GC — i.e., it's collectable garbage.

### Allocator calling convention

`alloc` takes its size and type via the ZP slots `ALLOC_SIZE` (word) and `ALLOC_TYPE` (byte) rather than registers:

- Caller writes both ZP slots immediately before the `jsr alloc`. No intervening `jsr` is permitted — another alloc anywhere in between would overwrite the pre-set size/type.
- `alloc_int` is a 3-instruction wrapper that presets `ALLOC_TYPE = TYPE_INT` then jumps to `alloc`; callers of `alloc_int` only need to set `ALLOC_SIZE`.
- OOM is fatal: see [Fatal panic](#fatal-panic). Callers can assume `alloc` and `alloc_int` succeed and always return a valid handle in `RV`.

### OOM check

Before carving a handle or bumping `NEXT_DATA`, alloc verifies:

```
need = ALLOC_SIZE + O_HEADER + (SIZEOF_HANDLE if FREE_HEAD == 0 else 0)
need <= NEXT_HANDLE − NEXT_DATA
```

If any step of the 16-bit addition carries out, the request is already wider than the address space and we trap without computing the gap.

### Reserved + free lists

Every allocated handle is on exactly one linked list via `H_NEXT`:

- **Reserved list** (`RESERVED_HEAD` → … → `RESERVED_TAIL`) — live handles. Appended at the tail on alloc. Because `NEXT_DATA` grows monotonically, list order is always H_PTR-ascending. Sweep and compact both walk this list in O(N).
- **Free list** (`FREE_HEAD` → …) — unallocated handles. LIFO.

`alloc` reuses a freed handle before carving a new one:

1. If `FREE_HEAD != 0`: pop the head, unlink via `H_NEXT`, populate fresh.
2. Otherwise: carve by decrementing `NEXT_HANDLE` by `SIZEOF_HANDLE`.

Either way, the populated handle is appended to `RESERVED_TAIL`.

Reuse recycles the handle record only. The old payload bytes at `H_PTR` linger as dead data on the heap until `gc_compact` reclaims them.

### OOM-triggered GC retry

On the first OOM check failure within a single `alloc` call, `alloc` runs `gc_collect` once and re-checks. If the second pass also fails, `alloc` stores `ERR_OOM` in `ERROR_CODE` and jumps to `error_handler` — it does not return. The retry flag is a per-call internal byte (`ALLOC_GC_TRIED`), cleared at each `alloc` entry.

`gc_collect` reclaims both handle-table entries (via sweep) and heap data bytes (via compact), so retry can recover from either kind of pressure as long as some unrooted handles exist.

## Fatal panic

Rather than burn bytes on error-return machinery at every call site, failing routines write an `ERR_*` code to `ERROR_CODE` then `jmp error_handler`. The handler restores the stack pointers from a snapshot the REPL captured at boot (`repl_rec_*` in `repl.asm`), closes any leaked disk channels (`disk_close_data` + `disk_close_cmd`), prints `?ERR XX`, and jumps back to `repl_loop` for a fresh prompt. The persistent root scope stays on RS because the snapshot points just past it — globals defined before the panic survive.

Panic codes:
- `ERR_OOM` ($01) — `alloc` after unsuccessful GC retry.
- `ERR_DIV_ZERO` ($02) — `int_divmod` (and wrappers `int_div`, `int_mod`); `float_div` when the divisor is exactly zero.
- `ERR_OVERFLOW` ($03) — `float_to_int` out of range, etc.
- `ERR_LEX` ($04) — lexer (illegal char, unterminated string, bad number).
- `ERR_TYPE` ($05) — operator / builtin given an operand of the wrong type.
- `ERR_ARITY` ($06) — wrong number of arguments to a builtin.
- `ERR_DISK` ($07) — 1541/IEC reported a non-zero status code, or a disk-builtin name validation failed.

Callers can assume success — no return-value check is needed.

## GC cycle

One `gc_collect` pass:

1. **Mark** — tri-color worklist using `FLAG_MARKED` and `FLAG_GRAY` together.
   - Phase 1: walk RS from `RSP` to `RS_END`. OR `FLAG_MARKED|FLAG_GRAY` into each root's `H_FLAGS` (white → gray).
   - Phase 2: scan the reserved list. For every gray handle, clear `FLAG_GRAY` (gray → black); if it's a container, OR `FLAG_MARKED|FLAG_GRAY` into each unmarked child. Repeat until a clean pass finds no gray handles. O(N²) worst case; fine at our scale.
   At exit, every reachable reserved handle is black (MARKED, !GRAY). Static handles may retain GRAY — harmless because nothing else reads it.
2. **Sweep** — walk the reserved list once. For each handle:
   - Marked: clear `FLAG_MARKED`, relink into rebuilt reserved list.
   - Unmarked: prepend onto `FREE_HEAD`.
   Reserved list is rebuilt in place via a running "previous survivor" pointer; the last survivor's `H_NEXT` is zeroed as the new tail.
3. **Compact** — walk the rebuilt reserved list sequentially. Copy each handle's `H_SIZE` bytes down to `GC_DEST`, update its `H_PTR`, advance `GC_DEST`. Finally `NEXT_DATA = GC_DEST`. O(N), no sort — the list is already in H_PTR-ascending order thanks to alloc's tail-append invariant.

Sweep and compact never visit free handles or un-carved handle slots — they traverse only the reserved list — so stale H_PTRs on garbage handles are never dereferenced.

Because compact moves live data, callers must not cache a payload pointer across any `jsr` that could trigger GC (i.e. any `jsr` that eventually reaches `alloc`). In practice: `deref` a handle to its payload only *after* the last allocating sub-call in the current body.

## Deferred optimizations

Code-level polish items: known wins that aren't worth doing until a need shows up. These are *implementation* improvements (smaller code, faster code, same semantics). Stage-level *feature* work belongs in `ROADMAP.md`, not here.

### Integer

- **Short division by an 8-bit scalar inside `int_divmod`.** Admiral's `int_division` (src/integer.dasm16:1066) dispatches to one of three algorithms: 16/16 word division, n-byte/8-bit short division, or general n/n bit-by-bit. Our `int_divmod` always takes the slow n/n path. The n/8 variant walks bytes MSB→LSB carrying the remainder across, giving a ~5–10× speedup for scalar divisors — notably `int_to_str` which repeatedly divides by `INT_10`. Drop-in swap inside `int_divmod`'s entry dispatch when we need it.

- **Unified decimal + hex formatting via a `HEX` table.** Admiral's `int_to_str` uses one routine for both bases by indexing a 16-entry `HEX` ASCII table (src/integer.dasm16:245). Our `int_to_str` hard-codes `adc #'0'` — decimal-only. Adding a `HEX` table + a base parameter (or a separate `int_to_hex` sharing the loop body) unifies both outputs at the cost of one 16-byte table.

- **Small-integer interning.** Admiral uses static handles `INT_N1`, `INT_0..INT_16` liberally but does not (in this codebase) intern alloc results against them. A wrapper over `alloc_int` that returns a static when `ALLOC_SIZE == 1 && payload < 17` would cut alloc pressure for common literals. We currently ship three statics (INT_0, INT_1, INT_10) but the hit-rate will be low until we have an interpreter producing many small ints.

### Float (Stage 6 follow-ups)

- **`int_to_float` via FLOATC at $BC44.** Current implementation (~215 bytes) walks the int byte-by-byte, calling GIVAYF + FADDT per byte. BASIC's internal FLOATC at `$BC44` converts a 32-bit signed BE int at `$62-$65` directly. Pad/sign-extend our LE int into that slot and `JSR $BC44` with `X = $A0` and we're done in ~50 bytes. **Cost**: caps at signed 32-bit (panic on longer ints — but MS-Basic float only has 32 mantissa bits so values past 2³² already round, making the cap matched to the format). Dependency on the undocumented `$BC44` entry — low risk on C64 (one stable BASIC ROM rev). Saves ~150 bytes. *Note*: this would re-introduce the asymmetry with `float_to_int` (which now does unbounded bigint extraction) — only do it if size pressure demands it.


### Float (still-missing features)

These are *features*, not optimizations, but they're scoped to Stage 6's surface so they're called out here for visibility:

- **`str_to_float`.** Deferred from Stage 6. Needs the BASIC `CHRGET` routine present in ZP `$73-$8A`. CHRGET is installed by BASIC ROM's power-on init; if we boot via the standard SYS-from-BASIC chain it's already there. Verify on real hardware before wiring `JSR FIN` ($BCF3).

- **INT/FLOAT cross-type promotion in `val_eq`/`val_cmp` and arithmetic.** Currently `val_cmp(int 1, float 1.5)` orders by type tag, not numeric value; arithmetic ops require both operands of the same type. Both can be added by promoting INT to FLOAT before the same-type path. ~50 bytes of dispatch wiring.

## Leaf helpers

Some routines intentionally skip `preamble`/`postamble` — they're optimized for speed and size, not ABI uniformity. A routine qualifies as a **leaf helper** when all of these hold:

1. **Does not allocate** (no `jsr alloc` anywhere in it or its callees) — can't trigger GC.
2. **Does not call any V4' routine** — no preamble to push/pop, no auto-cleanup relied upon.
3. **Small and hot** — inlining would cost more than the ABI mismatch.
4. **Documents its exact contract in the comment header** — in, out, and clobbers.

Current leaf helpers:

| Routine | In | Out | Clobbers |
|---|---|---|---|
| `deref_W0_to_W2` | W0 (handle) | W2 (payload ptr), A (length) | A, X, Y. W2 written. |
| `deref_W1_to_W3` | W1 (handle) | W3 (payload ptr), A (length) | A, X, Y. W3 written. |
| `deref_RV_to_W2` | RV (handle) | W2 (payload ptr), A (length) | A, X, Y. W2 written. |
| `sign_byte_W2` | A (length), W2 (payload ptr) | A ($00 or $FF) | A, Y. W2 preserved. |
| `sign_byte_W3` | A (length), W3 (payload ptr) | A ($00 or $FF) | A, Y. W3 preserved. |
| `gc_mark` | RSP (implicit), RESERVED_HEAD | All reachable reserved handles end up MARKED + !GRAY. Tri-color: phase 1 sets gray on roots, phase 2 drains gray by tracing container children to fixed point. | A, X, Y, W0-W3, B0 |
| `_gc_trace_seq` | W0 (sequence handle — tuple or list) | Each unmarked child has MARKED+GRAY ORed in. Null slots skipped. | A, X, Y, W2, W3 (W0/W1 preserved) |
| `gc_sweep` | RESERVED_HEAD + handle mark bits | Reserved list rebuilt in place from survivors; unmarked handles prepended to FREE_HEAD. Survivors' FLAG_MARKED cleared | A, Y, W0-W3 |
| `gc_compact` | RESERVED_HEAD | Walks reserved list in order (H_PTR-ascending by alloc invariant). Each handle's H_SIZE bytes slide down to GC_DEST; H_PTR updated; NEXT_DATA = end of packed region. O(N). | A, Y, W0-W3, GC_DEST |
| `gc_collect` | — | Full cycle: `gc_mark` → `gc_sweep` → `gc_compact` | A, X, Y, W0-W3, B0, GC_DEST |
| `seq_set_leaf` (= `tuple_set_leaf`) | W0 (container), W1 (child), A (slot index) | Container slot at index A holds W1 | A, Y, W2 (W0/W1 preserved) |
| `mem_copy_down` | W2 (src), GC_DEST (dst), W3 (count) | W3 bytes copied src→dst (forward; safe only when src > dst). GC_DEST advanced by count; W2+1 advanced by count's high byte. | A, X, Y, W2+1, GC_DEST. W0, W1, W3, B0-B7 preserved. Shared with `screen_scroll_up`. |
| `screen_init` | — | VIC border + bg set, color RAM filled with COLOR_FG, screen cleared, cursor reset | A, X |
| `screen_clear` | — | Screen RAM → $20 everywhere, cursor reset | A, X |
| `screen_put_char` | A (PETSCII byte) | One char rendered at cursor (with PETSCII→screen-code translation), cursor advanced, scroll if overflow | A, X, Y, W2, W3, GC_DEST (on scroll). W0, W1, B0-B7 preserved. |
| `screen_scroll_up` | — | Rows 1-24 slide up to 0-23; row 24 blanked | A, X, Y, W2, W3, GC_DEST |

Callers: leaf helpers are called from **inside** a V4' body that has already done its preamble. The caller "owns" the W/B regs in a scratch sense — the preamble saved the outer caller's values, so the V4' body is free to let leaves clobber them.

Things that would disqualify a would-be helper from leaf status:
- Calling `alloc` or `alloc_int`.
- Calling any `int_*` or other V4' routine.
- Needing to save state across an internal sub-call.

## GC and memory management concepts

| Term | Meaning |
|---|---|
| **handle** | Fixed-address 8-byte record referencing a heap object |
| **heap object** | Variable-length data block at a handle-pointed address, with `O_LEN` header |
| **payload** | The bytes of a heap object *after* the length header |
| **bump allocator** | Advances `NEXT_DATA` (up) and `NEXT_HANDLE` (down) when carving fresh records. Combined with a free-handle LIFO and a tail-appended reserved list, so mark-sweep-compact recycles both handles and data bytes. |
| **mark-sweep** | Two-phase GC: mark all reachable handles, free the unmarked ones |
| **compaction** | Post-mark phase that slides surviving data down to fill gaps |
| **handle indirection** | User code holds handles, not data pointers → data can move without invalidating user references |
| **GC roots** | Handles reachable from outside the heap. For us, every handle on RS is a root; nothing else is scanned. |
| **tri-color marking** | GC state where objects are white (unscanned), gray (scanned but children untraced), or black (fully traced) |
| **normalization** | For signed variable-length ints, stripping redundant leading sign bytes so `[$02, $00]` becomes `[$02]` |
| **sign extension** | Filling higher bytes with $00 (non-negative) or $FF (negative) to promote a shorter int to a longer one |
| **LSB / MSB** | Least / most significant byte. Little-endian — LSB at payload[0] |

## 6502 / assembly terms

| Term | Meaning |
|---|---|
| **ZP** | Zero page, the first 256 bytes of RAM ($00-$FF), with special short-encoded addressing modes |
| **HW stack** | Hardware stack, fixed at $0100-$01FF, managed by S register + JSR/RTS/PHA/PLA |
| **`(zp),y`** | Indirect-indexed addressing: read pointer from zero-page slot, add Y, dereference |
| **`(zp,x)`** | Indexed-indirect addressing: add X to zp slot, read pointer, dereference (rarely used here) |
| **`abs,y`** | Absolute indexed: `addr + Y` as operand location |
| **A / X / Y** | 6502's three 8-bit registers |
| **S** | 6502's stack pointer register (implicit in the $0100-$01FF hardware stack) |
| **C / N / Z / V flags** | Carry, negative, zero, overflow — status bits |
| **ADC / SBC** | Add / subtract with carry. Multi-byte arithmetic chains these with the C flag |
| **PHA / PLA** | Push A to / pull A from HW stack |
| **ASL / LSR / ROL / ROR** | Arithmetic/logical shift, rotate (left/right) |
| **JSR / RTS** | Jump to subroutine / return from subroutine |
| **SMC** | Self-modifying code — patching instruction bytes at runtime |
| **fastcall** | Calling convention using registers (not stack) to pass arguments |

## Toolchain

| Tool | Role |
|---|---|
| **Kick Assembler** (`kickass`) | The 6502 assembler we use. Java-based. |
| **py65** | Pure-Python 6502 emulator, used by our pytest suite |
| **VICE** (`x64sc`) | Full C64 emulator — for running `.prg` files as if on hardware |
| **.prg** | C64 program file format: 2-byte load address header followed by raw bytes |
| **.vs** | VICE label file (Kick Assembler emits this with `-vicesymbols`); maps `label` → address, consumed by our Python test harness |

## Admiral / DCPU-16 reference

When we say "Admiral" or cite line numbers like `integer.dasm16:783`, we mean the original DCPU-16 implementation at `../src/` (repo root). We're porting a subset of its functionality to 6502.

| Term | Meaning |
|---|---|
| **DCPU-16** | The fictional 16-bit CPU designed for the cancelled game 0x10c |
| **Admiral** | The Python-inspired language + runtime that runs on DCPU-16 |
| **`preamble`/`postamble`** | Admiral's per-frame save/restore routines (`src/stdlib.dasm16`). V4' adopts the same model, with symmetric auto-cleanup for RS and FS. |
| **`num_refs`** | Admiral's per-frame count of GC-rootable local slots — we don't use this model (the root stack is uniformly scanned instead) |

## File layout shorthand

| Path | What |
|---|---|
| `src/admiral.asm` | Top-level assembler entry — imports all modules |
| `src/defs.asm` | Constants only — ZP register file, handle struct, heap layout, type tags |
| `src/stacks.asm` | FS/RS regions, init routines, push/pop/peek macros, callable wrappers |
| `src/preamble.asm` | Shared `preamble` / `postamble` + `preamble_args(h, n)` macro |
| `src/handle.asm` | Leaf helpers: `deref_W0_to_W2`, `deref_W1_to_W3`, `deref_RV_to_W2`, `sign_byte_W2`, `sign_byte_W3` |
| `src/alloc.asm` | Bump allocator with free + reserved lists: `alloc_init`, `alloc`, `alloc_int`. Returns handle in RV; does not touch RS. Panics on OOM after GC retry. Also `heap_carve_payload` — bumps NEXT_DATA without carving a handle, used by `_list_grow`. |
| `src/gc.asm` | Mark-sweep-compact GC: `gc_mark` (tri-color, traces container children to fixed point via `_gc_trace_seq`), `gc_sweep`, `gc_compact`, `gc_collect`, `mem_copy_down`. Reserved list (live handles) walked in H_PTR-ascending order for O(N) compact; free list threaded via `H_NEXT`, LIFO. |
| `src/array.asm` | Shared container substrate for tuple / list / dict: `_array_alloc_init`, `array_get` / `array_len` / `array_set`, `array_append` / `array_insert` / `array_del`, `_array_grow`, `_array_shift_up_leaf` / `_array_shift_down_leaf`. Per-type names (`tuple_*`, `list_*`, `dict_len`, etc.) are co-located labels at the same body — single implementation, multiple names. |
| `src/tuple.asm` | TYPE_TUPLE allocator only: `tuple_alloc(N)` thin V4' wrapper around `_array_alloc_init`. All other tuple ops are aliases living in `array.asm`. |
| `src/list.asm` | TYPE_LIST allocator only: `list_alloc(N)`. Mutation surface (`list_set`, `list_append`, `list_insert`, `list_del`) is aliased in `array.asm`. |
| `src/dict.asm` | TYPE_DICT primitives: `dict_alloc`, `_dict_bin_search`, `dict_get`, `dict_set`, `dict_del`. Built on top of `array_insert` / `array_del` / `array_set_leaf` — no new payload layout. |
| `src/val.asm` | Generic value-level comparison: `val_eq` (boolean equality) and `val_cmp` (3-way ordering). Both dispatch by type tag with element-wise recursion for containers. TYPE_FLOAT routes `val_cmp` to `float_cmp`; bytewise compare for `val_eq` works because MS-Basic's canonical-zero invariant (exp=0 ⇒ all bytes zero) means equal values have identical packed bytes. |
| `src/float.asm` | TYPE_FLOAT primitives, all wrappers around BASIC ROM FP routines. Public: `float_alloc`, `float_add/sub/mul/div`, `float_neg`, `float_cmp`, `int_to_float` (variable-length int → 5-byte float), `float_to_int` (5-byte float → variable-length int via manual mantissa+exponent extraction; covers full MS-Basic magnitude range), `float_to_str`. Leaf helpers: `_fp_unpack_to_fac1`, `_fp_unpack_to_fac2`, `_fp_pack_from_fac1`, `_fp_load_left_right`, `_fp_alloc_and_pack`. Bank flip via `inc $01` / `dec $01`. |
| `src/int_*.asm` | V4' integer primitives: `int_add`, `int_sub`, `int_negate`, `int_normalize`, `int_sgn`, `int_cmp`, `int_mul` (8×8 kernel inlined), `int_divmod` (long-division core, returns quotient in RV and remainder in RV2), `int_div`, `int_mod` (thin wrappers over divmod), `int_to_str` (decimal render via repeated divmod by static `INT_10`, using FS as the digit-reversal buffer) |
| `src/str.asm` | String primitives: `str_alloc` convenience wrapper (parallel to `alloc_int`). Strings share the bigint heap layout — payload is raw bytes, `O_LEN` is byte count. |
| `src/statics.asm` | Pinned handle+object constants baked into the assembled binary. Current set: `INT_0`, `INT_1`, `INT_10`, `STR_BANNER`, `TRUE`, `FALSE`, `NONE`, `FLOAT_ZERO`, `FLOAT_ONE`. Address-disjoint from the heap, never on RESERVED/FREE — GC structurally skips them. |
| `src/screen.asm` | Direct VIC-II text output (bypasses KERNAL CHROUT): `screen_init`, `screen_clear`, `screen_put_char` (PETSCII → screen-code), `screen_scroll_up` (reuses `mem_copy_down`). All leaf helpers. |
| `src/keyboard.asm` | KERNAL GETIN facade: `kbd_getchar` (blocking), `kbd_poll` (non-blocking). V4'. |
| `src/print.asm` | High-level output: `print_str`, `print_int`, `println_str`, `println_int`. All V4'. `print_int` wraps `int_to_str` → `print_str`. |
| `build/admiral.prg` | Assembled binary |
| `build/admiral.vs` | VICE label file (used by tests) |
| `tests/conftest.py` | pytest harness — builds sources, loads `.prg` into py65 MPU, sets up stacks |
| `tests/test_*.py` | Test cases per subsystem |
