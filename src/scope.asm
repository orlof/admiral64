// -----------------------------------------------------------------------------
// scope.asm — variable scope primitives.
//
// For Stage 9a, all variables live in a single global scope dict held by
// the GLOBAL_SCOPE ZP cell. The dict's keys are TYPE_STR (variable names);
// values are arbitrary handles. parser_eval allocates the dict at start of
// evaluation, pushes it on RS for GC rooting, and caches the handle in
// GLOBAL_SCOPE for fast access from scope_get / scope_set.
//
// Stage 9c will add nested scopes via the `_` parent-link convention from
// DCPU Admiral. For now, every name resolves through the global dict.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"

// -----------------------------------------------------------------------------
// scope_get — look up a name, walking the scope's parent chain.
//   in:   1 handle on RS = name (TYPE_STR).
//   out:  RV = value handle.
//
// Algorithm:
//   1. Start at GLOBAL_SCOPE (the current scope; "global" is a misnomer
//      since it's actually the innermost scope in our flat naming).
//   2. dict_get(scope, name); if found (RV != NONE), return.
//   3. Otherwise dict_get(scope, "_") for parent link.
//      - If that returns NONE → name not anywhere in the chain → panic.
//      - Else → parent becomes the new current scope; loop.
//
// **Caveat**: NONE-as-stored-value is indistinguishable from "key absent" in
// our dict layer. Storing None into a variable will then read as "missing"
// and trigger walk + panic. Documented limitation; a future `dict_lookup`
// that returns a found-flag separately would fix it.
// V4' wrapper.
// -----------------------------------------------------------------------------
scope_get:
    preamble_args(1, 0)

    rs_pop(W0)                       // W0 = name (caller's arg, consumed)
    lda GLOBAL_SCOPE
    sta W1
    lda GLOBAL_SCOPE+1
    sta W1+1                          // W1 = current scope walker

_sg_loop:
    rs_push(W1)
    rs_push(W0)
    jsr dict_get                     // RV = value or NONE; consumes 2

    lda RV
    cmp #<NONE
    bne _sg_done
    lda RV+1
    cmp #>NONE
    bne _sg_done

    // Miss — try parent via "_" key.
    rs_push(W1)
    rs_push_const(STR_UNDERSCORE)
    jsr dict_get                     // RV = parent dict or NONE

    lda RV
    cmp #<NONE
    bne _sg_have_parent
    lda RV+1
    cmp #>NONE
    bne _sg_have_parent

    // No parent → name not found in any scope.
    lda #ERR_LEX
    sta ERROR_CODE
    jmp error_handler

_sg_have_parent:
    lda RV
    sta W1
    lda RV+1
    sta W1+1
    jmp _sg_loop

_sg_done:
    jmp postamble

// -----------------------------------------------------------------------------
// scope_set — bind a name to a value in the global scope.
//   in:   2 handles on RS — name (deeper), value (top).
//   out:  RV unchanged. dict_set has the side effect; both args consumed.
// V4' wrapper.
// -----------------------------------------------------------------------------
scope_set:
    preamble_args(2, 0)

    // RS at entry: [name, value]. dict_set wants [dict, key, value]. So we
    // need to insert global_dict UNDER name. Pop both, push dict, push back.
    rs_pop(W1)                       // W1 = value; RS: [name]
    rs_pop(W0)                       // W0 = name;  RS: []
    rs_push(GLOBAL_SCOPE)            // RS: [global_dict]
    rs_push(W0)                      // RS: [global_dict, name]
    rs_push(W1)                      // RS: [global_dict, name, value]
    jsr dict_set                     // consumes 3 args

    jmp postamble
