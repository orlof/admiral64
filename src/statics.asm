// -----------------------------------------------------------------------------
// Static handles + objects. Fixed-address constants baked into the assembled
// binary. They live in the code region (well below HEAP_HANDLE_START), so
// `alloc` never returns one and they're never on the RESERVED or FREE lists —
// `gc_sweep` and `gc_compact` naturally skip them.
//
// GC notes:
//   - `gc_mark` sees statics when they appear on RS and will OR `FLAG_MARKED`
//     into their H_FLAGS byte. This is benign: sweep never reads that bit for
//     handles not on the reserved list, so it just accumulates harmlessly.
//   - H_PTR of a static always points at the static's own object (in-image
//     address). Compact never visits the static, so H_PTR is never updated.
//
// Convention: each static is a pair of back-to-back labels — `INT_N:` is the
// handle address (what callers pass as a handle); `INT_N_OBJ:` is the heap
// object the handle points at.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"

// Inline-int statics: the 32-bit value lives in H_PTR (lo16) + H_SIZE (hi16),
// just like a heap-allocated inline int. No _OBJ payload. gc_compact skips
// TYPE_INT, and statics aren't on the reserved list anyway.

// INT_0 — used for "is this zero?" comparisons, default values, etc.
INT_0:
    .word 0                  // H_PTR  = value lo16
    .word 0                  // H_SIZE = value hi16
    .word 0                  // H_NEXT
    .byte TYPE_INT           // H_TYPE
    .byte 0                  // H_FLAGS

// INT_1 — unit value, loop counters, sign markers.
INT_1:
    .word 1
    .word 0
    .word 0
    .byte TYPE_INT
    .byte 0

// INT_10 — decimal divisor (legacy callers); inline value 10.
INT_10:
    .word 10
    .word 0
    .word 0
    .byte TYPE_INT
    .byte 0

// STR_BANNER — boot banner line 1, printed by admiral.asm's boot sequence.
// Mimics the C64's BASIC startup screen (`**** COMMODORE 64 BASIC V2 ****`)
// with our flavor. 5 leading spaces center the 30-char `**** … ****` block in
// the 40-column screen.
STR_BANNER:
    .word STR_BANNER_OBJ
    .word 2 + 35             // H_SIZE = O_HEADER + payload length
    .word 0
    .byte TYPE_STR
    .byte 0
STR_BANNER_OBJ:
    .word 35                 // O_LEN = payload length
    .text "     **** COMMODORE 64 ADMIRAL ****"

// STR_BANNER_2A / STR_BANNER_2B — banner line 2 split around the heap-free
// integer that boot computes at runtime: prints A, then the int, then B.
//   " 64K RAM SYSTEM  " <int> " HEAP BYTES FREE"
// One leading space centers the full 39-char line (with a 5-digit heap-free,
// e.g. 18432) symmetrically inside 40 columns.
STR_BANNER_2A:
    .word STR_BANNER_2A_OBJ
    .word 2 + 17
    .word 0
    .byte TYPE_STR
    .byte 0
STR_BANNER_2A_OBJ:
    .word 17
    .text " 64K RAM SYSTEM  "

STR_BANNER_2B:
    .word STR_BANNER_2B_OBJ
    .word 2 + 16
    .word 0
    .byte TYPE_STR
    .byte 0
STR_BANNER_2B_OBJ:
    .word 16
    .text " HEAP BYTES FREE"

// TRUE / FALSE — bool singletons. Payload byte distinguishes them (so a
// hypothetical freshly-allocated bool would still byte-compare correctly),
// but in practice val_eq's handle-identity short-circuit catches both.
TRUE:
    .word TRUE_OBJ
    .word 3                  // O_HEADER + 1
    .word 0
    .byte TYPE_BOOL
    .byte 0
TRUE_OBJ:
    .word 1
    .byte 1

FALSE:
    .word FALSE_OBJ
    .word 3
    .word 0
    .byte TYPE_BOOL
    .byte 0
FALSE_OBJ:
    .word 1
    .byte 0

// NONE — the singleton none value. Empty payload; equality is type-and-handle.
NONE:
    .word NONE_OBJ
    .word 2                  // O_HEADER + 0
    .word 0
    .byte TYPE_NONE
    .byte 0
NONE_OBJ:
    .word 0                  // O_LEN = 0

// FLOAT_ZERO — pre-allocated 0.0 for cheap "is x zero?" pivots and as a
// default initialiser. Packed MS-Basic zero is 5 bytes of $00 (exp=0 means
// the value is exactly zero).
FLOAT_ZERO:
    .word FLOAT_ZERO_OBJ
    .word 7                  // O_HEADER + 5
    .word 0
    .byte TYPE_FLOAT
    .byte 0
FLOAT_ZERO_OBJ:
    .word 5                  // O_LEN = 5
    .byte $00, $00, $00, $00, $00

// FLOAT_ONE — packed 1.0. Exp = $81 (excess-128 form of 2^0 = 1); mantissa
// MSB byte $00 (sign clear; hidden bit implicit); rest zero.
FLOAT_ONE:
    .word FLOAT_ONE_OBJ
    .word 7
    .word 0
    .byte TYPE_FLOAT
    .byte 0
FLOAT_ONE_OBJ:
    .word 5
    .byte $81, $00, $00, $00, $00

// Control-flow sentinels for break/continue. Each is a TYPE_CTRL handle;
// callers distinguish via handle identity (CTRL_BREAK vs CTRL_CONTINUE).
// parser_suite detects TYPE_CTRL after each parser_stmt and propagates;
// loop bodies (stmt_while / stmt_for) consume the sentinel and act on it.
CTRL_BREAK:
    .word CTRL_BREAK_OBJ
    .word 2
    .word 0
    .byte TYPE_CTRL
    .byte 0
CTRL_BREAK_OBJ:
    .word 0

CTRL_CONTINUE:
    .word CTRL_CONTINUE_OBJ
    .word 2
    .word 0
    .byte TYPE_CTRL
    .byte 0
CTRL_CONTINUE_OBJ:
    .word 0

// Pre-allocated TYPE_STR singletons for print rendering of bool / None.
// Bytes are PETSCII uppercase ($41-$5A) — matches the platform's native
// keyboard / disk encoding.
STR_TRUE:
    .word STR_TRUE_OBJ
    .word 6                  // O_HEADER + 4
    .word 0
    .byte TYPE_STR
    .byte 0
STR_TRUE_OBJ:
    .word 4
    .byte $54, $52, $55, $45  // "TRUE"

STR_FALSE:
    .word STR_FALSE_OBJ
    .word 7
    .word 0
    .byte TYPE_STR
    .byte 0
STR_FALSE_OBJ:
    .word 5
    .byte $46, $41, $4C, $53, $45  // "FALSE"

STR_NONE:
    .word STR_NONE_OBJ
    .word 6
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NONE_OBJ:
    .word 4
    .byte $4E, $4F, $4E, $45  // "NONE"

// Prefix for print_value's TYPE_CODE rendering: "<code 0x" — the four hex
// digits of O_LEN and the closing ">" are appended at print time.
STR_CODE_PREFIX:
    .word STR_CODE_PREFIX_OBJ
    .word 10                 // O_HEADER + 8
    .word 0
    .byte TYPE_STR
    .byte 0
STR_CODE_PREFIX_OBJ:
    .word 8
    .byte $3C, $43, $4F, $44, $45, $20, $30, $58  // "<CODE 0X"

// Built-in functions and methods are not first-class values in admiral —
// they're never stored, passed as arguments, or returned from expressions.
// Resolution is purely a parse-time operation: `nud_name` and `led_dot`
// peek for `(` after the name and dispatch directly through `_call_dispatch`
// (parser.asm). No TYPE_BUILTIN handle ever exists at runtime.

// Name strings for binding the built-ins into the global scope at
// parser_eval start. Bytes are PETSCII uppercase ($41-$5A).
// --- Method names. Prefixed `STR_NAME_M_` so they don't collide with the ----
// global-builtin name strings above. ----------------------------------------
STR_NAME_M_UPPER:
    .word STR_NAME_M_UPPER_OBJ
    .word 7
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_UPPER_OBJ:
    .word 5
    .byte $55, $50, $50, $45, $52  // "UPPER"

STR_NAME_M_LOWER:
    .word STR_NAME_M_LOWER_OBJ
    .word 7
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_LOWER_OBJ:
    .word 5
    .byte $4C, $4F, $57, $45, $52  // "LOWER"

STR_NAME_M_FIND:
    .word STR_NAME_M_FIND_OBJ
    .word 6
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_FIND_OBJ:
    .word 4
    .byte $46, $49, $4E, $44        // "FIND"

STR_NAME_M_STARTSWITH:
    .word STR_NAME_M_STARTSWITH_OBJ
    .word 12
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_STARTSWITH_OBJ:
    .word 10
    .byte $53, $54, $41, $52, $54, $53, $57, $49, $54, $48 // "STARTSWITH"

STR_NAME_M_ENDSWITH:
    .word STR_NAME_M_ENDSWITH_OBJ
    .word 10
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_ENDSWITH_OBJ:
    .word 8
    .byte $45, $4E, $44, $53, $57, $49, $54, $48  // "ENDSWITH"

STR_NAME_M_ISALPHA:
    .word STR_NAME_M_ISALPHA_OBJ
    .word 9
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_ISALPHA_OBJ:
    .word 7
    .byte $49, $53, $41, $4C, $50, $48, $41  // "ISALPHA"

STR_NAME_M_ISDIGIT:
    .word STR_NAME_M_ISDIGIT_OBJ
    .word 9
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_ISDIGIT_OBJ:
    .word 7
    .byte $49, $53, $44, $49, $47, $49, $54  // "ISDIGIT"

STR_NAME_M_REPLACE:
    .word STR_NAME_M_REPLACE_OBJ
    .word 9
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_REPLACE_OBJ:
    .word 7
    .byte $52, $45, $50, $4C, $41, $43, $45  // "REPLACE"

STR_NAME_M_SPLIT:
    .word STR_NAME_M_SPLIT_OBJ
    .word 7
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_SPLIT_OBJ:
    .word 5
    .byte $53, $50, $4C, $49, $54          // "SPLIT"

STR_NAME_M_APPEND:
    .word STR_NAME_M_APPEND_OBJ
    .word 8
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_APPEND_OBJ:
    .word 6
    .byte $41, $50, $50, $45, $4E, $44  // "APPEND"

STR_NAME_M_INSERT:
    .word STR_NAME_M_INSERT_OBJ
    .word 8
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_INSERT_OBJ:
    .word 6
    .byte $49, $4E, $53, $45, $52, $54  // "INSERT"

STR_NAME_M_POP:
    .word STR_NAME_M_POP_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_POP_OBJ:
    .word 3
    .byte $50, $4F, $50             // "POP"

STR_NAME_M_KEYS:
    .word STR_NAME_M_KEYS_OBJ
    .word 6
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_KEYS_OBJ:
    .word 4
    .byte $4B, $45, $59, $53        // "KEYS"

STR_NAME_M_VALUES:
    .word STR_NAME_M_VALUES_OBJ
    .word 8
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_VALUES_OBJ:
    .word 6
    .byte $56, $41, $4C, $55, $45, $53  // "VALUES"

STR_NAME_M_CREATE:
    .word STR_NAME_M_CREATE_OBJ
    .word 8
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_CREATE_OBJ:
    .word 6
    .byte $43, $52, $45, $41, $54, $45  // "CREATE"



// --- punctuation singletons used by builtin_str container rendering ---------
STR_LBRACK:
    .word STR_LBRACK_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_LBRACK_OBJ:
    .word 1
    .byte $5B                       // "["

STR_RBRACK:
    .word STR_RBRACK_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_RBRACK_OBJ:
    .word 1
    .byte $5D                       // "]"

STR_LPAREN:
    .word STR_LPAREN_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_LPAREN_OBJ:
    .word 1
    .byte $28                       // "("

STR_RPAREN:
    .word STR_RPAREN_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_RPAREN_OBJ:
    .word 1
    .byte $29                       // ")"

// Dict open/close — angle brackets, NOT curly braces. The C64 character ROM
// has no `{` `}` glyphs in either charset (PETSCII $7B/$7D map to graphic
// blocks). Angle brackets exist in both charsets and don't collide with list
// `[]` or tuple `()`. Both source syntax (`<a:1>`) and repr render with these.
STR_LCURLY:
    .word STR_LCURLY_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_LCURLY_OBJ:
    .word 1
    .byte $3C                       // "<"

STR_RCURLY:
    .word STR_RCURLY_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_RCURLY_OBJ:
    .word 1
    .byte $3E                       // ">"

// Container element separators. We render without the trailing space — on a
// 40-column screen, every spare column matters, and `[1,2,3]` is just as
// readable as `[1, 2, 3]`. The label names are kept (rather than renaming to
// STR_COMMA / STR_COLON) so callers in str.asm / dict.asm don't churn.
STR_COMMA_SPACE:
    .word STR_COMMA_SPACE_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_COMMA_SPACE_OBJ:
    .word 1
    .byte $2C                       // ","

STR_COLON_SPACE:
    .word STR_COLON_SPACE_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_COLON_SPACE_OBJ:
    .word 1
    .byte $3A                       // ":"

// Cycle-detection sentinels emitted by the container str-renderers when they
// detect they're already rendering this container higher up the stack
// (e.g., `g = globals(); print g`). One per bracket family.
STR_DICT_ELLIPSIS:
    .word STR_DICT_ELLIPSIS_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_DICT_ELLIPSIS_OBJ:
    .word 5
    .byte $3C, $2E, $2E, $2E, $3E    // "<...>"

STR_LIST_ELLIPSIS:
    .word STR_LIST_ELLIPSIS_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_LIST_ELLIPSIS_OBJ:
    .word 5
    .byte $5B, $2E, $2E, $2E, $5D    // "[...]"

STR_TUPLE_ELLIPSIS:
    .word STR_TUPLE_ELLIPSIS_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_TUPLE_ELLIPSIS_OBJ:
    .word 5
    .byte $28, $2E, $2E, $2E, $29    // "(...)"

// Single-quote singleton, used by builtin_repr to wrap TYPE_STR.
STR_QUOTE:
    .word STR_QUOTE_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_QUOTE_OBJ:
    .word 1
    .byte $27                       // "'"

// Parent-link key used by scope-chain lookup. Function-call setup stores
// `dict_set(new_scope, "_", old_scope)` so `scope_get` can walk outward
// from the call's local scope to its caller's scope to global.
STR_UNDERSCORE:
    .word STR_UNDERSCORE_OBJ
    .word 3                  // O_HEADER + 1
    .word 0
    .byte TYPE_STR
    .byte 0
STR_UNDERSCORE_OBJ:
    .word 1
    .byte $5F                 // "_"

// Receiver-binding key: `ME`. led_lparen's str-call binds `ME` to the
// method's receiver dict when called via attribute access (`obj.method(...)`).
// Mirrors Admiral's STR_ME (parser.dasm16:2046).
STR_ME:
    .word STR_ME_OBJ
    .word 4                  // O_HEADER + 2
    .word 0
    .byte TYPE_STR
    .byte 0
STR_ME_OBJ:
    .word 2
    .byte $4D, $45            // "ME"
