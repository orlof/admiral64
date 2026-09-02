"""Phase 1 disk-IO smoke tests.

Verify the KERNAL-wrapper layer in src/disk.asm round-trips bytes through
the virtual-1541 mock attached to the `hd` fixture: open SEQ-write, write
known bytes, close, open SEQ-read, read bytes back, byte-compare.

These tests do NOT exercise any of the higher-level Admiral builtins
(save/load/dir/format/rm) — those land in subsequent phases. The point
here is to prove the bank-bracketed KERNAL JSRs land correctly in the
mock and the wrappers' calling convention works end-to-end.
"""

from __future__ import annotations

import pytest

from conftest import B0, ERROR_CODE_ZP, RV, W0
from test_int_parse import _read_int
from test_str import place_str
from test_int_add import H_PTR, H_TYPE, O_HEADER, O_LEN, SIZEOF_HANDLE

ERR_DISK = 0x07
ERR_TYPE = 0x05

# Serialized record-stream type tags (must stay in sync with src/defs.asm).
SS_TYPE_INT = 0x20
SS_TYPE_STR = 0x21
SS_TYPE_BOOL = 0x22
SS_TYPE_NONE = 0x23
SS_TYPE_TUPLE = 0x24
SS_TYPE_LIST = 0x25
SS_TYPE_DICT = 0x26
SS_TYPE_FLOAT = 0x27


def parse_stream(data: bytes) -> list[dict]:
    """Decode the serialized stream into a list of records.

    Each record: {"id": handle_ptr, "type": tag, "size": payload_bytes,
    "data": raw bytes}. Stops at the first ID == 0x0000 terminator and
    asserts there are no trailing bytes after the terminator.
    """
    records: list[dict] = []
    i = 0
    while i + 2 <= len(data):
        rid = data[i] | (data[i + 1] << 8)
        i += 2
        if rid == 0:
            break
        assert i + 3 <= len(data), "stream truncated mid-header"
        rtype = data[i]
        rsize = data[i + 1] | (data[i + 2] << 8)
        i += 3
        assert i + rsize <= len(data), (
            f"stream truncated mid-data (need {rsize} bytes, have {len(data) - i})"
        )
        records.append({
            "ID": rid,
            "TYPE": rtype,
            "size": rsize,
            "data": data[i:i + rsize],
        })
        i += rsize
    return records


# Test scratch for staging the filename bytes we hand to disk_open_seq_*.
# Picked to live above the current code top (~$6900) and below the frame
# stack ($8000) — gives ~4 KB of slack as the binary grows.
NAME_ADDR = 0x9A00


def _stage_name(h, name: bytes) -> None:
    """Place `name` at NAME_ADDR and point W0/B0 at it for the wrapper."""
    h.write_bytes(NAME_ADDR, name)
    h.write_word(W0, NAME_ADDR)
    h.mpu.memory[B0] = len(name)


def _write_file(h, name: bytes, data: bytes) -> None:
    _stage_name(h, name)
    h.call("disk_open_seq_w")
    for byte in data:
        h.call("disk_byte_w", a=byte)
    h.call("disk_close_data")


def _read_file(h, name: bytes) -> bytes:
    _stage_name(h, name)
    h.call("disk_open_seq_r")
    out = bytearray()
    # Cap at a generous bound to fail fast if EOF is mishandled.
    for _ in range(8192):
        h.call("disk_byte_r")
        out.append(h.mpu.a)
        if h.mpu.p & 0x01:  # carry = EOF
            break
    else:
        raise AssertionError("disk_byte_r never reported EOF")
    h.call("disk_close_data")
    return bytes(out)


def test_open_write_close_creates_file(hd):
    _write_file(hd, b"FOO", b"HELLO")
    assert hd.kernal_mock.files == {b"FOO": b"HELLO"}


def test_filename_buffer_format_for_write(hd):
    """The wrapper builds '@0:NAME,S,W' — '@' for save-replace, ',S,W' for
    SEQ-write. Buffer stays stable through OPEN since KERNAL holds a
    pointer into it."""
    _stage_name(hd, b"FOO")
    hd.call("disk_open_seq_w")
    buf = bytes(hd.read_bytes(hd.sym["disk_filename_buf"], 10))
    assert buf == b"@0:FOO,S,W"
    hd.call("disk_close_data")


def test_filename_buffer_format_for_read(hd):
    """The read wrapper builds '0:NAME,S,R'."""
    hd.kernal_mock.files[b"FOO"] = b""
    _stage_name(hd, b"FOO")
    hd.call("disk_open_seq_r")
    buf = bytes(hd.read_bytes(hd.sym["disk_filename_buf"], 9))
    assert buf == b"0:FOO,S,R"
    hd.call("disk_close_data")


def test_round_trip_short_payload(hd):
    _write_file(hd, b"BAR", b"hello, world")
    assert _read_file(hd, b"BAR") == b"hello, world"


def test_round_trip_full_byte_range(hd):
    """Every byte value 0..255 round-trips intact — KERNAL CHRIN/CHROUT
    are 8-bit transparent (no PETSCII translation, no $03/$0D specials)."""
    data = bytes(range(256))
    _write_file(hd, b"BLOB", data)
    assert _read_file(hd, b"BLOB") == data


def test_save_replace_overwrites_existing(hd):
    """`@` prefix is the SAVE-REPLACE shortcut — DOS overwrites silently
    instead of erroring 63 FILE EXISTS."""
    hd.kernal_mock.files[b"OLD"] = b"original"
    _write_file(hd, b"OLD", b"new")
    assert hd.kernal_mock.files[b"OLD"] == b"new"


def test_eof_on_empty_file(hd):
    """Reading from a zero-byte file returns A=0 with C=1 (EOF) on the
    first read."""
    hd.kernal_mock.files[b"EMPTY"] = b""
    _stage_name(hd, b"EMPTY")
    hd.call("disk_open_seq_r")
    hd.call("disk_byte_r")
    assert hd.mpu.a == 0
    assert hd.mpu.p & 0x01, "expected EOF (carry set) on first read of empty file"
    hd.call("disk_close_data")


# ---------------------------------------------------------------------------
# Phase 2 — format() and rm() builtins, evaluated through parser_eval.
# ---------------------------------------------------------------------------


def _eval_no_result(h, source: str) -> None:
    """Evaluate Admiral source for side effects only (matches test_parser)."""
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8A00, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)


def _eval_panics_with(h, source: str, expected: int) -> None:
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8A00, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000, expect_panic=True)
    assert h.mpu.memory[ERROR_CODE_ZP] == expected, (
        f"got ERROR_CODE=${h.mpu.memory[ERROR_CODE_ZP]:02X}, "
        f"expected ${expected:02X}"
    )


def test_format_clears_files(hd):
    hd.kernal_mock.add_file(b"FOO", b"hello")
    hd.kernal_mock.add_file(b"BAR", b"world")
    _eval_no_result(hd, "FORMAT()")
    assert hd.kernal_mock.files == {}


def test_format_sets_disk_name_and_id(hd):
    hd.kernal_mock.disk_name = b"OLD"
    hd.kernal_mock.disk_id = b"ZZ"
    _eval_no_result(hd, "FORMAT()")
    assert hd.kernal_mock.disk_name == b"ADMIRAL"
    assert hd.kernal_mock.disk_id == b"01"
    assert hd.kernal_mock.formatted is True


def test_format_succeeds_when_dos_status_zero(hd):
    """N0:ADMIRAL,01 always returns 00,OK from the mock — no panic."""
    _eval_no_result(hd, "FORMAT()")
    # Check no error code was left behind from a panic that didn't abort.
    assert hd.mpu.memory[ERROR_CODE_ZP] == 0


def test_rm_removes_file(hd):
    hd.kernal_mock.add_file(b"FOO", b"x")
    hd.kernal_mock.add_file(b"BAR", b"y")
    _eval_no_result(hd, 'RM("FOO")')
    assert b"FOO" not in hd.kernal_mock.files
    assert hd.kernal_mock.files[b"BAR"] == b"y"


def test_rm_missing_file_raises_disk_err(hd):
    """DOS reports 62 FILE NOT FOUND → builtin raises ERR_DISK."""
    _eval_panics_with(hd, 'RM("MISSING")', ERR_DISK)


def test_rm_non_string_arg_raises_type_err(hd):
    _eval_panics_with(hd, "RM(42)", ERR_TYPE)


def test_rm_empty_name_raises_type_err(hd):
    _eval_panics_with(hd, 'RM("")', ERR_TYPE)


def test_rm_oversized_name_raises_type_err(hd):
    _eval_panics_with(hd, 'RM("0123456789ABC")', ERR_TYPE)  # 13 chars


# ---------------------------------------------------------------------------
# Phase 3 — save() builtin: stream emission for graphs of various shapes.
# ---------------------------------------------------------------------------


def _save_and_parse(hd, source: str, fname: bytes = b"FILE") -> list[dict]:
    _eval_no_result(hd, source)
    return parse_stream(hd.kernal_mock.files[fname])


def _int_payload(data: bytes) -> int:
    """Decode an int payload as little-endian 2's-complement."""
    if not data:
        return 0
    val = int.from_bytes(data, "little", signed=False)
    if data[-1] & 0x80:  # sign bit of MSB → negative
        val -= 1 << (8 * len(data))
    return val


def test_save_flat_int(hd):
    records = _save_and_parse(hd, 'SAVE("FILE", 42)')
    assert len(records) == 1
    rec = records[0]
    assert rec["TYPE"] == SS_TYPE_INT
    assert _int_payload(rec["data"]) == 42


def test_save_flat_string(hd):
    records = _save_and_parse(hd, 'SAVE("FILE", "abc")')
    assert len(records) == 1
    rec = records[0]
    assert rec["TYPE"] == SS_TYPE_STR
    # 'a','b','c' as PETSCII ($61..$63 are lowercase per the C64 port's
    # tokenizer, which keeps source-string bytes ASCII-compatible).
    assert rec["data"] == b"abc"


def test_save_flat_bool(hd):
    records = _save_and_parse(hd, 'SAVE("FILE", TRUE)')
    assert len(records) == 1
    assert records[0]["TYPE"] == SS_TYPE_BOOL
    assert records[0]["data"] == b"\x01"


def test_save_flat_none(hd):
    records = _save_and_parse(hd, 'SAVE("FILE", NONE)')
    assert len(records) == 1
    assert records[0]["TYPE"] == SS_TYPE_NONE
    assert records[0]["size"] == 0
    assert records[0]["data"] == b""


def test_save_empty_list(hd):
    records = _save_and_parse(hd, 'SAVE("FILE", [])')
    assert len(records) == 1
    assert records[0]["TYPE"] == SS_TYPE_LIST
    assert records[0]["size"] == 0


def test_save_list_of_ints(hd):
    records = _save_and_parse(hd, 'SAVE("FILE", [1, 2, 3])')
    # Expect 4 records: list root + three int children
    assert len(records) == 4
    root = records[0]
    assert root["TYPE"] == SS_TYPE_LIST
    assert root["size"] == 6  # three child IDs × 2 bytes each
    # Each subsequent record is a TYPE_INT
    for rec in records[1:]:
        assert rec["TYPE"] == SS_TYPE_INT
    # Container DATA holds 3 child IDs that match the next 3 record IDs in
    # the order they were enqueued (BFS preserves insertion order).
    child_ids = [
        root["data"][i] | (root["data"][i + 1] << 8) for i in range(0, 6, 2)
    ]
    rec_ids = [rec["ID"] for rec in records[1:]]
    assert child_ids == rec_ids
    # Values are 1, 2, 3
    assert [_int_payload(rec["data"]) for rec in records[1:]] == [1, 2, 3]


def test_save_shared_subobject_dedup(hd):
    """A list `[x, x]` where both slots reference the same int handle should
    serialize as one list record + ONE int record (dedup), with both child
    slots pointing at that single ID. This is the property that lets
    deserialize reconstruct the shared-identity graph."""
    records = _save_and_parse(
        hd, 'x = 42\nSAVE("FILE", [x, x])'
    )
    assert len(records) == 2  # list + one int (not two)
    root = records[0]
    assert root["TYPE"] == SS_TYPE_LIST
    assert root["size"] == 4  # two child IDs × 2 bytes
    a = root["data"][0] | (root["data"][1] << 8)
    b = root["data"][2] | (root["data"][3] << 8)
    assert a == b == records[1]["ID"]
    assert _int_payload(records[1]["data"]) == 42


def test_save_nested_list(hd):
    """A list-of-lists walks transitively: outer + inner + leaf ints, all
    distinct records."""
    records = _save_and_parse(hd, 'SAVE("FILE", [[1, 2], [3]])')
    # Records: outer list, inner1, inner2, int 1, int 2, int 3 → 6 records.
    assert len(records) == 6
    types = [rec["TYPE"] for rec in records]
    assert types == [
        SS_TYPE_LIST,  # outer
        SS_TYPE_LIST,  # inner1
        SS_TYPE_LIST,  # inner2
        SS_TYPE_INT,
        SS_TYPE_INT,
        SS_TYPE_INT,
    ]


def test_save_tuple(hd):
    records = _save_and_parse(hd, 'SAVE("FILE", (10, 20))')
    assert len(records) == 3
    assert records[0]["TYPE"] == SS_TYPE_TUPLE
    assert records[0]["size"] == 4
    assert [_int_payload(rec["data"]) for rec in records[1:]] == [10, 20]


def test_save_terminator_present(hd):
    """The serialized stream MUST end with a 0x0000 ID terminator so the
    deserializer knows when to stop."""
    _eval_no_result(hd, 'SAVE("FILE", 1)')
    blob = hd.kernal_mock.files[b"FILE"]
    # Last 2 bytes should be 0x00 0x00 (terminator).
    assert blob[-2:] == b"\x00\x00"


def test_save_overwrites_existing(hd):
    """@0:NAME,S,W replaces the file rather than erroring 63 FILE EXISTS.
    Verify by length: a 50-byte garbage file should shrink to a single int
    record + terminator."""
    hd.kernal_mock.files[b"FILE"] = b"\xAA" * 50
    _eval_no_result(hd, 'SAVE("FILE", 42)')
    blob = hd.kernal_mock.files[b"FILE"]
    assert len(blob) < 50
    records = parse_stream(blob)
    assert len(records) == 1
    assert _int_payload(records[0]["data"]) == 42


def test_save_non_string_name_raises_type_err(hd):
    _eval_panics_with(hd, "SAVE(42, 1)", ERR_TYPE)


def test_save_empty_name_raises_type_err(hd):
    _eval_panics_with(hd, 'SAVE("", 1)', ERR_TYPE)


def test_save_oversized_name_raises_type_err(hd):
    _eval_panics_with(hd, 'SAVE("0123456789ABC", 1)', ERR_TYPE)


# ---------------------------------------------------------------------------
# Phase 4 — load() deserializer: round-trip via parser_eval.
# ---------------------------------------------------------------------------


def _eval(h, source: str) -> int:
    """Evaluate Admiral source, return RV decoded as int."""
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8A00, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    return _read_int(h, h.read_word(RV))


def _read_str_payload(h, handle_addr: int) -> bytes:
    obj = h.read_word(handle_addr + H_PTR)
    length = h.read_word(obj + O_LEN)
    return bytes(h.read_bytes(obj + O_HEADER, length))


def _eval_str(h, source: str) -> bytes:
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8A00, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    return _read_str_payload(h, h.read_word(RV))


def _eval_handle(h, source: str) -> int:
    payload = list(source.encode("ascii"))
    handle = place_str(h, 0x8A00, payload)
    h.rs_push(handle)
    h.call("parser_eval", max_steps=2_000_000)
    return h.read_word(RV)


def test_load_round_trip_int(hd):
    """save 42 to disk, load it back, expect 42."""
    assert _eval(hd, 'SAVE("F", 42)\nLOAD("F")') == 42


def test_load_round_trip_negative_int(hd):
    """Negative ints round-trip: 2's complement bytes preserved."""
    assert _eval(hd, 'SAVE("F", -7)\nLOAD("F")') == -7


def test_load_round_trip_string(hd):
    assert _eval_str(hd, 'SAVE("F", "hello")\nLOAD("F")') == b"hello"


def test_load_round_trip_empty_string(hd):
    assert _eval_str(hd, 'SAVE("F", "")\nLOAD("F")') == b""


def test_load_round_trip_string_with_escape(hd):
    """Regression: strings containing escape sequences used to gain a trailing
    NUL on SAVE/LOAD. The lexer over-allocates STR literals to the source
    span size (counting `\\n` as 2 source bytes) and patches O_LEN down to
    the post-decode count; SAVE was streaming H_SIZE - O_HEADER bytes (the
    allocated size) instead of O_LEN, dragging the slack byte into the
    saved record."""
    # `\\n` is one backslash + n in the Admiral source we feed in — the
    # lexer decodes that to a LF byte ($0A). The outer `\n` (no raw r prefix)
    # is a real LF separating two Admiral statements.
    assert _eval_str(hd, 'SAVE("F", "a\\nb")\nLOAD("F")') == b"a\nb"
    assert _eval_str(hd, 'SAVE("F", "x\\n\\n\\\\")\nLOAD("F")') == b"x\n\n\\"


def test_load_round_trip_bool(hd):
    """True/False round-trip as TYPE_BOOL with the right payload byte."""
    h_true = _eval_handle(hd, 'SAVE("F", TRUE)\nLOAD("F")')
    assert hd.mpu.memory[h_true + H_TYPE] == 0x22  # TYPE_BOOL
    obj = hd.read_word(h_true + H_PTR)
    # Bool payload is a single byte: 1 = True, 0 = False.
    assert hd.mpu.memory[obj + O_HEADER] == 1

    h_false = _eval_handle(hd, 'SAVE("F", FALSE)\nLOAD("F")')
    assert hd.mpu.memory[h_false + H_TYPE] == 0x22
    obj = hd.read_word(h_false + H_PTR)
    assert hd.mpu.memory[obj + O_HEADER] == 0


def test_load_round_trip_none(hd):
    """None as the root: after load, identity must equal the global NONE."""
    handle = _eval_handle(hd, 'SAVE("F", NONE)\nLOAD("F")')
    # Verify it's TYPE_NONE.
    assert hd.mpu.memory[handle + H_TYPE] == 0x23  # TYPE_NONE


def test_load_round_trip_list_of_ints(hd):
    """Round-trip a flat list, verify length and elements."""
    src = 'SAVE("F", [10, 20, 30])\nx = LOAD("F")\nx[0] + x[1] + x[2]'
    assert _eval(hd, src) == 60


def test_load_preserves_list_length(hd):
    src = 'SAVE("F", [1, 2, 3, 4, 5])\nLEN(LOAD("F"))'
    assert _eval(hd, src) == 5


def test_load_round_trip_empty_list(hd):
    src = 'SAVE("F", [])\nLEN(LOAD("F"))'
    assert _eval(hd, src) == 0


def test_load_round_trip_tuple(hd):
    """Tuples re-materialize as tuples; verify len + element access."""
    src = 'SAVE("F", (7, 8))\nx = LOAD("F")\nx[0] + x[1]'
    assert _eval(hd, src) == 15


def test_load_round_trip_nested_list(hd):
    """Deserialize transitively rebuilds nested containers."""
    src = 'SAVE("F", [[1, 2], [3, 4, 5]])\nx = LOAD("F")\nx[0][1] + x[1][2]'
    assert _eval(hd, src) == 7  # 2 + 5


def test_load_shared_subobject_identity(hd):
    """The defining property of the (de)serializer pair: when the same handle
    appears twice in the source graph, save+load reproduces a graph where
    the two slots STILL reference the same handle. Tested via mutation:
    after load, mutating slot[0] is visible through slot[1] iff the two
    refer to the same object.

    NOTE: Admiral lists are shallow-cloneable; re-saving an `[x, x]` shape
    with our serializer's dedup is what makes this work."""
    src = (
        'a = [1]\n'
        'SAVE("F", [a, a])\n'
        'b = LOAD("F")\n'
        'b[0].APPEND(99)\n'
        'LEN(b[1])'
    )
    # If b[0] and b[1] are the same handle, b[1] also has 2 elements after
    # the append. If they're independent copies, b[1] still has 1.
    assert _eval(hd, src) == 2


def test_load_missing_file_raises_disk_err(hd):
    _eval_panics_with(hd, 'LOAD("MISSING")', ERR_DISK)


def test_load_non_string_name_raises_type_err(hd):
    _eval_panics_with(hd, "LOAD(42)", ERR_TYPE)


def test_load_empty_name_raises_type_err(hd):
    _eval_panics_with(hd, 'LOAD("")', ERR_TYPE)


def test_load_oversized_name_raises_type_err(hd):
    _eval_panics_with(hd, 'LOAD("0123456789ABC")', ERR_TYPE)


def test_rm_max_length_name_works(hd):
    """12-character names are at the boundary and should work."""
    name = b"A" * 12
    hd.kernal_mock.add_file(name, b"x")
    _eval_no_result(hd, 'RM("AAAAAAAAAAAA")')
    assert name not in hd.kernal_mock.files


# ---------------------------------------------------------------------------
# Phase 5 — dir() listing.
# ---------------------------------------------------------------------------


def test_dir_empty_disk_returns_empty_dict(hd):
    handle = _eval_handle(hd, "DIR()")
    assert hd.mpu.memory[handle + H_TYPE] == 0x26  # TYPE_DICT
    obj = hd.read_word(handle + H_PTR)
    assert hd.read_word(obj + O_LEN) == 0


def test_dir_returns_one_entry_per_file(hd):
    hd.kernal_mock.add_file(b"FOO", b"x" * 10)
    hd.kernal_mock.add_file(b"BAR", b"y" * 300)  # 2 blocks
    assert _eval(hd, 'DIR()\nLEN(DIR())') == 2


def test_dir_block_count_is_int(hd):
    """A 300-byte file occupies ceil(300/254)=2 blocks (CBM math)."""
    hd.kernal_mock.add_file(b"BIG", b"y" * 300)
    assert _eval(hd, 'DIR()["BIG"]') == 2


def test_dir_small_file_one_block(hd):
    hd.kernal_mock.add_file(b"TINY", b"x")
    assert _eval(hd, 'DIR()["TINY"]') == 1


def test_dir_skips_disk_header_line(hd):
    """The `0 "DISK NAME" 01 2A` header is not a file — len() of dir()
    on a brand-new (formatted-but-empty) disk is 0, not 1."""
    hd.kernal_mock.disk_name = b"ADMIRAL"
    assert _eval(hd, 'LEN(DIR())') == 0


def test_dir_after_save_includes_saved_file(hd):
    """End-to-end: save a value, dir() must list the file we wrote."""
    src = (
        'SAVE("THING", [1, 2, 3])\n'
        'd = DIR()\n'
        'LEN(d)'
    )
    assert _eval(hd, src) == 1


def test_dir_does_not_corrupt_existing_data(hd):
    """dir() must not touch other files; load round-trip still works after."""
    src = (
        'SAVE("DATA", 42)\n'
        'DIR()\n'
        'LOAD("DATA")'
    )
    assert _eval(hd, src) == 42


# ---------------------------------------------------------------------------
# Phase 6 — error_handler closes leaked channels.
# ---------------------------------------------------------------------------


def test_error_handler_closes_data_lfn_after_panic(hd):
    """Trigger a panic with lfn 2 open; verify the mock no longer has it
    in `_channels` afterward — proof error_handler ran disk_close_data."""
    # Set up minimal REPL recovery snapshot so error_handler can run.
    hd.call("screen_init")
    hd.call("dict_alloc")
    scope = hd.read_word(RV)
    hd.write_word(0x42, scope)           # CURRENT_SCOPE
    hd.write_word(0x44, scope)           # ROOT_SCOPE
    hd.rs_push(scope)
    hd.mpu.memory[hd.sym["repl_rec_s"]] = hd.mpu.sp
    hd.write_word(hd.sym["repl_rec_rsp"], hd.read_word(0x04))
    hd.write_word(hd.sym["repl_rec_fsp"], hd.read_word(0x02))
    hd.write_word(hd.sym["repl_rec_fp"],  hd.read_word(0x06))

    # Open lfn 2 ourselves (simulating a load/save mid-op leak).
    hd.kernal_mock.add_file(b"X", b"x")
    _stage_name(hd, b"X")
    hd.call("disk_open_seq_r")
    assert 2 in hd.kernal_mock._channels, "precondition: lfn 2 IS open"

    # Trigger a panic by storing an error code and jumping to error_handler.
    hd.mpu.memory[ERROR_CODE_ZP] = ERR_DISK
    hd.mpu.pc = hd.sym["error_handler"]
    repl_loop = hd.sym["repl_loop"]
    for _ in range(200_000):
        if hd.mpu.pc == repl_loop:
            break
        if hd.kernal_mock.step_hook():
            continue
        hd.mpu.step()
    else:
        raise TimeoutError("error_handler did NOT reach repl_loop")

    assert 2 not in hd.kernal_mock._channels, (
        "error_handler should have closed lfn 2"
    )
    assert 15 not in hd.kernal_mock._channels, (
        "error_handler should have closed lfn 15"
    )


def test_eof_set_on_last_byte(hd):
    """The byte that triggers EOF is the LAST valid data byte — C=1 on
    that read, not on the next one. Matches CBM convention so a standard
    `jsr CHRIN; bcs done; sta buf,x; inx; bne loop` works."""
    hd.kernal_mock.files[b"ONE"] = b"X"
    _stage_name(hd, b"ONE")
    hd.call("disk_open_seq_r")
    hd.call("disk_byte_r")
    assert hd.mpu.a == ord("X")
    assert hd.mpu.p & 0x01, "expected EOF on the read that delivers the last byte"
    hd.call("disk_close_data")
