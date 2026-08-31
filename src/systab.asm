// -----------------------------------------------------------------------------
// systab.asm — the fixed-address system table (see sys.inc for the ABI).
//
// Emitted at $0810, right after the BASIC stub, BEFORE all kernel code, so
// its addresses never move when the kernel is reassembled. Append-only.
// -----------------------------------------------------------------------------
#importonce
#import "defs.asm"
#import "sys.inc"

* = SYSD_BASE "SysTab"

// --- data directory ($0810) --------------------------------------------------
.word NONE
.word TRUE
.word FALSE
.word INT_0
.word INT_1
.word 0, 0, 0                       // reserved → pad to SYS_TAB ($0820)

// --- jump slots ($0820) ------------------------------------------------------
jmp sys_reloc                       //  0 SYS_RELOC
jmp preamble                        //  1 SYS_PREAMBLE
jmp _preamble_call                  //  2 SYS_PREAMBLE_CALL
jmp postamble                       //  3 SYS_POSTAMBLE
jmp postamble_peek_rv               //  4 SYS_POSTAMBLE_PEEK_RV
jmp postamble_arg0_rv               //  5 SYS_POSTAMBLE_ARG0_RV
jmp postamble_return_none           //  6 SYS_POSTAMBLE_RET_NONE
jmp arg_get_w0                      //  7 SYS_ARG_GET_W0
jmp arg_get_w1                      //  8 SYS_ARG_GET_W1
jmp arg_get_rv                      //  9 SYS_ARG_GET_RV
jmp arg0_w0_deref                   // 10 SYS_ARG0_W0_DEREF
jmp arg0_w0_push                    // 11 SYS_ARG0_W0_PUSH
jmp deref_W0_to_W2                  // 12 SYS_DEREF_W0_TO_W2
jmp str_alloc                       // 13 SYS_STR_ALLOC
jmp rs_push_rv                      // 14 SYS_RS_PUSH_RV
jmp rs_push_w0                      // 15 SYS_RS_PUSH_W0
jmp rs_push_w1                      // 16 SYS_RS_PUSH_W1
jmp rs_pop_rv                       // 17 SYS_RS_POP_RV
jmp rs_pop_w0                       // 18 SYS_RS_POP_W0
jmp rs_peek_w0                      // 19 SYS_RS_PEEK_W0
jmp val_cmp                         // 20 SYS_VAL_CMP
jmp val_truthy                      // 21 SYS_VAL_TRUTHY
jmp array_repeat                    // 22 SYS_ARRAY_REPEAT
jmp screen_clear                    // 23 SYS_SCREEN_CLEAR
jmp screen_show_cursor              // 24 SYS_SCREEN_SHOW_CURSOR
jmp screen_hide_cursor              // 25 SYS_SCREEN_HIDE_CURSOR
jmp scr_row_offset_to_w2_a          // 26 SYS_SCR_ROW_W2_A
jmp petscii_to_screen_code          // 27 SYS_PETSCII_TO_SCREEN
jmp panic_type                      // 28 SYS_PANIC_TYPE
jmp panic_arity                     // 29 SYS_PANIC_ARITY
jmp postamble_pop_rv                // 30 SYS_POSTAMBLE_POP_RV
jmp rs_push_const_ax                // 31 SYS_RS_PUSH_CONST_AX
.for (var i=32; i<48; i++) {
jmp sys_unimpl                      // reserved
}

.if (* != SYS_TAB_END) .error "systab size drifted — table must end at SYS_TAB_END"
