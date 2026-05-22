// -----------------------------------------------------------------------------
// Shared constants — ZP pseudo-register file, handle struct, heap layout.
// Pure definitions; emits no code.
// -----------------------------------------------------------------------------

#importonce

// --- Zero-page partition -----------------------------------------------------
// Target runtime config on real C64: $01 = $36 (BASIC off, KERNAL on, I/O on).
// BASIC ROM is flipped in only around calls to its FP routines (rare), so we
// split ZP along the boundary where BASIC's FP workspace begins:
//
//   $00-$01   CPU port / bank config — never used for data.
//   $02-$56   OURS. Pseudo-register file, allocator state, future GC state.
//   $57-$8F   RESERVED for BASIC FP workspace + CHRGET routine at $73-$8A.
//             BASIC's FP routines (FAC1 @ $61-$66, FAC2 @ $69-$6E, temporaries
//             @ $57-$60) write here when BASIC is switched on. Keeping our
//             data OUT of this range means no save/restore around FP calls.
//   $90-$FA   KERNAL ZP — keyboard, screen editor, IEC. Untouched.
//   $FB-$FE   Spare (always free on stock C64). Reserved for future use.
//   $FF       BASIC's float-to-ASCII scratch — leave alone.
//
// --- Calling convention (V4') ------------------------------------------------
//   - All W and B registers are PRESERVED across calls via preamble/postamble.
//   - RV (return value) is volatile — callee writes, caller reads.
//   - A is volatile byte-return / byte-arg slot.
//   - Handle args are passed on RS, popped by callee before returning.

.const FSP  = $02      // frame stack pointer (top of FS — moves on fs_push/fs_pop)
.const RSP  = $04      // root stack pointer  (top of RS — moves on rs_push/rs_pop)
.const FP   = $06      // frame base pointer  (stable within a routine; set by preamble)

.const RV   = $0E      // 16-bit volatile return value
.const RV2  = $31      // secondary 16-bit volatile return (dual-return routines)

// W0..W3: general-purpose 16-bit registers. Preserved by callee.
.const W0   = $10
.const W1   = $12
.const W2   = $14
.const W3   = $16

// B0..B7: general-purpose 8-bit registers. Preserved by callee.
.const B0   = $18
.const B1   = $19
.const B2   = $1A
.const B3   = $1B
.const B4   = $1C
.const B5   = $1D
.const B6   = $1E
.const B7   = $1F

// --- Allocator state (ZP) ----------------------------------------------------
.const NEXT_HANDLE = $20   // word: address of next free handle slot (grows DOWN)
.const NEXT_DATA   = $22   // word: address of next free data byte  (grows UP)
.const ALLOC_SIZE  = $24   // word: caller-preset payload size (0..$FFFF bytes)
.const ALLOC_TYPE  = $26   // byte: caller-preset type tag
.const ERROR_CODE  = $27   // byte: set before jumping to error_handler. $00 = none.
.const FREE_HEAD   = $28   // word: head of free-handle list (0 = empty)
                           //       chained via H_NEXT, LIFO (most recently freed first)
.const ALLOC_GC_TRIED = $2A // byte: alloc-internal. Set on first OOM within a
                           //       call to trigger gc_collect retry exactly once.
.const RESERVED_HEAD = $2B // word: head of live-handle list (0 = empty).
                           //       Chained via H_NEXT. Alloc appends to tail so
                           //       the list is in H_PTR ascending order, which
                           //       lets gc_compact walk it in O(N).
.const RESERVED_TAIL = $2D // word: tail of live-handle list (0 = empty)
.const GC_DEST     = $2F   // word: gc_compact's current destination walker
                           //       (also reused as dst ptr by screen_scroll_up's
                           //       call to mem_copy_down — safe because GC re-inits
                           //       GC_DEST at the start of every gc_compact)
.const B7_save_buf = $30   // byte: replace-pass-2 scratch — free ZP cell.

// --- Screen cursor state (ZP) -----------------------------------------------
// Note: RV2 above is a WORD at $31-$32, so cursor bytes start at $33.
.const SCREEN_ROW = $33    // byte: current row 0..24
.const SCREEN_COL = $34    // byte: current column 0..39

// --- Lexer state (ZP) -------------------------------------------------------
// Single-token pull model: one current token in ZP, parser drives via
// `lexer_advance`. Token spans use absolute pointers into the source-string
// payload, not indices — saves a 16-bit add per byte access. Source handle
// is held by the caller (e.g. parser) on RS so GC can't reclaim it; if a GC
// compact moves the payload mid-lex, we re-deref via _lexer_rebase
// (lexer.asm) which converts saved offsets back to absolute pointers.
.const LEX_SRC_HANDLE   = $35   // word: source TYPE_STR handle (kept on RS as a GC root)
.const LEX_PTR          = $37   // word: current scan cursor (absolute ptr into payload)
.const LEX_END          = $39   // word: one-past-last absolute ptr (LEX_PTR == LEX_END → EOF)
.const LEX_TOKEN_START  = $3B   // word: absolute ptr to first byte of current token
.const LEX_TOKEN_END    = $3D   // word: absolute ptr to one-past-last byte of current token
.const LEX_TOKEN_KIND   = $3F   // byte: TK_* kind of current token
.const LEX_INDENT_TARGET  = $40 // byte: indent the lexer wants to emit toward (set on newline)
.const LEX_INDENT_CURRENT = $41 // byte: indent already emitted (drives INDENT/DEDENT bursts)

// --- Runtime scope (Stage 9) ------------------------------------------------
// Two scope pointers:
//   CURRENT_SCOPE  — the *current* scope (changes on function entry/exit).
//                   Reads/writes by scope_get/scope_set go through here.
//   ROOT_SCOPE    — the program's top-level scope (set once at parser_eval
//                   start, never changes). Used as the parent-link target
//                   when a function call allocates a new local scope, so
//                   functions see globals + their own kwargs but NOT the
//                   caller's locals (Python lexical scoping). Mirrors
//                   Admiral's parser.dasm16:2024 invariant.
.const CURRENT_SCOPE = $42       // word: current scope (a TYPE_DICT handle)
.const ROOT_SCOPE   = $44       // word: program-level scope (immutable)
.const METHOD_RECEIVER = $46    // word: side-channel set by `led_dot` when
                                // a method-call follows (`obj.method(`).
                                // Read+cleared by led_lparen at call time.
                                // 0 = not a method call.

// --- GC throttle (Stage 9c) -------------------------------------------------
// Decremented once per alloc; on Z=1 we run mark+sweep (no compact) so dead
// handles return to FREE_HEAD before NEXT_HANDLE has to carve more. Mirrors
// DCPU's `heap_counter` (memory.dasm16:118). Init = 0 → first trigger after
// 256 allocs; counter wraps naturally and triggers every 256th alloc forever.
.const GC_COUNTER = $48         // byte: alloc → mark+sweep throttle

// --- NMI / Run-Stop pause infrastructure ------------------------------------
// PAUSE_BLOCKED is a counter (inc on disk-op entry, dec on exit). When non-
// zero, the NMI handler dismisses RESTORE silently — a banner + busy-wait
// while $01=MEM_KERNAL would re-enter into KERNAL ROM unpredictably. The
// counter form lets nested disk calls balance correctly. error_handler resets
// it to 0 so a panicking save/load doesn't leave it stuck.
.const PAUSE_BLOCKED = $49      // byte: NMI inhibit counter (0 = banner OK)

// NMI re-entry flag. RESTORE on the C64 is wired directly to /NMI through a
// 555 monostable, NOT through CIA2 — there is no CIA flag bit that latches
// "RESTORE was pressed". Detection of the second press is therefore purely
// software: first NMI entry sets NMI_PAUSED=1 and busy-waits for it to flip;
// second NMI entry sees NMI_PAUSED!=0, clears it, RTIs, and the first
// instance's wait loop exits and restores the screen.
.const NMI_PAUSED = $4A         // byte: 0 = idle, !0 = banner showing

// RUN/STOP latch. The IRQ handler polls CIA1 PRB row-7 directly each tick
// and writes bit 7 here: $80 = STOP held, $00 = not held. parser_stmt then
// reads this byte and panics ERR_BREAK when bit 7 is set. We don't go via
// KERNAL's $91/SCNKEY pipeline because that mechanism turned out to be
// unreliable mid-loop. Encoding "break = bit 7 set" (rather than = $7F)
// means py65 RAM-default $00 reads as "no break" → tests don't see false
// stops despite never running our IRQ.
.const STOP_REQUESTED = $4B     // byte: bit 7 set → user pressed RUN/STOP

// 40-byte scratch for saving screen row 0 across the NMI pause. Lives in
// unused KERNAL workspace at $02A7-$02CE (free during pause since we're not
// running disk I/O — see PAUSE_BLOCKED guard).
.label NMI_SCRATCH = $02A7

// --- Panic error codes -------------------------------------------------------
// Written to ERROR_CODE immediately before jmp error_handler.
.const ERR_OOM      = $01  // Out of memory — alloc could not satisfy a request
.const ERR_DIV_ZERO = $02  // Division by zero — divisor is exactly zero
.const ERR_OVERFLOW = $03  // Numeric overflow (e.g., float→int out of int32 range)
.const ERR_LEX      = $04  // Lexer panic — illegal char, unterminated string, malformed number
.const ERR_TYPE     = $05  // Type mismatch — operator/builtin received an unsupported operand type
.const ERR_ARITY    = $06  // Wrong number of arguments to a builtin or user function
.const ERR_DISK     = $07  // 1541/IEC error — DOS error channel reported a non-zero code
.const ERR_BREAK    = $08  // User pressed Run/Stop — interpreter aborted at a parser_stmt boundary

// --- Handle struct -----------------------------------------------------------
.const H_PTR         = 0   // 2 bytes — pointer to heap object (header + payload)
.const H_SIZE        = 2   // 2 bytes — total bytes reserved in heap (capacity)
.const H_NEXT        = 4   // 2 bytes — linked-list pointer (free / reserved list)
.const H_TYPE        = 6   // 1 byte  — pure type tag (no embedded bits)
.const H_FLAGS       = 7   // 1 byte  — GC state + future bits
.const SIZEOF_HANDLE = 8

// --- Handle flag bits --------------------------------------------------------
.const FLAG_MARKED = $80   // GC mark bit
.const FLAG_GRAY   = $40   // GC tri-color worklist bit — set during phase 1 of
                           // gc_mark on roots and on newly-discovered children;
                           // cleared in phase 2 once children traced.
.const FLAG_RENDERING = $10   // currently inside a str-render call on this
                              // container — set by builtin_str on entry to
                              // _bstr_list / _bstr_tuple / _bstr_dict, cleared
                              // on exit. If set on entry the renderer emits
                              // the matching ellipsis (`<...>` etc.) and
                              // returns instead of recursing.
                              // Bits $0F and $20 are unused and free for
                              // future flags.

// --- Heap object header ------------------------------------------------------
.const O_LEN    = 0        // 2 bytes — type-specific used count
.const O_HEADER = 2        // bytes before payload

// --- Type tags ---------------------------------------------------------------
// Pure enumerated values for now. If/when we move to bitfield grouping
// (numeric vs container, etc.), these numbers will change.
.const TYPE_INT   = $20
.const TYPE_STR   = $21    // byte string; payload is raw bytes, O_LEN = byte count
.const TYPE_BOOL  = $22    // singleton: TRUE / FALSE statics. Payload byte 0/1.
.const TYPE_NONE  = $23    // singleton: NONE static. Empty payload.
.const TYPE_TUPLE = $24    // immutable handle sequence. O_LEN = element count;
                           // payload = N×2 bytes of child handle pointers.
                           // GC traces children transitively (see _gc_trace_seq).
.const TYPE_LIST  = $25    // mutable handle sequence. Same payload shape as
                           // tuple — capacity tracked via H_SIZE so the list
                           // can hold slack past O_LEN for cheap append.
.const TYPE_DICT  = $26    // sorted array of (key, value) 2-tuples. Same
                           // payload shape as list; lookup is binary search
                           // by key (val_cmp on tuple slot DICT_KEY).
.const TYPE_FLOAT = $27    // 5-byte MS-Basic packed float. Heap object O_LEN=5;
                           // payload is BASIC ROM in-memory format. Leaf type
                           // (no GC tracing of children).
.const TYPE_CTRL  = $28    // control-flow sentinel (break/continue/return).
                           // Singletons in statics.asm — handle identity
                           // distinguishes which kind. Detected by parser_suite
                           // and the loop-statement bodies.
.const TYPE_BUILTIN = $29  // built-in function. Payload = 2-byte impl address.
                           // led_lparen reads the impl pointer and SMC-JSRs.

// --- Lazy / target types (admiral-style deferred eval) ----------------------
// Stored as 2-handle arrays (same payload shape as a 2-tuple) for TYPE_REF
// and TYPE_SUB; GC traces them like tuples. eval() resolves these into a
// concrete value; assign() consumes them as targets.
.const TYPE_REF   = $2A    // `obj.attr` lazy: payload = (receiver, name_str).
                           // eval → dict_get_proto(receiver, name).
                           // assign → dict_set(receiver, name, value).
.const TYPE_SUB   = $2B    // `obj[i]` lazy: payload = (container, index).
                           // eval → list/dict get; assign → list/dict set.
.const TYPE_NAME  = $2C    // bare name reference. Same heap layout as TYPE_STR
                           // (raw byte payload). nud_name allocates a TYPE_STR
                           // and mutates H_TYPE to this so eval() routes to
                           // scope_get instead of returning the bytes.

// --- Token kinds (lexer output) ---------------------------------------------
// Dense numbering 0..N-1 so dispatch tables can be array-indexed. **Stays
// under 128** so a single byte holds the kind. Augmented-assigns are
// contiguous so the parser can detect "is augass?" with a range check.
.const TK_EOF           = $00
.const TK_NEWLINE       = $01
.const TK_INDENT        = $02
.const TK_DEDENT        = $03

// Literals
.const TK_INT           = $04
.const TK_HEX           = $05
.const TK_BIN           = $06
.const TK_FLOAT_LIT     = $07   // distinct from TYPE_FLOAT — this is the token kind
.const TK_STR           = $08
.const TK_NAME          = $09

// Punctuation (single-char)
.const TK_LPAREN        = $0A
.const TK_RPAREN        = $0B
.const TK_LBRACK        = $0C
.const TK_RBRACK        = $0D
.const TK_LCURLY        = $0E
.const TK_RCURLY        = $0F
.const TK_COMMA         = $10
.const TK_COLON         = $11
.const TK_SEMICOLON     = $12
.const TK_DOT           = $13
.const TK_AT            = $14

// Arithmetic / bitwise operator tokens
.const TK_PLUS          = $15
.const TK_MINUS         = $16
.const TK_STAR          = $17
.const TK_SLASH         = $18
.const TK_DSLASH        = $19   // //
.const TK_PERCENT       = $1A
.const TK_POWER         = $1B   // **
.const TK_LSHIFT        = $1C   // <<
.const TK_RSHIFT        = $1D   // >>
.const TK_AMP           = $1E
.const TK_PIPE          = $1F
.const TK_CARET         = $20
.const TK_TILDE         = $21

// Comparison + assign
.const TK_LT            = $22
.const TK_LE            = $23
.const TK_GT            = $24
.const TK_GE            = $25
.const TK_EQ            = $26   // ==
.const TK_NEQ           = $27   // !=
.const TK_ASSIGN        = $28   // =

// Augmented-assign — kept contiguous so the parser can map any of these to
// a per-op trampoline by `kind - TK_AUGASS_BASE` indexing.
.const TK_AUGASS_BASE   = $29
.const TK_PLUSEQ        = $29
.const TK_MINUSEQ       = $2A
.const TK_STAREQ        = $2B
.const TK_SLASHEQ       = $2C
.const TK_DSLASHEQ      = $2D
.const TK_PERCENTEQ     = $2E
.const TK_POWEREQ       = $2F
.const TK_LSHIFTEQ      = $30
.const TK_RSHIFTEQ      = $31
.const TK_AMPEQ         = $32
.const TK_PIPEEQ        = $33
.const TK_CARETEQ       = $34
.const TK_AUGASS_LAST   = $34

// Keywords
.const TK_IF            = $35
.const TK_ELIF          = $36
.const TK_ELSE          = $37
.const TK_WHILE         = $38
.const TK_FOR           = $39
.const TK_IN            = $3A
.const TK_BREAK         = $3B
.const TK_CONTINUE      = $3C
.const TK_PASS          = $3D
.const TK_RETURN        = $3E
.const TK_TRY           = $3F
.const TK_EXCEPT        = $40
.const TK_FINALLY       = $41
.const TK_RAISE         = $42
.const TK_DEL           = $43
.const TK_AND           = $44
.const TK_OR            = $45
.const TK_NOT           = $46
.const TK_IS            = $47
.const TK_TRUE          = $48
.const TK_FALSE         = $49
.const TK_NONE_KW       = $4A   // distinct name from TYPE_NONE
.const TK_PRINT         = $4B   // print statement (Stage 9b)
.const TK_CLS           = $4C   // cls statement — clears the screen

// Dict pair-tuple slots. Each dict element is a 2-tuple of [key, value].
.const DICT_KEY   = 0
.const DICT_VAL   = 1

// --- Heap region layout (bump allocator) -------------------------------------
// With MEM_NORMAL ($34) the entire upper RAM is ours: $A000-$BFFF (under
// BASIC ROM), $C000-$CFFF (always-RAM gap), $D000-$DFFF (under I/O), and
// $E000-$FFF8 (under KERNAL ROM, minus the IRQ/NMI/RESET vectors at the top).
// Data grows UP from $8800 (right after FS at $8000-$83FF and RS at
// $8400-$87FF); handles grow DOWN from $FFF8 — one byte below the NMI vector
// at $FFFA. Net usable heap: ~30 KB.
.const HEAP_DATA_START   = $8800   // data heap grows UP from here
.const HEAP_HANDLE_START = $FFF8   // text-config handle ceiling: grows DOWN
                                   // from here (just below the IRQ/NMI/RESET
                                   // vectors at $FFFA-$FFFF — RAM with $01=$34)

// Graphics-config handle ceiling. REBOOT(TRUE) reserves $DC00-$FFFF (~9KB) for
// a VIC bank-3 hi-res bitmap + color matrix; the handle table then grows down
// from $DC00 instead of $FFF8. The actual VIC setup + drawing are user-space
// CALL-asm extensions (examples/{text,hires,mc}.admiral). Layout (for those
// extensions / EXTENSIONS.md — not used by core):
//   GFX_MATRIX_BASE  $DC00  color matrix (1000 B, $DC00-$DFE7)
//   GFX_BITMAP_BASE  $E000  bitmap       (8000 B, $E000-$FF3F)
//   GFX_YTBL         $FF40  free scratch ($FF40-$FFF9, ~186 B): row-addr table
//                           + bit masks (below the vectors at $FFFA).
.const HEAP_HANDLE_START_GFX = $DC00
.const GFX_MATRIX_BASE       = $DC00
.const GFX_BITMAP_BASE       = $E000
.const GFX_YTBL              = $FF40

// --- VIC-II / screen layout (bank 0 default) ---------------------------------
// Text mode in VIC-II bank 0. See ARCHITECTURE.md for future bank-3 migration.
.const SCREEN_BASE = $0400         // VIC text screen RAM (screen codes)
.const COLOR_BASE  = $D800         // color RAM (4-bit per cell, dual-ported)
.const VIC_BORDER  = $D020         // border color register
.const VIC_BG      = $D021         // screen background color register
.const VIC_MEMPTR  = $D018         // screen-mem + char-gen pointers
                                   // $15 = unshifted (uppercase + graphics)
                                   // $17 = shifted   (lowercase + uppercase)
.const SCREEN_COLS = 40
.const SCREEN_ROWS = 25

// Default color theme: light-green chars + light-green border on dark-green
// background. ($05 is the C64 palette's only mid/dark green; $0D is light
// green.)
.const COLOR_BORDER = $0D          // light green
.const COLOR_BG     = $05          // dark (mid) green
.const COLOR_FG     = $0D          // light green

// --- $01 banking modes -------------------------------------------------------
// Steady state is MEM_NORMAL ($34) — BASIC + KERNAL + I/O all banked OUT.
// $D000-$DFFF and $E000-$FFFF are plain RAM, available for the heap.
// Tight bracketed sections temporarily flip to:
//   MEM_IO  ($35) — I/O on (VIC, color RAM, CIA1) for screen and keyboard
//                   matrix access.
//   MEM_KERNAL ($36) — KERNAL+I/O on for KERNAL_GETIN (kbd_getchar) and
//                      KERNAL_SCNKEY (irq_handler).
//   MEM_FP  ($37) — BASIC+KERNAL+I/O on across each BASIC ROM FP JSR.
//   $34: LORAM=0 HIRAM=0 CHAREN=0 — full RAM at $A000+$D000+$E000
//   $35: LORAM=1 HIRAM=0 CHAREN=1 — RAM @ $A000+$E000, I/O @ $D000
//   $36: LORAM=0 HIRAM=1 CHAREN=1 — RAM @ $A000, KERNAL @ $E000, I/O @ $D000
//   $37: LORAM=1 HIRAM=1 CHAREN=1 — BASIC+KERNAL+I/O all in
.const MEM_NORMAL = $34
.const MEM_IO     = $35
.const MEM_KERNAL = $36
.const MEM_FP     = $37

// --- KERNAL entry points we use ----------------------------------------------
.const KERNAL_GETIN = $FFE4        // read one key from buffer; A=0 if empty
.const KERNAL_SCNKEY = $EA87       // scan keyboard matrix → $0277 ringbuf

// --- BASIC ROM entry points (FP routines) ------------------------------------
// All addresses verified against the standard C64 BASIC ROM (basic-901226-01).
//
// Register-form binary-op entries (FADDT/FMULTT/FDIVT) require the caller to
// preload A = FAC1 exponent ($61) before JSR — they begin with a BNE/BEQ on
// A that mirrors what a fresh CONUPK would have produced. FSUBT loads its
// own A and additionally manipulates signs.
.const BASIC_GIVAYF = $B391        // FAC1 ← signed int (A=hi byte, Y=lo byte)
.const BASIC_FADDT  = $B86A        // FAC1 = FAC2 + FAC1   (caller preloads A=FAC1 exp)
.const BASIC_FSUBT  = $B853        // FAC1 = FAC2 - FAC1   (self-contained; sign flip + JMP FADDT)
.const BASIC_FMULTT = $BA2B        // FAC1 = FAC2 * FAC1   (caller preloads A=FAC1 exp, $6F=combined sign)
.const BASIC_FDIVT  = $BB12        // FAC1 = FAC2 / FAC1   (caller preloads A=FAC1 exp, $6F=combined sign)
.const BASIC_NEGOP  = $BFB4        // FAC1 = -FAC1
.const BASIC_QINT   = $BC9B        // FAC1 → signed 32-bit int at $62..$65 (BE)
.const BASIC_FOUT   = $BDDD        // FAC1 → ASCII at $0100 (null-terminated)
.const BASIC_INT    = $BCCC        // FAC1 = floor(FAC1)  (toward -inf)
.const BASIC_FPWRT  = $BF7B        // FAC1 = FAC2 ^ FAC1  (caller preloads A=FAC1 exp, $6F=combined sign)
.const BASIC_EXP    = $BFED        // FAC1 = exp(FAC1)
.const BASIC_LOG    = $B9EA        // FAC1 = ln(FAC1)   (panics on FAC1 <= 0)
.const BASIC_SQR    = $BF71        // FAC1 = sqrt(FAC1) (computes as exp(0.5*log(FAC1)) → panics on FAC1 < 0)
.const BASIC_SIN    = $E26B        // FAC1 = sin(FAC1)  (radians; in KERNAL bank)
.const BASIC_COS    = $E264        // FAC1 = cos(FAC1)  (adds π/2 then falls into SIN)
.const BASIC_TAN    = $E2B4        // FAC1 = tan(FAC1)
.const BASIC_ATN    = $E30E        // FAC1 = atan(FAC1)

// FAC ZP base addresses (BASIC's workspace; preserved by our ZP partition).
// Layout per FAC: [exp, m_hi, m_mh, m_ml, m_lo, sign].
.const FAC1 = $61                  // primary float accumulator (6 bytes incl sign)
.const FAC2 = $69                  // secondary FP register (6 bytes incl sign)
.const ARISGN = $6F                // combined sign for arithmetic (FAC1.sign XOR FAC2.sign)
