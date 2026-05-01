// -----------------------------------------------------------------------------
// dict.asm — TYPE_DICT primitives. Mirrors Admiral's dict2.dasm16.
//
// A dict is a SORTED ARRAY of (key, value) 2-tuples — payload layout
// identical to TYPE_LIST. Type tag is what distinguishes lookup semantics:
//
//   payload[i] = handle to a 2-tuple [key_handle, value_handle]
//
// Lookup is **binary search** by key (val_cmp on tuple slot DICT_KEY).
// Insertion: binary search to find insert position, then `array_insert`
// shifts subsequent entries up. Update of existing key: array_set_leaf
// overwrites the slot. Deletion: binary search, then `array_del` shifts
// down. Mutation cost is O(n); lookup is O(log n).
//
// Supported key types: anything val_cmp orders consistently — int, bool,
// str, tuple-of-orderable. Heterogeneous keys are tolerated (val_cmp falls
// back to type-tag order for cross-type compares).
//
// The dict reuses array.asm's `_array_alloc_init`, `array_insert`, `array_del`,
// `array_set_leaf` — no new payload layout, no new GC tracer, no new val_eq
// dispatch. `gc_mark` and `val_eq` already include TYPE_DICT in their
// container-recursion dispatchers.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "array.asm"

// -----------------------------------------------------------------------------
// dict_alloc — allocate an empty dict (capacity 0). First insert grows
// capacity to the array floor (4 elements / 8 bytes payload).
//   in:  (none)
//   out: RV = new dict handle.
// -----------------------------------------------------------------------------
dict_alloc:
    preamble_args(0, 0)
    lda #0
    ldx #TYPE_DICT
    jsr _array_alloc_init
    jmp postamble

// -----------------------------------------------------------------------------
// _dict_bin_search — binary-search a dict for `key`.
//
// Internal V4' helper. Args via ZP registers (NOT RS) so callers don't
// have to stage/restore the search args around our val_cmp recursion.
// RS is left untouched — what callers had on RS at jsr time is the same
// at return time.
//
//   in:  W0 = dict handle, W1 = key handle
//   out: RV = index (matched index on hit, insertion index on miss).
//        A  = 1 on hit, 0 on miss.
//   clobbers: A, X, Y, RV. W0..W3 / B0..B7 restored by postamble.
//
// Important: results MUST go in RV (volatile, $0E-$0F) and A (volatile,
// preserved across postamble). The B regs are saved+restored by the V4'
// preamble/postamble — we can't return state through them.
//
// Standard half-open binary search:
//   lo = 0; hi = O_LEN; (lo, hi]
//   while lo < hi:
//     mid = lo + (hi - lo) / 2
//     c = val_cmp(key, payload[mid].key)
//     if c == 0:  return (mid, hit)
//     if c < 0:   hi = mid
//     else:       lo = mid + 1
//   return (lo, miss)
// -----------------------------------------------------------------------------
_dict_bin_search:
    preamble_args(0, 0)

    // Save the search key in B6:B7 so we can re-stage it for each val_cmp call.
    lda W1
    sta B6
    lda W1+1
    sta B7

    jsr deref_W0_to_W2           // W2 = dict payload (post-header), A:X = O_LEN word

    // 16-bit search bounds:
    //   lo  = B1:B3   (init 0)
    //   hi  = B2:B4   (init O_LEN word)
    //   mid = B5:B0   (computed each iter)
    sta B2                       // hi.lo = O_LEN.lo
    stx B4                       // hi.hi = O_LEN.hi
    lda #0
    sta B1                       // lo.lo
    sta B3                       // lo.hi

_dbs_loop:
    // Compare lo (B1:B3) vs hi (B2:B4): if lo >= hi → miss.
    lda B3
    cmp B4
    bcc _dbs_have_range
    bne _dbs_miss
    lda B1
    cmp B2
    bcc _dbs_have_range
_dbs_miss:
    // No match: insertion at lo.
    lda B1
    sta RV
    lda B3
    sta RV+1
    lda #0                       // miss
    jmp postamble

_dbs_have_range:
    // mid = lo + (hi - lo) / 2 (16-bit).
    sec
    lda B2
    sbc B1
    sta B5                       // mid lo = (hi - lo) lo
    lda B4
    sbc B3
    sta B0                       // mid hi
    // Right-shift (B0:B5) by 1.
    lsr B0
    ror B5
    // Add lo back.
    clc
    lda B5
    adc B1
    sta B5
    lda B0
    adc B3
    sta B0

    // W3 = W2 + 2*mid (handle slot pointer).
    lda B5
    asl
    sta W3
    lda B0
    rol
    sta W3+1
    clc
    lda W3
    adc W2
    sta W3
    lda W3+1
    adc W2+1
    sta W3+1

    // W1 = payload[mid] = pair-tuple handle
    ldy #0
    lda (W3),y
    sta W1
    iny
    lda (W3),y
    sta W1+1

    // W3 = pair-tuple object header
    ldy #H_PTR
    lda (W1),y
    sta W3
    iny
    lda (W1),y
    sta W3+1

    // W1 = stored key (slot DICT_KEY of the pair)
    ldy #(O_HEADER + 2*DICT_KEY)
    lda (W3),y
    sta W1
    iny
    lda (W3),y
    sta W1+1

    // Stage val_cmp args: rs_push(search_key); rs_push(stored_key).
    lda B6
    sta W0
    lda B7
    sta W0+1
    rs_push(W0)
    rs_push(W1)
    jsr val_cmp                  // A = $FF / $00 / $01

    cmp #0
    beq _dbs_match
    bmi _dbs_lower

    // search > stored → search the upper half: lo = mid + 1 (16-bit).
    clc
    lda B5
    adc #1
    sta B1
    lda B0
    adc #0
    sta B3
    jmp _dbs_resume

_dbs_lower:
    // search < stored → search the lower half: hi = mid
    lda B5
    sta B2
    lda B0
    sta B4

_dbs_resume:
    // val_cmp's postamble restored W2 to its preamble-saved value (= dict
    // payload pointer). Continue.
    jmp _dbs_loop

_dbs_match:
    lda B5
    sta RV
    lda B0
    sta RV+1
    lda #1                       // hit
    jmp postamble

// -----------------------------------------------------------------------------
// dict_get — look up `key`, return value handle or NONE.
//   in:  RS: dict (deeper), key (top).
//   out: RV = value handle, or NONE if key not present. Args consumed.
// -----------------------------------------------------------------------------
dict_get:
    preamble_args(2, 0)

    rs_peek_at(W0, 1)            // dict
    rs_peek_at(W1, 0)            // key
    jsr _dict_bin_search          // A = match flag; RV = index

    cmp #0
    bne _dg_match

    // Miss → return NONE.
    jmp postamble_return_none

_dg_match:
    // RV holds the 16-bit matched index; save before we overwrite RV.
    lda RV
    sta B0                       // B0:B1 = matched index (word)
    lda RV+1
    sta B1
    rs_peek_at(W0, 1)            // dict
    jsr deref_W0_to_W2           // W2 = dict payload
    // W3 = W2 + 2*index (16-bit handle slot pointer).
    lda B0
    asl
    sta W3
    lda B1
    rol
    sta W3+1
    clc
    lda W3
    adc W2
    sta W3
    lda W3+1
    adc W2+1
    sta W3+1
    ldy #0
    lda (W3),y
    sta W1
    iny
    lda (W3),y
    sta W1+1                     // W1 = matched pair handle

    ldy #H_PTR
    lda (W1),y
    sta W3
    iny
    lda (W1),y
    sta W3+1
    ldy #(O_HEADER + 2*DICT_VAL)
    lda (W3),y
    sta RV
    iny
    lda (W3),y
    sta RV+1
    jmp postamble

// -----------------------------------------------------------------------------
// dict_get_proto — like dict_get but walks the "_" prototype chain on miss.
//
// Used by attribute access (`obj.attr`) and method dispatch on TYPE_DICT.
// The convention: a dict storing `_` → other_dict makes that other_dict the
// prototype. A miss in the local dict recursively looks up in the prototype.
// Returns NONE if the key is absent in the entire chain.
//
//   in:  RS bottom→top: dict, key.
//   out: RV = value handle, or NONE on absent. Args consumed (mirrors dict_get).
// V4'.
// -----------------------------------------------------------------------------
dict_get_proto:
    preamble_args(2, 0)

    rs_pop(W1)                       // W1 = key (will be re-pushed each iter)
    rs_pop(W0)                       // W0 = current walker dict

_dgp_loop:
    rs_push(W0)
    rs_push(W1)
    jsr dict_get                     // consumes 2; RV = value or NONE

    // Hit?
    lda RV+1
    cmp #>NONE
    bne _dgp_done
    lda RV
    cmp #<NONE
    bne _dgp_done

    // Miss — look up "_" in the same dict.
    rs_push(W0)
    rs_push_const(STR_UNDERSCORE)
    jsr dict_get                     // RV = parent dict or NONE

    lda RV+1
    cmp #>NONE
    bne _dgp_have_parent
    lda RV
    cmp #<NONE
    beq _dgp_done                    // no parent → RV is already NONE

_dgp_have_parent:
    // Parent must be TYPE_DICT to be walkable. If not, give up and return NONE.
    lda RV
    sta W0
    lda RV+1
    sta W0+1
    ldy #H_TYPE
    lda (W0),y
    cmp #TYPE_DICT
    bne !skip+
    jmp _dgp_loop
!skip:
    lda #<NONE
    sta RV
    lda #>NONE
    sta RV+1

_dgp_done:
    jmp postamble

// -----------------------------------------------------------------------------
// dict_set — insert or update (key → value).
//   in:  RS bottom→top: dict, key, value.
//   out: dict[key] = value. All three args consumed.
//
// Algorithm (mirrors Admiral's dict__set in dict2.dasm16:36):
//   1. Allocate a fresh 2-tuple [key, value]. Push to RS to root.
//   2. Binary-search the dict for `key`.
//   3. On hit: array_set_leaf overwrites the matched slot with the new pair.
//   4. On miss: array_insert at the insertion index shifts the tail up.
// -----------------------------------------------------------------------------
dict_set:
    preamble_args(3, 0)
    // RS layout from top: value (off 0), key (off 1), dict (off 2).

    // Step 1: allocate pair tuple.
    lda #2
    ldx #TYPE_TUPLE
    jsr _array_alloc_init        // RV = pair handle
    rs_push(RV)
    // RS: pair (off 0), value (off 1), key (off 2), dict (off 3).

    // Fill pair[DICT_KEY] = caller's key.
    rs_peek_at(W0, 0)            // pair
    rs_peek_at(W1, 2)            // key
    lda #DICT_KEY
    jsr array_set_leaf

    // Fill pair[DICT_VAL] = caller's value.
    rs_peek_at(W0, 0)
    rs_peek_at(W1, 1)            // value
    lda #DICT_VAL
    jsr array_set_leaf

    // Step 2: binary-search.
    rs_peek_at(W0, 3)            // dict
    rs_peek_at(W1, 2)            // key
    jsr _dict_bin_search          // A = match flag; RV = index (word)

    // Stash the word index in B0:B1 — we'll overwrite RV during the array
    // call paths.
    pha                           // save match flag (A) across the RV save
    lda RV
    sta B0
    lda RV+1
    sta B1
    pla

    cmp #0
    bne _ds_hit

    // Step 4: miss → array_insert at B0:B1.
    // Stage RS: rs_push(dict), rs_push(pair). FS: rs_push(index_word).
    rs_peek_at(W0, 3)            // dict
    rs_push(W0)                   // RS off 0
    rs_peek_at(W0, 1)            // pair (was off 0; now off 1 after the push)
    rs_push(W0)                   // RS off 0 again

    lda B0
    sta W0
    lda B1
    sta W0+1
    fs_push(W0)

    jsr array_insert              // consumes 2 RS + 1 FS; pair stays in dict
    // RS: pair (off 0), value (off 1), key (off 2), dict (off 3).
    // postamble will pop all four — pair is fine, it's now duplicated in dict.
    jmp postamble

_ds_hit:
    // Step 3: hit → overwrite matched slot at index B0:B1.
    rs_peek_at(W0, 3)            // dict
    rs_peek_at(W1, 0)            // pair
    lda B0
    ldx B1
    jsr array_set_leaf_w
    // postamble pops pair + caller's 3 args.
    jmp postamble

// -----------------------------------------------------------------------------
// dict_del — remove the entry for `key`. No-op if key not present.
//   in:  RS: dict (deeper), key (top).
//   out: Args consumed.
// -----------------------------------------------------------------------------
dict_del:
    preamble_args(2, 0)
    // RS: key (off 0), dict (off 1).

    rs_peek_at(W0, 1)            // dict
    rs_peek_at(W1, 0)            // key
    jsr _dict_bin_search          // A = match flag; RV = index (word)

    cmp #0
    beq _dd_done                 // miss → no-op

    // Stash word index, then stage RS + FS for array_del.
    lda RV
    sta B0
    lda RV+1
    sta B1

    rs_peek_at(W0, 1)            // dict
    rs_push(W0)
    lda B0
    sta W0
    lda B1
    sta W0+1
    fs_push(W0)
    jsr array_del

_dd_done:
    jmp postamble
