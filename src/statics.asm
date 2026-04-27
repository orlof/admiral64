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

// INT_0 — used for "is this zero?" comparisons, default values, etc.
INT_0:
    .word INT_0_OBJ          // H_PTR
    .word 3                  // H_SIZE (O_HEADER + 1)
    .word 0                  // H_NEXT (never on a list)
    .byte TYPE_INT           // H_TYPE
    .byte 0                  // H_FLAGS
INT_0_OBJ:
    .word 1                  // O_LEN
    .byte 0                  // payload

// INT_1 — unit value, loop counters, sign markers.
INT_1:
    .word INT_1_OBJ
    .word 3
    .word 0
    .byte TYPE_INT
    .byte 0
INT_1_OBJ:
    .word 1
    .byte 1

// INT_10 — decimal divisor for int_to_str. Pinned so every divmod in the
// digit-extraction loop reuses the same handle (no per-call allocation).
INT_10:
    .word INT_10_OBJ
    .word 3
    .word 0
    .byte TYPE_INT
    .byte 0
INT_10_OBJ:
    .word 1
    .byte 10

// STR_BANNER — boot banner printed by admiral.asm's boot sequence.
STR_BANNER:
    .word STR_BANNER_OBJ
    .word 2 + 11             // H_SIZE = O_HEADER + payload length
    .word 0
    .byte TYPE_STR
    .byte 0
STR_BANNER_OBJ:
    .word 11                 // O_LEN = payload length
    .text "ADMIRAL C64"

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
// Bytes are raw ASCII (kickass `.text` would emit screen codes).
STR_TRUE:
    .word STR_TRUE_OBJ
    .word 6                  // O_HEADER + 4
    .word 0
    .byte TYPE_STR
    .byte 0
STR_TRUE_OBJ:
    .word 4
    .byte $54, $72, $75, $65  // "True"

STR_FALSE:
    .word STR_FALSE_OBJ
    .word 7
    .word 0
    .byte TYPE_STR
    .byte 0
STR_FALSE_OBJ:
    .word 5
    .byte $46, $61, $6C, $73, $65  // "False"

STR_NONE:
    .word STR_NONE_OBJ
    .word 6
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NONE_OBJ:
    .word 4
    .byte $4E, $6F, $6E, $65  // "None"

// Built-in function singletons (Stage 10 starter). Each is a TYPE_BUILTIN
// handle whose 2-byte payload IS the impl address — `led_lparen` reads it
// directly and JSRs via self-modifying code.
BUILTIN_LEN:
    .word BUILTIN_LEN_OBJ
    .word 4                  // O_HEADER + 2
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_LEN_OBJ:
    .word 2
    .word builtin_len        // payload = impl address (2 bytes, lo/hi)

BUILTIN_RANGE:
    .word BUILTIN_RANGE_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_RANGE_OBJ:
    .word 2
    .word builtin_range

BUILTIN_BOOL:
    .word BUILTIN_BOOL_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_BOOL_OBJ:
    .word 2
    .word builtin_bool

BUILTIN_ABS:
    .word BUILTIN_ABS_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_ABS_OBJ:
    .word 2
    .word builtin_abs

BUILTIN_CHR:
    .word BUILTIN_CHR_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_CHR_OBJ:
    .word 2
    .word builtin_chr

BUILTIN_ORD:
    .word BUILTIN_ORD_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_ORD_OBJ:
    .word 2
    .word builtin_ord

BUILTIN_TYPE:
    .word BUILTIN_TYPE_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_TYPE_OBJ:
    .word 2
    .word builtin_type

BUILTIN_INT:
    .word BUILTIN_INT_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_INT_OBJ:
    .word 2
    .word builtin_int

BUILTIN_FLOAT:
    .word BUILTIN_FLOAT_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_FLOAT_OBJ:
    .word 2
    .word builtin_float

BUILTIN_STR:
    .word BUILTIN_STR_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_STR_OBJ:
    .word 2
    .word builtin_str

BUILTIN_ID:
    .word BUILTIN_ID_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_ID_OBJ:
    .word 2
    .word builtin_id

BUILTIN_CMP:
    .word BUILTIN_CMP_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_CMP_OBJ:
    .word 2
    .word builtin_cmp

BUILTIN_HEX:
    .word BUILTIN_HEX_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_HEX_OBJ:
    .word 2
    .word builtin_hex

BUILTIN_REPR:
    .word BUILTIN_REPR_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_REPR_OBJ:
    .word 2
    .word builtin_repr

BUILTIN_SORT:
    .word BUILTIN_SORT_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_SORT_OBJ:
    .word 2
    .word builtin_sort

// --- Method builtins (resolved via per-type method tables in builtins.asm) ---
BUILTIN_STR_UPPER:
    .word BUILTIN_STR_UPPER_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_STR_UPPER_OBJ:
    .word 2
    .word builtin_str_upper

BUILTIN_STR_LOWER:
    .word BUILTIN_STR_LOWER_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_STR_LOWER_OBJ:
    .word 2
    .word builtin_str_lower

BUILTIN_STR_FIND:
    .word BUILTIN_STR_FIND_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_STR_FIND_OBJ:
    .word 2
    .word builtin_str_find

BUILTIN_STR_STARTSWITH:
    .word BUILTIN_STR_STARTSWITH_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_STR_STARTSWITH_OBJ:
    .word 2
    .word builtin_str_startswith

BUILTIN_STR_ENDSWITH:
    .word BUILTIN_STR_ENDSWITH_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_STR_ENDSWITH_OBJ:
    .word 2
    .word builtin_str_endswith

BUILTIN_STR_ISALPHA:
    .word BUILTIN_STR_ISALPHA_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_STR_ISALPHA_OBJ:
    .word 2
    .word builtin_str_isalpha

BUILTIN_STR_ISDIGIT:
    .word BUILTIN_STR_ISDIGIT_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_STR_ISDIGIT_OBJ:
    .word 2
    .word builtin_str_isdigit

BUILTIN_STR_REPLACE:
    .word BUILTIN_STR_REPLACE_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_STR_REPLACE_OBJ:
    .word 2
    .word builtin_str_replace

BUILTIN_STR_SPLIT:
    .word BUILTIN_STR_SPLIT_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_STR_SPLIT_OBJ:
    .word 2
    .word builtin_str_split

BUILTIN_LIST_APPEND:
    .word BUILTIN_LIST_APPEND_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_LIST_APPEND_OBJ:
    .word 2
    .word builtin_list_append

BUILTIN_LIST_INSERT:
    .word BUILTIN_LIST_INSERT_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_LIST_INSERT_OBJ:
    .word 2
    .word builtin_list_insert

BUILTIN_LIST_POP:
    .word BUILTIN_LIST_POP_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_LIST_POP_OBJ:
    .word 2
    .word builtin_list_pop

BUILTIN_DICT_HAS:
    .word BUILTIN_DICT_HAS_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_DICT_HAS_OBJ:
    .word 2
    .word builtin_dict_has

BUILTIN_DICT_GET:
    .word BUILTIN_DICT_GET_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_DICT_GET_OBJ:
    .word 2
    .word builtin_dict_get

BUILTIN_DICT_KEYS:
    .word BUILTIN_DICT_KEYS_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_DICT_KEYS_OBJ:
    .word 2
    .word builtin_dict_keys

BUILTIN_DICT_VALUES:
    .word BUILTIN_DICT_VALUES_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_DICT_VALUES_OBJ:
    .word 2
    .word builtin_dict_values

BUILTIN_DICT_CREATE:
    .word BUILTIN_DICT_CREATE_OBJ
    .word 4
    .word 0
    .byte TYPE_BUILTIN
    .byte 0
BUILTIN_DICT_CREATE_OBJ:
    .word 2
    .word builtin_dict_create



// Name strings for binding the built-ins into the global scope at
// parser_eval start. Bytes are raw ASCII.
STR_NAME_LEN:
    .word STR_NAME_LEN_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_LEN_OBJ:
    .word 3
    .byte $6C, $65, $6E       // "len"

STR_NAME_RANGE:
    .word STR_NAME_RANGE_OBJ
    .word 7
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_RANGE_OBJ:
    .word 5
    .byte $72, $61, $6E, $67, $65  // "range"

STR_NAME_BOOL:
    .word STR_NAME_BOOL_OBJ
    .word 6                          // O_HEADER + 4
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_BOOL_OBJ:
    .word 4
    .byte $62, $6F, $6F, $6C        // "bool"

STR_NAME_ABS:
    .word STR_NAME_ABS_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_ABS_OBJ:
    .word 3
    .byte $61, $62, $73             // "abs"

STR_NAME_CHR:
    .word STR_NAME_CHR_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_CHR_OBJ:
    .word 3
    .byte $63, $68, $72             // "chr"

STR_NAME_ORD:
    .word STR_NAME_ORD_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_ORD_OBJ:
    .word 3
    .byte $6F, $72, $64             // "ord"

STR_NAME_TYPE:
    .word STR_NAME_TYPE_OBJ
    .word 6
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_TYPE_OBJ:
    .word 4
    .byte $74, $79, $70, $65        // "type"

STR_NAME_INT:
    .word STR_NAME_INT_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_INT_OBJ:
    .word 3
    .byte $69, $6E, $74             // "int"

STR_NAME_FLOAT:
    .word STR_NAME_FLOAT_OBJ
    .word 7
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_FLOAT_OBJ:
    .word 5
    .byte $66, $6C, $6F, $61, $74   // "float"

STR_NAME_STR:
    .word STR_NAME_STR_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_STR_OBJ:
    .word 3
    .byte $73, $74, $72             // "str"

STR_NAME_ID:
    .word STR_NAME_ID_OBJ
    .word 4
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_ID_OBJ:
    .word 2
    .byte $69, $64                   // "id"

STR_NAME_CMP:
    .word STR_NAME_CMP_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_CMP_OBJ:
    .word 3
    .byte $63, $6D, $70             // "cmp"

STR_NAME_HEX:
    .word STR_NAME_HEX_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_HEX_OBJ:
    .word 3
    .byte $68, $65, $78             // "hex"

STR_NAME_REPR:
    .word STR_NAME_REPR_OBJ
    .word 6
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_REPR_OBJ:
    .word 4
    .byte $72, $65, $70, $72       // "repr"

STR_NAME_SORT:
    .word STR_NAME_SORT_OBJ
    .word 6
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_SORT_OBJ:
    .word 4
    .byte $73, $6F, $72, $74       // "sort"

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
    .byte $75, $70, $70, $65, $72  // "upper"

STR_NAME_M_LOWER:
    .word STR_NAME_M_LOWER_OBJ
    .word 7
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_LOWER_OBJ:
    .word 5
    .byte $6C, $6F, $77, $65, $72  // "lower"

STR_NAME_M_FIND:
    .word STR_NAME_M_FIND_OBJ
    .word 6
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_FIND_OBJ:
    .word 4
    .byte $66, $69, $6E, $64        // "find"

STR_NAME_M_STARTSWITH:
    .word STR_NAME_M_STARTSWITH_OBJ
    .word 12
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_STARTSWITH_OBJ:
    .word 10
    .byte $73, $74, $61, $72, $74, $73, $77, $69, $74, $68 // "startswith"

STR_NAME_M_ENDSWITH:
    .word STR_NAME_M_ENDSWITH_OBJ
    .word 10
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_ENDSWITH_OBJ:
    .word 8
    .byte $65, $6E, $64, $73, $77, $69, $74, $68  // "endswith"

STR_NAME_M_ISALPHA:
    .word STR_NAME_M_ISALPHA_OBJ
    .word 9
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_ISALPHA_OBJ:
    .word 7
    .byte $69, $73, $61, $6C, $70, $68, $61  // "isalpha"

STR_NAME_M_ISDIGIT:
    .word STR_NAME_M_ISDIGIT_OBJ
    .word 9
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_ISDIGIT_OBJ:
    .word 7
    .byte $69, $73, $64, $69, $67, $69, $74  // "isdigit"

STR_NAME_M_REPLACE:
    .word STR_NAME_M_REPLACE_OBJ
    .word 9
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_REPLACE_OBJ:
    .word 7
    .byte $72, $65, $70, $6C, $61, $63, $65  // "replace"

STR_NAME_M_SPLIT:
    .word STR_NAME_M_SPLIT_OBJ
    .word 7
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_SPLIT_OBJ:
    .word 5
    .byte $73, $70, $6C, $69, $74          // "split"

STR_NAME_M_APPEND:
    .word STR_NAME_M_APPEND_OBJ
    .word 8
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_APPEND_OBJ:
    .word 6
    .byte $61, $70, $70, $65, $6E, $64  // "append"

STR_NAME_M_INSERT:
    .word STR_NAME_M_INSERT_OBJ
    .word 8
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_INSERT_OBJ:
    .word 6
    .byte $69, $6E, $73, $65, $72, $74  // "insert"

STR_NAME_M_POP:
    .word STR_NAME_M_POP_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_POP_OBJ:
    .word 3
    .byte $70, $6F, $70             // "pop"

STR_NAME_M_HAS:
    .word STR_NAME_M_HAS_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_HAS_OBJ:
    .word 3
    .byte $68, $61, $73             // "has"

STR_NAME_M_GET:
    .word STR_NAME_M_GET_OBJ
    .word 5
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_GET_OBJ:
    .word 3
    .byte $67, $65, $74             // "get"

STR_NAME_M_KEYS:
    .word STR_NAME_M_KEYS_OBJ
    .word 6
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_KEYS_OBJ:
    .word 4
    .byte $6B, $65, $79, $73        // "keys"

STR_NAME_M_VALUES:
    .word STR_NAME_M_VALUES_OBJ
    .word 8
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_VALUES_OBJ:
    .word 6
    .byte $76, $61, $6C, $75, $65, $73  // "values"

STR_NAME_M_CREATE:
    .word STR_NAME_M_CREATE_OBJ
    .word 8
    .word 0
    .byte TYPE_STR
    .byte 0
STR_NAME_M_CREATE_OBJ:
    .word 6
    .byte $63, $72, $65, $61, $74, $65  // "create"



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

STR_LCURLY:
    .word STR_LCURLY_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_LCURLY_OBJ:
    .word 1
    .byte $7B                       // "{"

STR_RCURLY:
    .word STR_RCURLY_OBJ
    .word 3
    .word 0
    .byte TYPE_STR
    .byte 0
STR_RCURLY_OBJ:
    .word 1
    .byte $7D                       // "}"

STR_COMMA_SPACE:
    .word STR_COMMA_SPACE_OBJ
    .word 4
    .word 0
    .byte TYPE_STR
    .byte 0
STR_COMMA_SPACE_OBJ:
    .word 2
    .byte $2C, $20                  // ", "

STR_COLON_SPACE:
    .word STR_COLON_SPACE_OBJ
    .word 4
    .word 0
    .byte TYPE_STR
    .byte 0
STR_COLON_SPACE_OBJ:
    .word 2
    .byte $3A, $20                  // ": "

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

// Receiver-binding key: `me`. led_lparen's str-call binds `me` to the
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
    .byte $6D, $65            // "me"
