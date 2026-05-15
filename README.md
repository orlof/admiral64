---

<h1>ADMIRAL/C64 - Operating Environment for the Commodore 64</h1>

Admiral is an easy-to-use all-in-one operating environment, ported from its
original DCPU-16 home to the Commodore 64. It requires no toolchains and
comes bundled with an efficient high-level programming language. Admiral's
mix of straightforward design and a few well-chosen architectural tricks
make it a comfortable little playground for scripting and rapid
experimentation on the C64.

---

<i>yes, it's hard to write code with 40 columns and 25 rows...<br>
yes, it's hard to fit IDE, runtime and application software into 64K<br>
...and yes, it's hard to coax a 1 MHz 6510 into doing variable-length
arithmetic on a kitchen-table integer with hundreds of digits!<br>

But we did not enlist on this old breadbin because it is fast, but because
it is small.</i>

---

<h4 id="1">Background</h4>

<h5 id="1.1">Summary</h5>

<h6>What this is</h6>

Admiral/C64 is a self-hosted environment that boots straight from a `.PRG`
on disk and gives you:

 - an interactive REPL with line editing and auto-printing of expressions,
 - a Python-inspired language with dynamic typing, first-class strings-as-functions,
   exceptions, and `me`-bound methods inside dicts,
 - a gap-buffer text editor (`edit()`) for writing programs without leaving Admiral,
 - a 1541 floppy filesystem with object-graph `save()` / `load()`,
 - variable-length integers (limited only by heap), 48-bit floats, lists,
   tuples, dicts, booleans, and `None`,
 - a mark-and-sweep garbage collector for the dynamic heap.

Everything is written in 6510 assembly and assembles into one ~30 KB
`admiral.prg`. There is no operating system underneath — Admiral *is* the
operating system once it loads.

<h6>Design Philosophy</h6>

 - The C64 must provide a self-sufficient environment for developing and
   running software — no host PC, no cross-assembler, no swapping discs to
   reach a compiler.
 - Capability is more important than capacity. We'd rather have arbitrary-
   precision integers and a real garbage collector than another 4 KB of
   speed.
 - Users shouldn't be bothered with details that the machine can handle.
 - A bug in user code should not be allowed to lead to undefined behaviour
   of the interpreter (except `poke()` and `call()`, where you signed the
   waiver yourself).
 - There should be no fixed limit on the range of numbers, the length of
   strings, or the size of collections — only the total memory available.

<h6>Implementation Principles</h6>

 - "First have fun. Then make it work. Then make it right. Then make it fast."
 - This is, frankly, a toy. It exists for the intellectual fun of squeezing
   a modern-feeling language into 8-bit constraints and for the joy of
   wrestling with the 6510. It is **not** a performance-tuned production
   runtime — large stretches of the code could easily be made 2-5x faster
   with a profiler, an AST cache, and a few weekends.
 - Everything written in pure 6510 assembly (KickAssembler syntax).
 - Memory split, rounded:
   - ~50% heap (data + handles, ~30 KB across the upper-RAM gaps)
   - 1 KB software root stack (RS) + 1 KB software frame stack (FS)
   - the rest is interpreter code under $8000
 - Direct one-pass Pratt-parser interpreter — no bytecode, no AST cache.
   Slow, but compact and obvious.
 - Mark-and-sweep GC handles reference cycles.
 - Floppy `save` / `load` walks the live object graph, so cycles and
   shared references round-trip safely.

<h6>C64-Specific Tricks</h6>

The C64 hands you 64 KB of address space and then immediately covers most
of the interesting parts with ROM. The interpreter is built around making
that ROM appear and disappear at exactly the moments it helps:

 - **Steady state with everything banked out.** `$01 = $34` (MEM_NORMAL)
   keeps BASIC ROM, KERNAL ROM, *and* the I/O page banked out. The full
   upper RAM (`$A000-$BFFF`, `$C000-$CFFF`, `$D000-$DFFF`, `$E000-$FFF7`)
   is plain read/write memory for the heap. We get nearly the entire 64 KB
   for our own use.
 - **Floating point is borrowed from BASIC.** All the hard FP work —
   `FADDT`, `FMULTT`, `FDIVT`, `INT`, plus the transcendentals `SIN`,
   `COS`, `TAN`, `ATN`, `EXP`, `LOG`, `SQR` — are JSRs into the original
   MS-BASIC ROM at `$A000-$BFFF`. Each call site briefly flips `$01` to
   MEM_FP (`$37` — BASIC + KERNAL + I/O all in), runs the routine using
   MS-BASIC's 5-byte FAC1/FAC2 format, and flips back. Saved us writing
   a fresh 48-bit FP library from scratch, and the polynomial coefficients
   are already in ROM for free.
 - **Disk I/O is borrowed from KERNAL.** `LOAD`, `SAVE`, `DIR`, `RM` all
   talk to the real 1541 through KERNAL's `OPEN` / `CHKIN` / `CHRIN` /
   `CHROUT` / `CLOSE` (`$FFC0`, `$FFC6`, `$FFCF`, `$FFD2`, `$FFC3`). Same
   pattern as FP: flip `$01` to MEM_KERNAL (`$36`) only for the bracketed
   KERNAL call, then back to MEM_NORMAL. The KERNAL never sees our heap.
 - **Keyboard reads use KERNAL too.** `KERNAL_GETIN` (`$FFE4`) and
   `KERNAL_SCNKEY` (`$EA87`) feed our `getc()`. Bracketed bank flip again.
 - **I/O page only when we actually need it.** Screen writes and color
   RAM (`$0400`, `$D800`) need I/O visible, so they happen under MEM_IO
   (`$35`) — KERNAL stays banked out. This keeps a 4 KB chunk of `$E000`
   addressable as heap most of the time.
 - **The 256-byte 6502 stack carries almost no payload.** Admiral has two
   private software stacks — RS (handle root stack, scanned by GC) and FS
   (frame stack for V4' calling convention) — each 1 KB, both growing
   downward in zero-page-pointed RAM. The hardware stack at `$0100-$01FF`
   only carries 6502 return addresses and the occasional `pha` scratch.
 - **Self-modifying dispatch.** A single `_fp_basic_envelope` thunk
   handles every BASIC FP call — the FP routine address is patched into
   the JSR operand at the call site (`basic_op` macro). Each FP site
   shrinks from ~28 bytes to ~13. Same trick lets one `KERNAL_call`
   wrapper handle every $FFxx vector. These savings are how we fit a
   GC'd, big-int, exception-aware interpreter under `$8000`.
 - **Ternary search tree for builtin names.** Looking up `PRINT` or
   `RANGE` walks a flat TST in ROM — no string-compare loops, just a few
   indirect loads. Saves space and time compared with a linear table.
 - **PETSCII uppercase, native.** The display starts in the unshifted
   character set, so source code, keywords, and string literals are all
   PETSCII uppercase (`$41-$5A`). No ASCII↔PETSCII translation tax in the
   lexer or REPL. `π` and the cursor character are the only special-cased
   glyphs.

None of this is novel — every C64 demo coder reaches for the same
toolbox. The fun is in stacking the tricks together so that a Python-like
language with arbitrary-precision integers comfortably fits into the
machine your parents threw out in 1990.

<h6>Status & Caveats</h6>

This is a personal-fun project, not a polished product:

 - The interpreter is one-pass and could be a lot faster. There is no AST
   cache. Each call to a string-as-function re-lexes and re-parses the
   body.
 - The integer routines could be tightened — divmod still has a few
   easy bytes to shed.
 - Error reporting is minimal. You get a one-byte error code and a
   recovery to the prompt; line numbers and source positions are
   on the wishlist.
 - There is no virtual memory, no multitasking, no colour graphics, no
   sound. Just enough to play with the language.

If you're here to learn how a 6510 actually feels under your fingers when
you have to count cycles and bank ROMs in and out by hand, welcome.
That's what this is for.
