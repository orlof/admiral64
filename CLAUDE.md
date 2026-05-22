# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Admiral64 is a self-hosted operating environment for the Commodore 64. It bundles an interactive REPL, a Python-inspired high-level interpreted language, a gap-buffer text editor, a 1541 floppy filesystem with object-graph serialization, and a mark-and-sweep GC — all written in pure 6510 assembly, fitting under the $8000 frame-stack base. Steady state runs with BASIC/KERNAL/I/O all banked out (`$01 = $34`), giving the heap nearly the full upper RAM ($A000-$FFF7).

This is a port of [orlof/dcpu-admiral](https://github.com/orlof/dcpu-admiral) (DCPU-16) — same language, same architecture, retargeted to the 6510.

The whole thing assembles into one `admiral.prg` (~30 KB). There is no library structure; `src/*.asm` files are pulled in via KickAssembler `#import` from `src/admiral.asm`.

## Build & tooling

Build system uses [KickAssembler](https://www.theweb.dk/KickAssembler/) and Python 3 for the test harness and content packers:

- Assembler: `java -jar $(HOME)/bin/KickAssembler/KickAss.jar`
- Test simulator: [py65](https://github.com/mnaberez/py65) (used by pytest harness)
- Disk image tool: VICE's `c1541` (default path `/Applications/vice-arm64-gtk3-3.9/bin/c1541` — override with `make C1541=...`)

Common targets:

- `make` — build `build/admiral.d64` (PRG + packed `examples/*.admiral` written to a fresh disk image).
- `make prg` — just `build/admiral.prg`.
- `make test` — `.venv/bin/pytest tests/` (~1600 tests, ~2 min in py65).
- `make clean` — remove `build/` and generated TST table.

The PRG loads at `$0801`; the entire interpreter must fit under `$8000` (where the software frame stack starts). The current top sits around `$7FFC` — keep an eye on this when adding code.

`tools/build_tst.py` generates `src/tst_builtins.asm` (ternary search tree for builtin name lookup) and is invoked automatically by make.

`examples/*.admiral` are user-space Admiral programs; `tools/pack_str_record.py` serializes each one as a single TYPE_STR record for `LOAD("name")` to consume.

## Architecture

### Single-binary layout
`src/admiral.asm` is the entry point: `.import`s `defs.asm` (constants) then every other module. KickAssembler scopes labels by file, but cross-module calls use the public label names directly (`jsr label_name`). The build link is purely the import graph in `admiral.asm`.

### Memory map (see `src/defs.asm`)
The 64 KB address space is partitioned at assembly time, with the C64's ROM overlays kept banked out by default:
- `$0801 .. ~$7FFC` — assembled code (the PRG load region).
- `$8000 .. $8400` — software frame stack (FS), 1 KB, grows DOWN. Holds V4' preamble frames.
- `$8400 .. $8800` — software root stack (RS), 1 KB, scanned linearly by GC.
- `$8800 .. $FFF8` — data heap. Data blocks grow UP from `$8800`; handle table grows DOWN from `$FFF8` (just below the IRQ/NMI/RESET vectors at `$FFFA-$FFFF`). Net heap is ~30 KB.

Heap allocation uses handle indirection (handles grow down from `HEAP_HANDLE_START = $FFF8`; data blocks grow up from `HEAP_DATA_START = $8800`). Mark-and-sweep GC triggers every `HEAP_GC_TRIGGER` allocations. Allocation is in `alloc.asm`; GC lives in `gc.asm`.

### $01 banking — load-bearing
Steady state is `$01 = $34` (MEM_NORMAL): BASIC + KERNAL + I/O all banked OUT. Brief bracketed flips:
- `$35` (MEM_IO) — I/O on for VIC/color RAM/CIA1 (screen + keyboard matrix)
- `$36` (MEM_KERNAL) — KERNAL + I/O on (disk routines, `KERNAL_GETIN`/`SCNKEY`)
- `$37` (MEM_FP)  — BASIC + KERNAL + I/O all on (BASIC ROM FP routines)

If you JSR into a ROM routine without flipping `$01` first, you'll hit RAM garbage at that address. The `basic_op` macro (in `float.asm`) handles BASIC-ROM FP calls via a shared self-modifying envelope (`_fp_basic_envelope`); KERNAL disk calls use a similar pattern in `disk.asm`.

### Type system
Values are tagged via the `H_TYPE` byte in the 8-byte handle struct (see `defs.asm`: `H_PTR`, `H_SIZE`, `H_NEXT`, `H_TYPE`, `H_FLAGS`). Type constants `TYPE_INT`, `TYPE_FLOAT`, `TYPE_STR`, `TYPE_LIST`, `TYPE_DICT`, `TYPE_TUPLE`, `TYPE_BOOL`, `TYPE_NONE`, plus internal types like `TYPE_SUB` (subscript lvalue), `TYPE_NAME`, `TYPE_REF`. Integers are **fixed 32-bit signed two's-complement, stored inline in the handle** — the value occupies `H_PTR` (low 16 bits) + `H_SIZE` (high 16 bits), no heap payload. `alloc_inline_int` creates them; `gc_compact` skips `TYPE_INT` (nothing to move). Arithmetic wraps mod 2³² (only divide-by-zero traps). See `int_util.asm` for the shared value helpers and `PLANS/fixed-32-integers.md`. Floats use MS-BASIC's native 5-byte FAC format (still boxed).

### Interpreter pipeline
- `admiral.asm` / `repl.asm` — entry, REPL loop, auto-print, scope mgmt, panic recovery
- `lexer.asm` — tokenizer (PETSCII uppercase keywords, `\n` `\r` `\t` `\\` `\"` `\'` `\0` `\xNN` string escapes)
- `parser.asm` — Pratt expression parser + statement parser, one-pass
- `builtins.asm` — built-in functions (`PRINT`, `INPUT`, `LEN`, `RANGE`, `TYPE`, `ABS`, `INT`, `FLOAT`, `STR`, `REPR`, `HEX`, `SIN`, `COS`, `TAN`, `ATAN`, `EXP`, `LOG`, `SQRT`, `RND`, `CMP`, `SORT`, `MEM`, `GLOBALS`, `LOCALS`, `PEEK`, `POKE`, `EDIT`, `LOAD`, `SAVE`, `DIR`, `RM`, `GETC`, ...)
- `tst_builtins.asm` (generated) — ternary search tree for builtin name lookup
- Per-type implementations: `int_*.asm` (arithmetic split across files), `float.asm` (bridges to BASIC ROM), `str.asm` / `str_to_float.asm`, `list.asm`, `array.asm`, `dict.asm`, `val.asm`

Execution is direct one-pass interpretation — strings are callable, and a function call re-lexes and re-parses the body. Trades speed for memory.

### V4' calling convention
Most non-leaf routines use `preamble_args(H, N)` / `postamble`:
- `H` RS args (handle pointers, GC-rooted), `N` FS args (non-handle bytes/words).
- Preamble saves caller's `W0..W3` (`$10-$17`) and `B0..B7` (`$18-$1F`) into a 22-byte frame on FS, plus target_RSP, target_FSP, caller's FP. The body then owns the W/B file freely.
- Postamble restores W/B, RSP, FSP, FP, A. `RV` (`$0E`) and `RV2` (`$31`) are NOT in the saved region, so callees set them before returning.
- Tail-call helpers: `postamble_set_rv_ax`, `postamble_peek_rv`, `postamble_pop_rv`, `postamble_return_none`, etc.
- `preamble_call(MIN, MAX)` for user-level calls: handles arity check + tuple-unpack of args.

### Subsystems
- `edit.asm` — gap-buffer text editor (`EDIT()`), F-key shortcuts: F1 save+exit, F3 cancel, F5 cut line, F7 paste. Supports horizontal + vertical scrolling on long lines and long buffers.
- `screen.asm` — VIC-II text mode (40x25, screen at `$0400`, color at `$D800`)
- `disk.asm` — KERNAL-based 1541 driver + object-graph serialization. `SAVE`/`LOAD` walk reference graphs (cycles and shared references preserved). 16-bit scalar lengths so individual STR/INT/etc. payloads can exceed 256 bytes.
- `keyboard.asm` — KERNAL `GETIN` via bracketed bank flip; IRQ/NMI handlers for RUN/STOP, RESTORE, and timer
- `print.asm` / `int_to_str.asm` / `val.asm` — string conversion + display

### Hardware
Mandatory: stock C64 + 1541-compatible drive (any serial-bus device that speaks the standard DOS — VICE's true-1541 emulation works, KERNAL routines do the talking). No optional hardware extensions yet (no SID/audio, no sprite/hi-res, no REU/cartridge).

## Working with this code

- The interpreter must fit under `$8000`. Run `make prg` and check `build/admiral.prg` size; the load address is in the first 2 bytes (LE) and `top = load + len - 2` must stay below `$8000`. There's usually only a few bytes of headroom.
- 6502 sign-bit gotcha: `bmi`/`bpl` on register/zp byte test BIT 7, not "value < 0". If a byte index can legitimately reach $80..$FF, use `cpx #0 / bne` or `txa / bne`, not `bpl`. See `int_divmod.asm` outer loop for an example fix.
- Macro vs subroutine for `fs_push_byte` / `fs_pop_byte`: macros expand to ~10-14 bytes inline. The `_call` subroutine forms (`fs_push_byte_call`, `fs_pop_byte_call`) are 3-byte JSRs — prefer them in any loop or any cold path where size matters more than 6 cycles.
- BASIC FP routines (FADDT, FMULTT, FDIVT, INT, SIN, COS, TAN, EXP, LOG, SQR, ATN) trash `$53..$70` (FAC1/FAC2 + scratch). Bracket every FP call with `_basic_zp_save` / `_basic_zp_restore` if you have anything live in zero page that overlaps.
- BASIC ROM is read with `$01 = $37` (MEM_FP); without that, you'll JSR into garbage RAM where ROM thinks it is. The `basic_op` macro handles this for you.
- KERNAL disk routines similarly need `$01 = $36` (MEM_KERNAL). The disk.asm wrappers do the flip.
- Tests use py65 — `tests/conftest.py` has `h` (plain), `hfp` (BASIC + KERNAL ROM loaded for FP tests), and `hd` (mocked 1541 via `KernalDiskMock`). py65 doesn't simulate banking — every address is RAM — so ROM loading is just `mpu.memory[$A000:$C000] = basic_rom`. Real-hardware behavior with `$01` flips is lost in tests; verify visually under VICE if banking semantics matter.
- `examples/*.admiral` are user-space Admiral programs. They get packed by `tools/pack_str_record.py` into single TYPE_STR records on the disk image, callable via `F=LOAD("NAME"); F()`. Source uses PETSCII uppercase — keywords (`IF`, `WHILE`, `RETURN`, ...), names, and string contents.
- `README.md` is the user-facing README. Keep it in sync when adding builtins or changing visible behavior.
