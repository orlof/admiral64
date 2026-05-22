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
...and yes, it's hard to coax a 1 MHz 6510 into running a garbage-collected,
dynamically-typed language at all!<br>

But we did not enlist on this old breadbin because it is fast, but because
it is small.</i>

---

What this is

Admiral64 is a self-hosted environment that boots from a `.PRG` on disk and gives you:

 - an interactive REPL with line editing and auto-printing of expressions,
 - a Python-inspired language with dynamic typing, first-class strings-as-functions, exceptions, and `me`-bound methods inside dicts,
 - a gap-buffer text editor (`edit()`) for writing programs without leaving Admiral,
 - a 1541 floppy filesystem with object-graph `save()` / `load()`,
 - 32-bit signed integers (two's-complement, wraparound on overflow), 48-bit floats, lists, tuples, dicts, booleans, and `None`,
 - a mark-and-sweep garbage collector for the dynamic heap,
 - native 6510 extensions via `call()` — drop to machine code for inner loops (see [EXTENSIONS.md](EXTENSIONS.md)),
 - hi-res (320×200) and multicolor (160×200) bitmap graphics via a `reboot()` memory-mode switch plus on-disk drawing libraries (`hires`, `mc`, `text`).

Everything is written in 6510 assembly and assembles into one ~30 KB `admiral.prg`. There is no operating system underneath — Admiral *is* the operating system once it loads.

<h6>Implementation Principles</h6>

 - "First have fun. Then make it work. Then make it right. Then make it fast."
 - This is, frankly, a toy. It exists for the intellectual fun of squeezing a modern-feeling language into 8-bit constraints and for the joy of wrestling with the 6510. It is **not** a performance-tuned production runtime — large stretches of the code could easily be made 2-5x faster or smaller with a profiler, an AST cache, and a few weekends.
 - Everything written in pure 6510 assembly (KickAssembler syntax).
 - Memory split, rounded:
   - ~50% heap (data + handles, ~30 KB across the upper-RAM gaps)
   - 1 KB software root stack (RS) + 1 KB software frame stack (FS)
   - the rest is interpreter code under $8000
 - Direct one-pass Pratt-parser interpreter — no bytecode, no AST cache. Slow, but compact and obvious.
 - Mark-and-sweep GC handles reference cycles.
 - Floppy `save` / `load` walks the live object graph, so cycles and shared references round-trip safely.

<h6>C64-Specific Tricks</h6>

The C64 hands you 64 KB of address space and then immediately covers most half of it of it with ROM. The interpreter is built around making that ROM appear and disappear at exactly the moments it helps:

 - Steady state keeps BASIC ROM, KERNAL ROM, and the I/O page banked out. The full upper RAM is plain read/write memory for the heap.
 - Floating point is borrowed from BASIC.
 - Disk I/O and keyboard reads are borrowed from KERNAL.
 - I/O page only when we actually need it.
 - The 256-byte 6502 stack carries almost no payload. Admiral has two private software stacks — RS (handle root stack, scanned by GC) and FS (frame stack for calling convention) — each 1 KB - leaving 30 KB for HEAP. The hardware stack at only carries 6502 return addresses and the occasional `pha` scratch.

None of this is novel — every C64 demo coder reaches for the same toolbox. The fun is in stacking the tricks together to mimic Python-like language with limited resources.

<h6>Status & Caveats</h6>

This is a personal-fun project, not a polished product:

 - The interpreter is one-pass and could be a lot faster.
 - Integers are fixed 32-bit and wrap on overflow (no arbitrary precision); only division by zero traps.
 - Error reporting is minimal. You get a one-byte error code and a recovery to the prompt.
 - Bitmap graphics exist (hi-res + multicolor) but switching into them is a `reboot()` into a smaller-heap memory config, not a live mode flip. No sprites, no sound, no virtual memory, no multitasking. Just enough to play with the language.
