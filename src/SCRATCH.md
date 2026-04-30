⏺ Free function (built-in) comparison

  Both have (16) ✓

  len, range, bool, int, float, str, chr, ord, abs, cmp, hex, repr, type, id, sort, rnd

  That covers everything in the C64 port today.

  Admiral-only — by category

  ┌───────────────────┬───────────────────────────────────────────┬────────────────────────────────────────────────┐
  │       Group       │                 Functions                 │                     Notes                      │
  ├───────────────────┼───────────────────────────────────────────┼────────────────────────────────────────────────┤
  │ Statements (not   │ print, del                                │ both ports already have these as statements    │
  │ fns)              │                                           │                                                │
  ├───────────────────┼───────────────────────────────────────────┼────────────────────────────────────────────────┤
  │ Console I/O       │ input, edit, getc, key, format            │ edit invokes the gap-buffer text editor — huge │
  │                   │                                           │  subsystem                                     │
  ├───────────────────┼───────────────────────────────────────────┼────────────────────────────────────────────────┤
  │ Screen / cursor   │ cursor, scroll, wget, wset, sound         │ small, doable                                  │
  ├───────────────────┼───────────────────────────────────────────┼────────────────────────────────────────────────┤
  │ Filesystem        │ load, save, rm, dir                       │ needs floppy driver port                       │
  ├───────────────────┼───────────────────────────────────────────┼────────────────────────────────────────────────┤
  │ Reflection /      │ mem, locals, globals                      │ globals only meaningful once user-defined fns  │
  │ memory            │                                           │ land                                           │
  ├───────────────────┼───────────────────────────────────────────┼────────────────────────────────────────────────┤
  │ Low-level         │ peek, poke, call                          │ trivial, but design choice — do we expose raw  │
  │                   │                                           │ 6502 access?                                   │
  ├───────────────────┼───────────────────────────────────────────┼────────────────────────────────────────────────┤
  │ Hardware          │ hwn, hwq, hwi, time, sleep, read, write   │ DCPU-specific; C64 needs different primitives  │
  ├───────────────────┼───────────────────────────────────────────┼────────────────────────────────────────────────┤
  │ HIC/RCI radio     │ hsel, hinfo, hrecv, hsend, rconf, rinfo,  │ TechCompliant hardware; no C64 equivalent      │
  │                   │ rrecv, rsend                              │                                                │
  ├───────────────────┼───────────────────────────────────────────┼────────────────────────────────────────────────┤
  │ Hi-res graphics   │ hires, plot, point, line, circle          │ C64 has bitmap mode but needs separate plan    │
  └───────────────────┴───────────────────────────────────────────┴────────────────────────────────────────────────┘

  What's worth porting vs. dropping

  Easy + useful for an interactive port:
  - input(prompt) — biggest gap; needed before there's a real REPL
  - key() — non-blocking key poll
  - getc() — blocking key read
  - cursor(x, y), scroll(dx, dy), wget, wset — small helpers, screen module already exists
  - peek/poke/call — one-liners on top of existing alloc/handle primitives

  Reasonable medium effort:
  - sound(channel, freq[, dur]) — SID is a richer instrument than the DCPU speaker, so the API will probably diverge
  - time(), sleep() — needs raster IRQ or CIA timer wired up
  - hires, plot, point, line, circle — VIC bitmap mode; reuses the bresenham/midpoint algorithms unchanged
  - mem(), locals(), globals() — meaningful once scoping/user-fns land
  - format() — printf-style helper; admiral doesn't document it well

  Skip (DCPU-specific):
  - hwn, hwq, hwi, read, write, hsel, hinfo, hsend, hrecv, rconf, rinfo, rsend, rrecv — the C64 port has no analogous
  device model

  Big-ticket subsystems (own plans):
  - edit() — gap-buffer text editor
  - load/save/rm/dir — disk I/O (needs Kernal disk routines or equivalent)

  If you want a productive next slice, the highest-leverage chunk is the interactive console group: input, key, getc,
  cursor — they together turn the port from "evaluator" into "REPL". Want me to scope that?



FUNCTION PetsciiToScreenCode AS BYTE(Petscii AS BYTE) SHARED STATIC
    ASM
        ldx #$5e
        lda {Petscii}
        cmp #255
        beq _petscii_to_screencode_end
        lsr
        lsr
        lsr
        lsr
        lsr
        sty
        clc
        lda {_petscii_to_screencode},y
        adc {Petscii}
        tax
_petscii_to_screencode_end
        stx {PetsciiToScreenCode}
    END ASM
END FUNCTION

__petscii_to_screencode:
DATA AS BYTE $80, $00, $c0, $e0, $40, $c0, $80, $80
