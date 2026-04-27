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
//   GLOBAL_SCOPE  — the *current* scope (changes on function entry/exit).
//                   Reads/writes by scope_get/scope_set go through here.
//   ROOT_SCOPE    — the program's top-level scope (set once at parser_eval
//                   start, never changes). Used as the parent-link target
//                   when a function call allocates a new local scope, so
//                   functions see globals + their own kwargs but NOT the
//                   caller's locals (Python lexical scoping). Mirrors
//                   Admiral's parser.dasm16:2024 invariant.
.const GLOBAL_SCOPE = $42       // word: current scope (a TYPE_DICT handle)
.const ROOT_SCOPE   = $44       // word: program-level scope (immutable)
.const METHOD_RECEIVER = $46    // word: side-channel set by `led_dot` when
                                // a method-call follows (`obj.method(`).
                                // Read+cleared by led_lparen at call time.
                                // 0 = not a method call.

// --- Panic error codes -------------------------------------------------------
// Written to ERROR_CODE immediately before jmp error_handler.
.const ERR_OOM      = $01  // Out of memory — alloc could not satisfy a request
.const ERR_DIV_ZERO = $02  // Division by zero — divisor is exactly zero
.const ERR_OVERFLOW = $03  // Numeric overflow (e.g., float→int out of int32 range)
.const ERR_LEX      = $04  // Lexer panic — illegal char, unterminated string, malformed number
.const ERR_TYPE     = $05  // Type mismatch — operator/builtin received an unsupported operand type

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
.const FLAG_PINNED = $20   // don't relocate data during compact (reserved)

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

// Dict pair-tuple slots. Each dict element is a 2-tuple of [key, value].
.const DICT_KEY   = 0
.const DICT_VAL   = 1

// --- Heap region layout (bump allocator) -------------------------------------
// Heap lives in $8500..$BFFF — the 16KB freed by switching BASIC ROM off,
// minus the 1.25KB consumed by FS ($8000-$83FF) and RS ($8400-$84FF).
// Data grows UP from $8500; handles grow DOWN from $C000 (wall below I/O).
.const HEAP_DATA_START   = $8500   // data heap grows UP from here
.const HEAP_HANDLE_START = $C000   // handle table grows DOWN from here

// --- VIC-II / screen layout (bank 0 default) ---------------------------------
// Text mode in VIC-II bank 0. See ARCHITECTURE.md for future bank-3 migration.
.const SCREEN_BASE = $0400         // VIC text screen RAM (screen codes)
.const COLOR_BASE  = $D800         // color RAM (4-bit per cell, dual-ported)
.const VIC_BORDER  = $D020         // border color register
.const VIC_BG      = $D021         // screen background color register
.const SCREEN_COLS = 40
.const SCREEN_ROWS = 25

// Default color theme: light-green chars + light-green border on dark-green
// background. ($05 is the C64 palette's only mid/dark green; $0D is light
// green.)
.const COLOR_BORDER = $0D          // light green
.const COLOR_BG     = $05          // dark (mid) green
.const COLOR_FG     = $0D          // light green

// --- KERNAL entry points we use ----------------------------------------------
.const KERNAL_GETIN = $FFE4        // read one key from buffer; A=0 if empty

// --- BASIC ROM entry points (FP routines) ------------------------------------
// Steady state is $01=$36 (BASIC ROM banked OUT). float.asm flips to $37 only
// across each JSR into BASIC space. All addresses verified against the
// standard C64 BASIC ROM (basic-901226-01).
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

// FAC ZP base addresses (BASIC's workspace; preserved by our ZP partition).
// Layout per FAC: [exp, m_hi, m_mh, m_ml, m_lo, sign].
.const FAC1 = $61                  // primary float accumulator (6 bytes incl sign)
.const FAC2 = $69                  // secondary FP register (6 bytes incl sign)
.const ARISGN = $6F                // combined sign for arithmetic (FAC1.sign XOR FAC2.sign)
