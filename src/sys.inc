// -----------------------------------------------------------------------------
// sys.inc — the plugin ABI: fixed addresses of the system jump table.
//
// This file is the ONLY contract between the kernel and disk-loaded
// TYPE_CODE plugins. The table lives at $0810-$087F, between the BASIC
// stub and the kernel code (see systab.asm). Entries are APPEND-ONLY:
// never renumber or remove a slot — plugins on user disks were assembled
// against these addresses.
//
// Data directory ($0810-$081F): 16-bit addresses of static handles.
// Plugins read them indirectly, e.g.:
//     lda SYSD_NONE     // lo byte of NONE's handle address
//     ldx SYSD_NONE+1
//
// Jump slots ($0820-$087F): 3-byte `jmp` thunks to kernel routines.
// Register/ZP contracts are identical to the target routines' own
// contracts (see their home files).
// -----------------------------------------------------------------------------
#importonce

// --- data directory ----------------------------------------------------------
.const SYSD_BASE  = $0810
.const SYSD_NONE  = SYSD_BASE + 0    // .word NONE   (statics.asm)
.const SYSD_TRUE  = SYSD_BASE + 2    // .word TRUE
.const SYSD_FALSE = SYSD_BASE + 4    // .word FALSE
.const SYSD_INT0  = SYSD_BASE + 6    // .word INT_0
.const SYSD_INT1  = SYSD_BASE + 8    // .word INT_1
                                     // $081A-$081F reserved (zero)

// --- jump slots --------------------------------------------------------------
.const SYS_TAB                  = $0820
.const SYS_RELOC                = SYS_TAB + 3*0   // plugin_rt.asm
.const SYS_PREAMBLE             = SYS_TAB + 3*1   // preamble.asm: preamble
.const SYS_PREAMBLE_CALL        = SYS_TAB + 3*2   // preamble.asm: _preamble_call
.const SYS_POSTAMBLE            = SYS_TAB + 3*3
.const SYS_POSTAMBLE_PEEK_RV    = SYS_TAB + 3*4
.const SYS_POSTAMBLE_ARG0_RV    = SYS_TAB + 3*5
.const SYS_POSTAMBLE_RET_NONE   = SYS_TAB + 3*6
.const SYS_ARG_GET_W0           = SYS_TAB + 3*7   // stacks.asm arg helpers
.const SYS_ARG_GET_W1           = SYS_TAB + 3*8
.const SYS_ARG_GET_RV           = SYS_TAB + 3*9
.const SYS_ARG0_W0_DEREF        = SYS_TAB + 3*10
.const SYS_ARG0_W0_PUSH         = SYS_TAB + 3*11
.const SYS_DEREF_W0_TO_W2       = SYS_TAB + 3*12  // handle.asm
.const SYS_STR_ALLOC            = SYS_TAB + 3*13  // str.asm
.const SYS_RS_PUSH_RV           = SYS_TAB + 3*14  // stacks.asm
.const SYS_RS_PUSH_W0           = SYS_TAB + 3*15
.const SYS_RS_PUSH_W1           = SYS_TAB + 3*16
.const SYS_RS_POP_RV            = SYS_TAB + 3*17
.const SYS_RS_POP_W0            = SYS_TAB + 3*18
.const SYS_RS_PEEK_W0           = SYS_TAB + 3*19
.const SYS_VAL_CMP              = SYS_TAB + 3*20  // val.asm
.const SYS_VAL_TRUTHY           = SYS_TAB + 3*21
.const SYS_ARRAY_REPEAT         = SYS_TAB + 3*22  // array.asm
.const SYS_SCREEN_CLEAR         = SYS_TAB + 3*23  // screen.asm
.const SYS_SCREEN_SHOW_CURSOR   = SYS_TAB + 3*24
.const SYS_SCREEN_HIDE_CURSOR   = SYS_TAB + 3*25
.const SYS_SCR_ROW_W2_A         = SYS_TAB + 3*26  // scr_row_offset_to_w2_a
.const SYS_PETSCII_TO_SCREEN    = SYS_TAB + 3*27
.const SYS_PANIC_TYPE           = SYS_TAB + 3*28  // admiral.asm
.const SYS_PANIC_ARITY          = SYS_TAB + 3*29
                                                  // slots 30-31 reserved
.const SYS_TAB_END              = SYS_TAB + 3*32  // = $0880 (kernel code start)
