// -----------------------------------------------------------------------------
// list.asm — TYPE_LIST allocator. Everything else lives in array.asm via
// co-located aliases (`list_get`, `list_set`, `list_append`, `list_insert`,
// `list_del`, `list_len` all share bodies with their `array_*` originals).
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "array.asm"

// -----------------------------------------------------------------------------
// list_alloc — allocate a list with N initial null elements (capacity = N).
//   in:  A = N (initial element count, 0..127)
//   out: RV = new list handle. Payload zeroed, O_LEN = N.
//
// To create an empty growing list, pass N = 0; the first append's grow path
// floors capacity to 4 elements (8 bytes of payload).
// -----------------------------------------------------------------------------
list_alloc:
    preamble_args(0, 0)
    ldx #TYPE_LIST
    jsr _array_alloc_init
    jmp postamble
