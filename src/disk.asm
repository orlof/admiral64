// -----------------------------------------------------------------------------
// disk.asm — KERNAL/IEC wrappers for device 8 (one-drive 1541).
//
// Steady state runtime has $01 = MEM_NORMAL ($34): KERNAL banked OUT. Every
// JSR into KERNAL ROM brackets the call with `lda #MEM_KERNAL; sta $01`
// before and `lda #MEM_NORMAL; sta $01` after. The IRQ handler's own
// $01-save/restore (admiral.asm:220) makes the bracket interrupt-safe — no
// SEI/CLI needed.
//
// Filename construction lives in disk_filename_buf (24 bytes after code).
// KERNAL's IEC engine reads from this buffer during OPEN's LISTEN/NAME
// session, so the buffer must stay stable between SETNAM and the matching
// OPEN+CHKIN/CHKOUT — caller must not call disk_open_* concurrently.
//
// Channels:
//   lfn 2, sec 2 — SEQ read   (0:NAME,S,R)
//   lfn 2, sec 3 — SEQ write  (@0:NAME,S,W — always overwrite)
//   lfn 15       — command/error channel (used by Phase 2+)
//
// Phase 1 surface area:
//   disk_open_seq_w(W0=name_ptr, B0=name_len)   // open + CHKOUT lfn 2
//   disk_open_seq_r(W0=name_ptr, B0=name_len)   // open + CHKIN  lfn 2
//   disk_byte_w(A=byte)                         // CHROUT one byte
//   disk_byte_r → A=byte, C=EOF                 // CHRIN  one byte
//   disk_close_data()                           // CLOSE 2 + CLRCHN
//
// Higher-level helpers (status check, command channel, dir listing) come in
// later phases.
// -----------------------------------------------------------------------------

#importonce
#import "defs.asm"
#import "stacks.asm"
#import "preamble.asm"
#import "handle.asm"
#import "array.asm"
#import "list.asm"
#import "dict.asm"

.const KERNAL_SETLFS = $FFBA
.const KERNAL_SETNAM = $FFBD
.const KERNAL_OPEN   = $FFC0
.const KERNAL_CLOSE  = $FFC3
.const KERNAL_CHKIN  = $FFC6
.const KERNAL_CHKOUT = $FFC9
.const KERNAL_CLRCHN = $FFCC
.const KERNAL_CHRIN  = $FFCF
.const KERNAL_CHROUT = $FFD2

.const DISK_LFN_DATA = 2
.const DISK_LFN_CMD  = 15
.const DISK_DEV      = 8

// -----------------------------------------------------------------------------
// disk_open_seq_w — open SEQ file for write, route output to it.
//   in:  W0 = pointer to filename bytes (PETSCII)
//        B0 = filename length (1..12)
//   clobbers: A, X, Y. W0/B0 not preserved (this is a leaf helper, no preamble).
//
// Builds "@0:NAME,S,W" in disk_filename_buf — `@` forces overwrite of any
// existing file with the same name (matches Admiral semantics: save replaces).
// After OPEN+CHKOUT, every subsequent disk_byte_w writes to this file until
// disk_close_data.
// -----------------------------------------------------------------------------
disk_open_seq_w:
    // Prefix: "@0:" — 3 bytes
    lda #$40                          // '@'
    sta disk_filename_buf
    lda #$30                          // '0'
    sta disk_filename_buf + 1
    lda #$3A                          // ':'
    sta disk_filename_buf + 2

    // Copy filename body. Y indexes both source (via (W0),y) and dest.
    ldy #0
!loop:
    cpy B0
    beq !done+
    lda (W0),y
    sta disk_filename_buf + 3,y
    iny
    bne !loop-                        // unconditional after the cpy guard
!done:
    // Suffix: ",S,W" — 4 bytes
    lda #$2C                          // ','
    sta disk_filename_buf + 3,y
    lda #$53                          // 'S'
    sta disk_filename_buf + 4,y
    lda #$2C                          // ','
    sta disk_filename_buf + 5,y
    lda #$57                          // 'W'
    sta disk_filename_buf + 6,y

    // Total length = 3 (prefix) + B0 + 4 (suffix) = B0 + 7
    lda B0
    clc
    adc #7
    pha                               // stash for SETNAM call

    // SETLFS A=lfn=2, X=dev=8, Y=sec=3
    lda #DISK_LFN_DATA
    ldx #DISK_DEV
    ldy #3
    jsr _disk_kjsr_setlfs

    // SETNAM A=length, X=ptr_lo, Y=ptr_hi
    pla                               // length
    ldx #<disk_filename_buf
    ldy #>disk_filename_buf
    jsr _disk_kjsr_setnam

    jsr _disk_kjsr_open

    // CHKOUT routes subsequent CHROUT to lfn 2.
    ldx #DISK_LFN_DATA
    jmp _disk_kjsr_chkout

// -----------------------------------------------------------------------------
// disk_open_seq_r — open SEQ file for read, route input from it.
//   in:  W0 = pointer to filename bytes (PETSCII)
//        B0 = filename length (1..12)
//   clobbers: A, X, Y.
//
// Builds "0:NAME,S,R". Drive prefix "0:" disambiguates against potential
// dual-drive units; harmless on stock 1541.
// -----------------------------------------------------------------------------
disk_open_seq_r:
    // Prefix: "0:" — 2 bytes
    lda #$30                          // '0'
    sta disk_filename_buf
    lda #$3A                          // ':'
    sta disk_filename_buf + 1

    ldy #0
!loop:
    cpy B0
    beq !done+
    lda (W0),y
    sta disk_filename_buf + 2,y
    iny
    bne !loop-
!done:
    // Suffix: ",S,R"
    lda #$2C
    sta disk_filename_buf + 2,y
    lda #$53
    sta disk_filename_buf + 3,y
    lda #$2C
    sta disk_filename_buf + 4,y
    lda #$52                          // 'R'
    sta disk_filename_buf + 5,y

    lda B0
    clc
    adc #6
    pha

    lda #DISK_LFN_DATA
    ldx #DISK_DEV
    ldy #2
    jsr _disk_kjsr_setlfs

    pla
    ldx #<disk_filename_buf
    ldy #>disk_filename_buf
    jsr _disk_kjsr_setnam

    jsr _disk_kjsr_open

    ldx #DISK_LFN_DATA
    jmp _disk_kjsr_chkin

// -----------------------------------------------------------------------------
// disk_open_dir — open the disk directory ("$") for read on lfn 2.
//   clobbers: A, X, Y.
//
// The 1541 returns the directory as a fake BASIC program. Caller is expected
// to skip the 2-byte load address and parse line records.
// -----------------------------------------------------------------------------
disk_open_dir:
    lda #$24                          // '$'
    sta disk_filename_buf

    lda #DISK_LFN_DATA
    ldx #DISK_DEV
    ldy #0                            // sec 0 = LOAD-style read
    jsr _disk_kjsr_setlfs

    lda #1                            // filename length
    ldx #<disk_filename_buf
    ldy #>disk_filename_buf
    jsr _disk_kjsr_setnam

    jsr _disk_kjsr_open

    ldx #DISK_LFN_DATA
    jmp _disk_kjsr_chkin

// -----------------------------------------------------------------------------
// disk_byte_w — write one byte to the active output (lfn 2 after open_seq_w).
//   in:  A = byte to write
//   clobbers: A. X/Y preserved through KERNAL CHROUT (KERNAL contract).
// -----------------------------------------------------------------------------
disk_byte_w:
    pha
    lda #MEM_KERNAL
    sta $01
    pla
    jsr KERNAL_CHROUT
    pha
    lda #MEM_NORMAL
    sta $01
    pla
    rts

// -----------------------------------------------------------------------------
// disk_byte_r — read one byte from the active input (lfn 2 after open_seq_r).
//   out: A = byte read
//        C = EOF flag (1 if this byte was the last in the file)
//   clobbers: A. X/Y preserved.
//
// Sets carry from ST.bit6 ($90) AFTER the read, so callers can do
//   jsr disk_byte_r
//   bcs done            ; this was the last byte; still process A then exit
//   sta buf,x
//   inx
//   bne loop
// -----------------------------------------------------------------------------
disk_byte_r:
    lda #MEM_KERNAL
    sta $01
    jsr KERNAL_CHRIN
    pha                               // stash byte on HW stack across bank-out
    lda $90                           // ST byte (KERNAL writes here)
    and #$40                          // EOF bit
    cmp #$01                          // C = (ST.bit6 != 0)
    php                               // save C across bank-out
    lda #MEM_NORMAL
    sta $01
    plp                               // restore C
    pla                               // recover byte; PLA preserves C
    rts

// -----------------------------------------------------------------------------
// disk_close_data — close lfn 2 and restore default I/O.
//   clobbers: A, X, Y.
// -----------------------------------------------------------------------------
disk_close_data:
    lda #DISK_LFN_DATA
    jsr _disk_kjsr_close
    jmp _disk_kjsr_clrchn

// -----------------------------------------------------------------------------
// Internal: bank-toggled JSR helpers. Each one banks KERNAL in, calls the
// KERNAL routine with original A/X/Y, banks back to MEM_NORMAL, and RTS.
// A is preserved across the bracket where it is the input or output of the
// underlying KERNAL routine; status flags from the KERNAL call are NOT
// preserved (the bank-out STA $01 clobbers Z/N). For the routines that
// indicate failure via C (OPEN, CHKIN, CHKOUT), the underlying contract is
// already squishy and we lean on the cmd-channel error read (Phase 2+).
// -----------------------------------------------------------------------------
_disk_kjsr_setlfs:
    pha
    lda #MEM_KERNAL
    sta $01
    pla
    jsr KERNAL_SETLFS
    lda #MEM_NORMAL
    sta $01
    rts

_disk_kjsr_setnam:
    pha
    lda #MEM_KERNAL
    sta $01
    pla
    jsr KERNAL_SETNAM
    lda #MEM_NORMAL
    sta $01
    rts

_disk_kjsr_open:
    lda #MEM_KERNAL
    sta $01
    jsr KERNAL_OPEN
    pha
    lda #MEM_NORMAL
    sta $01
    pla
    rts

_disk_kjsr_close:
    pha
    lda #MEM_KERNAL
    sta $01
    pla
    jsr KERNAL_CLOSE
    lda #MEM_NORMAL
    sta $01
    rts

_disk_kjsr_chkin:
    lda #MEM_KERNAL
    sta $01
    jsr KERNAL_CHKIN
    pha
    lda #MEM_NORMAL
    sta $01
    pla
    rts

_disk_kjsr_chkout:
    lda #MEM_KERNAL
    sta $01
    jsr KERNAL_CHKOUT
    pha
    lda #MEM_NORMAL
    sta $01
    pla
    rts

_disk_kjsr_clrchn:
    lda #MEM_KERNAL
    sta $01
    jsr KERNAL_CLRCHN
    lda #MEM_NORMAL
    sta $01
    rts

// -----------------------------------------------------------------------------
// disk_dos_cmd — send a DOS command via the command channel (lfn 15).
//   in:  W0 = pointer to command bytes, B0 = length
//   clobbers: A, X, Y.
//
// Opens lfn 15 sec 15 with the command string as filename — DOS executes
// the command on the LISTEN/OPEN sequence. Then CHKIN's lfn 15 so the
// caller can read the resulting status via disk_check_status. Caller must
// follow up with disk_close_cmd to release the channel.
// -----------------------------------------------------------------------------
disk_dos_cmd:
    lda #DISK_LFN_CMD
    ldx #DISK_DEV
    ldy #DISK_LFN_CMD                 // sec 15 = command channel
    jsr _disk_kjsr_setlfs

    lda B0
    ldx W0
    ldy W0+1
    jsr _disk_kjsr_setnam

    jsr _disk_kjsr_open

    ldx #DISK_LFN_CMD
    jmp _disk_kjsr_chkin

// -----------------------------------------------------------------------------
// disk_close_cmd — close lfn 15 + restore default I/O.
//   clobbers: A, X, Y.
// -----------------------------------------------------------------------------
disk_close_cmd:
    lda #DISK_LFN_CMD
    jsr _disk_kjsr_close
    jmp _disk_kjsr_clrchn

// -----------------------------------------------------------------------------
// disk_check_status — read the DOS error channel (lfn 15 must be open and
// CHKIN'd) and return the decoded 2-digit error code in A.
//   out: A = 0..99 (00 = OK)
//   clobbers: A, X, Y, B5, B6, B7. Drains the channel through CR or EOF.
//
// Status reply format: "<CC>,<MSG>,<TT>,<SS>\r" — first two bytes are the
// error code in ASCII decimal. We decode those, then drain the rest until
// ST.bit6 (EOF) is set so the channel is left at a clean position before
// disk_close_cmd.
// -----------------------------------------------------------------------------
disk_check_status:
    jsr disk_byte_r                   // A = tens digit (ASCII)
    sec
    sbc #$30                          // → 0..9
    sta B5                            // stash tens
    asl                               // *2
    sta B6
    asl                               // *4
    asl                               // *8
    clc
    adc B6                            // *8 + *2 = *10
    sta B6                            // B6 = tens * 10

    jsr disk_byte_r                   // A = ones digit
    sec
    sbc #$30                          // → 0..9
    clc
    adc B6
    sta B6                            // B6 = decoded code

_dcs_drain:
    // ST is in $90, written by KERNAL CHRIN; bit 6 = EOF.
    lda $90
    and #$40
    bne _dcs_done
    jsr disk_byte_r
    jmp _dcs_drain
_dcs_done:
    lda B6
    rts

// -----------------------------------------------------------------------------
// disk_dos_cmd_check — send a DOS command and return status.
//   in:  W0 = ptr, B0 = length
//   out: A = DOS status code (0 = OK)
//   clobbers: A, X, Y, B5, B6, B7.
//
// Convenience wrapper: disk_dos_cmd → disk_check_status → disk_close_cmd.
// -----------------------------------------------------------------------------
disk_dos_cmd_check:
    jsr disk_dos_cmd
    jsr disk_check_status
    pha                               // preserve status across close
    jsr disk_close_cmd
    pla
    rts

// -----------------------------------------------------------------------------
// disk_status_check — open ch15 (no name), read DOS status, close.
//   out: A = DOS status code (00 = OK)
//   clobbers: A, X, Y, B5, B6, B7.
//
// Use after a SEQ-write/read sequence to surface any disk error (write
// protect, disk full, FILE NOT FOUND, etc.) — DOS accumulates the most
// recent status in the error channel and returns it on the next read.
// -----------------------------------------------------------------------------
disk_status_check:
    lda #DISK_LFN_CMD
    ldx #DISK_DEV
    ldy #DISK_LFN_CMD
    jsr _disk_kjsr_setlfs

    lda #0                            // empty name → just open for status
    ldx #0
    ldy #0
    jsr _disk_kjsr_setnam

    jsr _disk_kjsr_open

    ldx #DISK_LFN_CMD
    jsr _disk_kjsr_chkin

    jsr disk_check_status
    pha
    jsr disk_close_cmd
    pla
    rts

// -----------------------------------------------------------------------------
// disk_serialize_w0 — emit a record stream for the object graph rooted at the
// handle in W0. Caller has already opened the SEQ-write channel via
// disk_open_seq_w. We emit raw bytes via disk_byte_w; caller closes after.
//
// Stream format: per object, {ID, TYPE, SIZE, DATA[SIZE]}, terminated by a
// final ID = 0x0000.
//   ID    — 2 bytes LE = original handle pointer (stable identity in the dump)
//   TYPE  — 1 byte = H_TYPE
//   SIZE  — 2 bytes LE = byte count of DATA (NOT element count)
//   DATA  — for containers (LIST/TUPLE/DICT): SIZE/2 16-bit child IDs;
//           for scalars: raw payload bytes
//
// BFS over the graph: maintain a TYPE_LIST work-set rooted on RS, walk it by
// index. Each iteration emits one record; for container records, every
// child reference is checked against the work-set and appended if unseen
// (linear-scan dedup, O(N²) worst case — matches the DCPU implementation).
//
// Limits: container O_LEN ≤ 255, scalar payload ≤ 255 bytes. The high byte
// of O_LEN is currently ignored in the data loop. Total graph size is
// bounded only by available heap (work-set grows as a TYPE_LIST).
//
//   in:  W0 = root handle to serialize
//   clobbers: standard V4' (caller's W/B preserved by frame).
// -----------------------------------------------------------------------------
disk_serialize_w0:
    preamble_args(0, 0)

    rs_push(W0)                       // RS: [..., root] — keep root rooted

    // Allocate empty work list. RS: [..., root, work_list].
    lda #0
    jsr list_alloc                    // RV = empty TYPE_LIST handle
    rs_push(RV)

    // Append root to work_list.
    rs_peek(W0)                       // W0 = work_list
    rs_push(W0)                       // RS: [..., root, work_list, work_list]
    rs_peek_at(W0, 2)                 // W0 = root
    rs_push(W0)                       // RS: [..., root, work_list, work_list, root]
    jsr list_append                   // RS: [..., root, work_list]

    lda #0
    sta B6                            // B6 = i (outer iteration index)

_dser_outer:
    // Re-fetch work_list payload + len each iteration; list_append may have
    // grown it (and GC compaction may have moved its data).
    rs_peek(W0)                       // W0 = work_list handle (stable)
    jsr deref_W0_to_W2                // A = O_LEN low, W2 = payload
    cmp B6
    bne !+                            // i < len → keep going
    jmp _dser_outer_done               // i == len → done (long branch)
!:

    // W0 = work_list[i] (the current handle to serialize).
    lda B6
    asl
    tay
    lda (W2),y
    sta W0
    iny
    lda (W2),y
    sta W0+1

    // ---- Emit ID ----
    lda W0
    jsr disk_byte_w
    lda W0+1
    jsr disk_byte_w

    // ---- Emit TYPE, cache in B5 ----
    ldy #H_TYPE
    lda (W0),y
    sta B5
    jsr disk_byte_w

    // ---- Compute SIZE into B0:B1, emit ----
    cmp #TYPE_LIST                    // A still = type
    beq _dser_size_container
    cmp #TYPE_TUPLE
    beq _dser_size_container
    cmp #TYPE_DICT
    beq _dser_size_container

    // Scalar: SIZE = H_SIZE - O_HEADER (= total payload byte count).
    sec
    ldy #H_SIZE
    lda (W0),y
    sbc #O_HEADER
    sta B0
    iny
    lda (W0),y
    sbc #0
    sta B1
    jmp _dser_emit_size

_dser_size_container:
    // SIZE = O_LEN * 2. O_LEN ≤ 255 cap; 2*255 = 510 fits in 9 bits.
    jsr deref_W0_to_W2                // A = O_LEN low
    asl                                // *2; carry = high bit
    sta B0
    lda #0
    rol                                // A = carry-in (0 or 1)
    sta B1

_dser_emit_size:
    lda B0
    jsr disk_byte_w
    lda B1
    jsr disk_byte_w

    // ---- Emit DATA ----
    lda B5
    cmp #TYPE_LIST
    beq _dser_data_container
    cmp #TYPE_TUPLE
    beq _dser_data_container
    cmp #TYPE_DICT
    beq _dser_data_container
    jmp _dser_data_scalar

_dser_data_scalar:
    // Stream B0 bytes from payload (cap ≤ 255 so single-byte index suffices).
    // disk_byte_w → KERNAL CHROUT preserves Y (CBM ROM contract; our mock
    // matches), so the index doesn't need to be cached across the JSR.
    jsr deref_W0_to_W2                // W2 = payload start (bytes)
    ldy #0
_dser_scalar_loop:
    cpy B0
    beq _dser_record_done
    lda (W2),y
    jsr disk_byte_w
    iny
    bne _dser_scalar_loop             // unconditional (B0 ≤ 255 cap)

_dser_data_container:
    // For each child slot j = 0..O_LEN-1:
    //   1. read child handle from container payload
    //   2. emit child ID
    //   3. dedup-check work_list; append if missing
    //
    // O_LEN cached in B4 (≤ 255). Inner loop counter B7 = j.
    jsr deref_W0_to_W2                // A = O_LEN low (W2 ignored on first pass)
    sta B4
    lda #0
    sta B7
_dser_child_loop:
    lda B7
    cmp B4
    beq _dser_record_done

    // Re-deref container — list_append in prior iteration may have GC'd.
    jsr deref_W0_to_W2                // W2 = container payload, A = O_LEN
    lda B7
    asl
    tay
    lda (W2),y
    sta B2                            // child handle low
    iny
    lda (W2),y
    sta B3                            // child handle high

    // Emit child ID
    lda B2
    jsr disk_byte_w
    lda B3
    jsr disk_byte_w

    // Dedup search: is {B2,B3} already in work_list?
    jsr _dser_search_worklist         // A = 0 (not found) or 1 (found)
    bne _dser_child_skip_append

    // Append to work_list. RS: [..., root, work_list]; container handle in W0.
    rs_peek(W1)                       // W1 = work_list (W0 preserved)
    rs_push(W1)                       // container for list_append
    lda B2
    sta W3
    lda B3
    sta W3+1
    rs_push(W3)                       // child for list_append
    jsr list_append
    // After list_append: W0..W3, B0..B7 preserved by V4' frame.

_dser_child_skip_append:
    inc B7
    jmp _dser_child_loop

_dser_record_done:
    inc B6
    jmp _dser_outer

_dser_outer_done:
    // ---- Terminator: ID = 0x0000 ----
    lda #0
    jsr disk_byte_w
    lda #0
    jsr disk_byte_w

    // Drop work_list and root from RS.
    rs_pop(W0)                        // discard work_list
    rs_pop(W0)                        // discard root

    jmp postamble

// -----------------------------------------------------------------------------
// _dser_search_worklist — linear scan of the work_list (RS top) for a handle.
//   in:  B2:B3 = handle to find
//   out: A = 0 (not found) or 1 (found)
//   clobbers: A, X, Y, W1, W3
//   preserves: W0, B0..B7 except as input.
// -----------------------------------------------------------------------------
_dser_search_worklist:
    rs_peek(W1)                       // W1 = work_list (preserves W0)
    jsr deref_W1_to_W3                // A = O_LEN, W3 = payload
    tax                                // X = remaining count
    beq _dsw_not_found
    ldy #0
_dsw_loop:
    lda (W3),y
    cmp B2
    bne _dsw_skip
    iny
    lda (W3),y
    dey
    cmp B3
    beq _dsw_found
_dsw_skip:
    iny
    iny
    dex
    bne _dsw_loop
_dsw_not_found:
    lda #0
    rts
_dsw_found:
    lda #1
    rts

// -----------------------------------------------------------------------------
// disk_morph_w0 — change an existing handle's (TYPE, SIZE) in place.
//
// Allocates fresh data area at NEXT_DATA via heap_carve_payload, repoints
// the handle's H_PTR/H_SIZE/H_TYPE, writes O_LEN. The handle's address is
// stable, so any references already pointing at this handle remain valid —
// this is what makes forward-reference fix-up sound during deserialize.
//
//   in:  RS top: target handle (rooted across the heap_carve_payload retry)
//        B5    : new TYPE
//        B2:B3 : new SIZE (data byte count, NOT including O_HEADER)
//   out: W2 = pointer to fresh payload bytes (post-O_LEN). Caller fills.
//   clobbers: A, X, Y, W0, W2, W3, B0..B7 except as input.
// V4'.
// -----------------------------------------------------------------------------
disk_morph_w0:
    preamble_args(1, 0)

    lda B2
    sta ALLOC_SIZE
    lda B3
    sta ALLOC_SIZE+1

    jsr heap_carve_payload            // RV = new object base; may GC-retry

    rs_peek(W0)                       // re-fetch handle (ZP-stable already,
                                       // but refresh for clarity)

    // H_PTR = RV
    ldy #H_PTR
    lda RV
    sta (W0),y
    iny
    lda RV+1
    sta (W0),y

    // H_SIZE = SIZE + O_HEADER
    clc
    lda B2
    adc #O_HEADER
    sta W2
    lda B3
    adc #0
    sta W2+1
    ldy #H_SIZE
    lda W2
    sta (W0),y
    iny
    lda W2+1
    sta (W0),y

    // H_TYPE = B5
    ldy #H_TYPE
    lda B5
    sta (W0),y

    // Compute and write O_LEN at *RV. Containers store element count
    // (= SIZE/2); scalars store byte count (= SIZE).
    lda B5
    cmp #TYPE_LIST
    beq _dmw_container
    cmp #TYPE_TUPLE
    beq _dmw_container
    cmp #TYPE_DICT
    beq _dmw_container

    // Scalar: heap_carve_payload already wrote O_LEN = SIZE; nothing to do.
    jmp _dmw_relink

_dmw_container:
    ldy #O_LEN
    lda B2
    lsr                                // /2 (assumes high byte = 0; cap 510B)
    sta (RV),y
    iny
    lda #0
    sta (RV),y

_dmw_relink:
    // heap_carve_payload always carves at NEXT_DATA (highest H_PTR), so the
    // handle now belongs at the tail of RESERVED to keep the ascending-PTR
    // invariant gc_compact requires.
    rs_peek(W0)
    jsr _relink_to_tail

    // Compute W2 = payload base for caller. Postamble pops the rooted handle.
    clc
    lda RV
    adc #O_HEADER
    sta W2
    lda RV+1
    adc #0
    sta W2+1

    jmp postamble

// -----------------------------------------------------------------------------
// disk_deserialize — read records from the open SEQ-read channel and rebuild
// the object graph. PRECONDITION: caller has already opened the channel via
// disk_open_seq_r. The first record's new handle is the graph's root.
//
//   out: RV = root handle (handle of the first record read).
//
// id-map representation: two parallel TYPE_LISTs rooted on RS.
//   old_ids:     each entry is a TYPE_INT (2-byte payload) holding an old ID
//   new_handles: each entry is the corresponding live handle
//
// On encountering a record:
//   1. Read {ID, TYPE, SIZE} (5 bytes).
//   2. Look up ID in old_ids:
//      - Hit: morph the existing placeholder handle to (TYPE, SIZE).
//      - Miss: alloc(TYPE, SIZE), append (ID-int, handle) to the lists.
//   3. Read DATA:
//      - Container: SIZE/2 child sub-IDs, each looked up (or placeholder
//        allocated) and written into the new handle's payload.
//      - Scalar: SIZE bytes copied verbatim into the new handle's payload.
// Stop at ID == 0x0000. Return the root (the first record's handle).
//
//   clobbers: standard V4' (caller's W/B preserved).
// -----------------------------------------------------------------------------
disk_deserialize:
    preamble_args(0, 0)

    // Allocate id-map lists. RS: [..., old_ids, new_handles].
    // The graph root is implicitly new_handles[0] (the FIRST record's
    // handle, which is what disk_serialize_w0 emits first by construction).
    lda #0
    jsr list_alloc
    rs_push(RV)
    lda #0
    jsr list_alloc
    rs_push(RV)

_dds_loop:
    // Read ID (2 bytes LE)
    jsr disk_byte_r
    sta B0                             // B0 = ID low
    jsr disk_byte_r
    sta B1                             // B1 = ID high

    // Terminator?
    lda B0
    ora B1
    bne !+
    jmp _dds_done                      // long branch
!:

    // Read TYPE
    jsr disk_byte_r
    sta B5                             // B5 = TYPE

    // Read SIZE
    jsr disk_byte_r
    sta B2                             // B2 = SIZE low
    jsr disk_byte_r
    sta B3                             // B3 = SIZE high

    // Look up ID in old_ids list. Returns A = index+1, or 0 if miss.
    // On hit, _ddeser_lookup_old also leaves the matched new_handle in W1.
    jsr _ddeser_lookup_old
    bne _dds_morph_existing

    // Miss: alloc fresh handle, bind in id-map.
    jsr _ddeser_alloc_and_bind         // W0 = new handle
    jmp _dds_have_handle

_dds_morph_existing:
    // W1 = matched new_handle from lookup. Push onto RS to root for morph,
    // then morph it to (TYPE=B5, SIZE=B2:B3).
    rs_push(W1)                        // RS top: target handle for morph
    jsr disk_morph_w0                  // pops the rooted handle, returns W2 = payload

    // Refresh W0 to the morphed handle (lookup returned it in W1).
    // After the morph postamble W1 is restored by V4', so it's still valid.
    lda W1
    sta W0
    lda W1+1
    sta W0+1

_dds_have_handle:
    // ---- Read DATA bytes ----
    lda B5
    cmp #TYPE_LIST
    beq _dds_data_container
    cmp #TYPE_TUPLE
    beq _dds_data_container
    cmp #TYPE_DICT
    beq _dds_data_container

    // Scalar: read SIZE bytes (cap ≤ 255) into payload.
    jsr deref_W0_to_W2                 // W2 = payload start
    ldy #0
_dds_scalar_loop:
    cpy B2
    beq _dds_record_done
    jsr disk_byte_r
    sta (W2),y
    iny
    bne _dds_scalar_loop

_dds_data_container:
    // SIZE/2 children. Read each sub-ID, look up (or alloc placeholder),
    // write resolved handle into container payload[j*2..j*2+1].
    lda B2
    lsr
    sta B4                             // B4 = element count
    lda #0
    sta B7                             // B7 = j (child index)

_dds_child_loop:
    lda B7
    cmp B4
    beq _dds_record_done

    // Read child sub-ID into B0:B1. Reuse B0:B1 since outer ID was used
    // only at lookup time (already past that for this record).
    jsr disk_byte_r
    sta B0
    jsr disk_byte_r
    sta B1

    // _ddeser_lookup_or_placeholder clobbers W0 (sets it to a new placeholder
    // on the alloc path). The container is already a GC root via new_handles,
    // so we just stash W0 on the HW stack to refresh it after — pushing onto
    // RS would shift the alloc-and-bind helper's RS-depth indices.
    lda W0
    pha
    lda W0+1
    pha
    jsr _ddeser_lookup_or_placeholder  // W1 = handle for sub_id
    pla
    sta W0+1
    pla
    sta W0

    jsr deref_W0_to_W2                  // W2 = container payload (post-GC)

    // payload[j*2] = W1 (low/high)
    lda B7
    asl
    tay
    lda W1
    sta (W2),y
    iny
    lda W1+1
    sta (W2),y

    inc B7
    jmp _dds_child_loop

_dds_record_done:
    jmp _dds_loop

_dds_done:
    // Root = new_handles[0] (BFS-first record).
    rs_peek(W0)                        // W0 = new_handles list
    jsr deref_W0_to_W2                 // W2 = payload start
    ldy #0
    lda (W2),y
    sta RV
    iny
    lda (W2),y
    sta RV+1

    // Drop new_handles, old_ids.
    rs_pop(W0)
    rs_pop(W0)

    jmp postamble

// -----------------------------------------------------------------------------
// _ddeser_lookup_old — scan old_ids list for the 2-byte ID in B0:B1.
//   in:  B0:B1 = target old ID; RS layout: [..., old_ids, new_handles]
//   out: A = 0 if not found, else (matched_index + 1)
//        On hit: W1 = new_handles[matched_index]
//   clobbers: A, X, Y, W1, W3 (W0/W2 preserved)
// -----------------------------------------------------------------------------
_ddeser_lookup_old:
    rs_peek_at(W1, 1)                 // W1 = old_ids list (RS depth 1)
    jsr deref_W1_to_W3                // A = O_LEN, W3 = payload
    tax
    beq _dlo_not_found

    ldy #0
    sty B6                             // B6 = current index
_dlo_iter:
    // W3[Y..Y+1] = int handle of this old_id slot
    lda (W3),y
    sta W1
    iny
    lda (W3),y
    sta W1+1                           // W1 = TYPE_INT handle of stored ID

    // Compare its 2-byte payload against B0:B1
    txa                                 // save X (count)
    pha
    lda W3                              // save W3 (we'll deref into it)
    pha
    lda W3+1
    pha
    jsr deref_W1_to_W3                  // now W3 = stored-id payload (2 bytes)
    ldy #0
    lda (W3),y
    cmp B0
    bne _dlo_no_match
    iny
    lda (W3),y
    cmp B1
    beq _dlo_match
_dlo_no_match:
    pla
    sta W3+1
    pla
    sta W3
    pla
    tax
    // resume outer iteration: advance Y, dec X
    lda B6
    asl
    clc
    adc #2                              // Y = (B6+1)*2
    tay
    inc B6
    dex
    bne _dlo_iter
_dlo_not_found:
    lda #0
    rts

_dlo_match:
    // Discard the saved W3+pla (we don't need it back; we want to fetch
    // new_handles[matched_index] instead).
    pla                                 // toss W3+1
    pla                                 // toss W3
    pla                                 // toss X
    // Now fetch new_handles[B6] into W1.
    rs_peek(W1)                         // W1 = new_handles list (RS depth 0)
    jsr deref_W1_to_W3                  // W3 = new_handles payload
    lda B6
    asl
    tay
    lda (W3),y
    sta W1
    iny
    lda (W3),y
    sta W1+1
    lda B6
    clc
    adc #1                              // return index+1
    rts

// -----------------------------------------------------------------------------
// _ddeser_alloc_and_bind — allocate a new handle of (TYPE=B5, SIZE=B2:B3),
// register it in the id-map under old_id (B0:B1), return handle in W0.
//
// For container types, alloc with element count = SIZE/2; for scalars,
// alloc with byte count = SIZE.
//
//   in:  B0:B1 = old_id, B5 = type, B2:B3 = size
//   out: W0 = new handle
//   clobbers: A, X, Y, W2, W3 (B0..B7 preserved by sub-call frames)
// -----------------------------------------------------------------------------
_ddeser_alloc_and_bind:
    lda B5
    cmp #TYPE_LIST
    beq _dab_container
    cmp #TYPE_TUPLE
    beq _dab_container
    cmp #TYPE_DICT
    beq _dab_container

    // Scalar: alloc(SIZE bytes, B5)
    lda B2
    sta ALLOC_SIZE
    lda B3
    sta ALLOC_SIZE+1
    lda B5
    sta ALLOC_TYPE
    jsr alloc                           // RV = new handle
    jmp _dab_register

_dab_container:
    // Container: _array_alloc_init(N=SIZE/2, type=B5). Caller must already
    // be inside a V4'-wrapped body (we are: deserialize's frame).
    lda B2
    lsr                                 // A = element count (≤ 127 cap)
    ldx B5
    jsr _array_alloc_init               // RV = new container handle

_dab_register:
    // Save new handle on RS so it survives the next list_appends.
    rs_push(RV)                         // RS: [..., old_ids, new_handles, new_handle]

    // Allocate a 2-byte TYPE_INT to hold old_id.
    lda #2
    jsr alloc_int_a_deref_w2            // RV = int handle, W2 = payload
    ldy #0
    lda B0
    sta (W2),y
    iny
    lda B1
    sta (W2),y
    rs_push(RV)                         // RS: [..., old_ids, new_handles, new_handle, int_id]

    // Append int_id to old_ids list. RS: [..., old_ids, new_handles, new_handle, int_id]
    rs_peek_at(W0, 3)                   // W0 = old_ids
    rs_push(W0)
    rs_peek_at(W0, 1)                   // W0 = int_id
    rs_push(W0)
    jsr list_append                     // pops 2; RS: [..., old_ids, new_handles, new_handle, int_id]
    rs_pop(W0)                          // pop int_id (now in old_ids list, rooted)

    // Append new_handle to new_handles list.
    rs_peek_at(W0, 1)                   // W0 = new_handles
    rs_push(W0)
    rs_peek_at(W0, 1)                   // W0 = new_handle
    rs_push(W0)
    jsr list_append                     // pops 2

    // Pop new_handle from RS into W0 (now also rooted via new_handles list).
    rs_pop(W0)
    rts

// -----------------------------------------------------------------------------
// _ddeser_lookup_or_placeholder — given child sub-ID in B0:B1, return the
// corresponding live handle in W1. If not in id-map: alloc TYPE_NONE
// placeholder, register under sub-ID, return placeholder in W1.
//
//   in:  B0:B1 = sub-ID (preserved across this call)
//   out: W1 = live handle for this ID
//   clobbers: A, X, Y, W2, W3 (W0 and B0..B7 preserved by sub-call frames)
// -----------------------------------------------------------------------------
_ddeser_lookup_or_placeholder:
    jsr _ddeser_lookup_old              // A = idx+1, or 0
    bne _dlop_done                      // hit: W1 already set

    // Miss: alloc TYPE_NONE placeholder (size 0). Save B5/B2/B3 — they
    // belong to the OUTER record, not the placeholder.
    lda B5
    pha
    lda B2
    pha
    lda B3
    pha

    lda #TYPE_NONE
    sta B5
    lda #0
    sta B2
    sta B3
    jsr _ddeser_alloc_and_bind          // W0 = placeholder; bound under B0:B1

    pla
    sta B3
    pla
    sta B2
    pla
    sta B5

    // Return placeholder in W1 for caller to write into container.
    lda W0
    sta W1
    lda W0+1
    sta W1+1
_dlop_done:
    rts

// -----------------------------------------------------------------------------
// disk_dir — read directory ("$") and return a TYPE_DICT { name → blocks }.
//   out: RV = dict handle. Caller closes via disk_close_data.
//
// The directory comes back as a fake BASIC program:
//   $0401 load address (2 bytes)
//   per line: link(2), line#(2), text..., 0
//   final 00 00 closes the program
//
// Each text line has the filename in double-quotes; the line number is the
// CBM block count (file size in 254-byte blocks). The line-0 header carries
// the disk name in quotes — we skip it. The "BLOCKS FREE." footer has no
// quoted name and is also skipped naturally.
//
//   clobbers: standard V4'.
// -----------------------------------------------------------------------------
disk_dir:
    preamble_args(0, 0)

    jsr disk_open_dir

    // Allocate empty dict, push as RS root for the duration.
    jsr dict_alloc                     // RV = empty dict
    rs_push(RV)                        // RS: [dict]

    // Skip 2-byte load address.
    jsr disk_byte_r
    jsr disk_byte_r

_ddir_line_loop:
    // Read link (2 bytes). 00 00 = end of program.
    jsr disk_byte_r
    sta B0
    jsr disk_byte_r
    ora B0
    bne !+
    jmp _ddir_done
!:
    // Read line number (= block count) into B2:B3.
    jsr disk_byte_r
    sta B2
    jsr disk_byte_r
    sta B3

    // Walk the line text, extract first quoted token into disk_filename_buf.
    // B4 = name length so far. B5 = parser state: 0 pre-quote, 1 in-name,
    // 2 post-name (drain remaining bytes until terminator).
    lda #0
    sta B4
    sta B5

_ddir_char_loop:
    jsr disk_byte_r
    cmp #0
    beq _ddir_line_done                // end-of-line terminator

    ldx B5
    bne _ddir_state_nonzero            // state 1 or 2

    // State 0: pre-quote — look for opening "
    cmp #$22                           // '"'
    bne _ddir_char_loop
    inc B5                             // → state 1
    jmp _ddir_char_loop

_ddir_state_nonzero:
    cpx #1
    bne _ddir_char_loop                // state 2: drain to terminator

    // State 1: in-name — '"' closes, otherwise append (cap at 16)
    cmp #$22
    bne _ddir_in_name_byte
    inc B5                             // → state 2
    jmp _ddir_char_loop

_ddir_in_name_byte:
    ldx B4
    cpx #16
    bcs _ddir_char_loop                // truncate beyond 16
    sta disk_filename_buf,x
    inc B4
    jmp _ddir_char_loop

_ddir_line_done:
    // Skip line if no quoted name was found, or if the line number is 0
    // (header line — disk name, not a file).
    lda B4
    beq _ddir_line_loop_jump
    lda B2
    ora B3
    beq _ddir_line_loop_jump

    // Allocate STR(name).
    lda B4
    sta ALLOC_SIZE
    lda #0
    sta ALLOC_SIZE+1
    lda #TYPE_STR
    sta ALLOC_TYPE
    jsr alloc                          // RV = name string handle
    rs_push(RV)                        // RS: [dict, name_str]

    // Copy name bytes into payload.
    jsr deref_RV_to_W2                 // W2 = payload start
    ldy #0
_ddir_copy:
    cpy B4
    beq _ddir_copy_done
    lda disk_filename_buf,y
    sta (W2),y
    iny
    bne _ddir_copy
_ddir_copy_done:

    // Allocate INT(2 bytes) holding block count.
    lda #2
    jsr alloc_int_a_deref_w2           // RV = int handle, W2 = payload
    ldy #0
    lda B2
    sta (W2),y
    iny
    lda B3
    sta (W2),y
    rs_push(RV)                        // RS: [dict, name_str, int_blocks]

    // dict_set(dict, name_str, int_blocks). Push duplicates so the rooted
    // copies remain after dict_set's 3-arg pop.
    rs_peek_at(W0, 2)                  // dict
    rs_push(W0)
    rs_peek_at(W0, 2)                  // name_str (after the push above)
    rs_push(W0)
    rs_peek_at(W0, 2)                  // int_blocks
    rs_push(W0)
    jsr dict_set                       // pops 3

    // Drop the locally-rooted name_str and int_blocks — they live in the
    // dict now (rooted via the dict's payload).
    rs_pop(W0)                         // int_blocks
    rs_pop(W0)                         // name_str

_ddir_line_loop_jump:
    jmp _ddir_line_loop

_ddir_done:
    // RV = dict; pop our root.
    rs_peek(W0)
    lda W0
    sta RV
    lda W0+1
    sta RV+1
    rs_pop(W0)

    jsr disk_close_data
    jmp postamble

// -----------------------------------------------------------------------------
// Static DOS command strings.
// -----------------------------------------------------------------------------
DOS_CMD_FORMAT:
    .text "N0:ADMIRAL,01"
.const DOS_CMD_FORMAT_LEN = * - DOS_CMD_FORMAT

// -----------------------------------------------------------------------------
// disk_filename_buf — 24-byte scratch for the SETNAM string.
//   Layout examples:
//     "@0:NAME,S,W"  → 11 bytes for a 4-char name; max 19 for 12-char name
//     "0:NAME,S,R"   → 10 bytes for a 4-char name; max 18 for 12-char name
//     "@0:" + 12-char + ",S,W" = 19. 24-byte buffer leaves 5 bytes slack.
// -----------------------------------------------------------------------------
disk_filename_buf:
    .fill 24, 0
