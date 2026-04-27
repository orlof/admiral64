// -----------------------------------------------------------------------------
// tuple.asm — TYPE_TUPLE allocator. Everything else lives in seq.asm.
//
// Tuples are immutable, fixed-length sequences of handles. Construction:
//   1. `tuple_alloc(N)` (A = N) → RV = handle, payload zeroed.
//   2. Caller rs_push(RV) immediately to root.
//   3. Caller writes children via `tuple_set_leaf` (= seq_set_leaf alias).
//   4. From this point on the tuple is treated as immutable.
//
// `tuple_get`, `tuple_len`, `tuple_set_leaf` are all aliases for their
// `seq_*` counterparts in seq.asm — see that file for documentation.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "array.asm"

tuple_alloc:
    preamble_args(0, 0)
    ldx #TYPE_TUPLE
    jsr _array_alloc_init        // A = N (preserved by preamble)
    jmp postamble
