"""Shared test harness: assemble sources, load .prg into py65, parse symbols."""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest
from py65.devices.mpu6502 import MPU

C64_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = C64_ROOT / "src"
BUILD_DIR = C64_ROOT / "build"
KICKASS_JAR = Path.home() / "bin" / "KickAssembler" / "KickAss.jar"

TOP = "admiral"

_VICE_LABEL_RE = re.compile(r"al\s+C:([0-9a-fA-F]+)\s+\.?(\S+)")


def _assemble() -> tuple[Path, Path]:
    """Assemble src/admiral.asm, producing build/admiral.prg + .vs."""
    BUILD_DIR.mkdir(exist_ok=True)
    asm_path = SRC_DIR / f"{TOP}.asm"
    result = subprocess.run(
        [
            "java", "-jar", str(KICKASS_JAR),
            "-odir", str(BUILD_DIR),
            "-vicesymbols",
            str(asm_path),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"KickAssembler failed:\n{result.stdout}\n{result.stderr}"
        )
    prg = BUILD_DIR / f"{TOP}.prg"
    vs = BUILD_DIR / f"{TOP}.vs"
    if not prg.exists():
        raise RuntimeError(f"{prg} was not produced")
    return prg, vs


def _load_prg(mpu: MPU, prg_path: Path) -> int:
    """Load a .prg at its embedded load address. Returns that address."""
    data = prg_path.read_bytes()
    load_addr = data[0] | (data[1] << 8)
    for offset, byte in enumerate(data[2:]):
        mpu.memory[load_addr + offset] = byte
    return load_addr


def _load_symbols(vs_path: Path) -> dict[str, int]:
    """Parse a KickAssembler -vicesymbols file into {label: address}."""
    syms: dict[str, int] = {}
    for raw in vs_path.read_text().splitlines():
        m = _VICE_LABEL_RE.match(raw.strip())
        if m:
            syms[m.group(2)] = int(m.group(1), 16)
    return syms


# ZP addresses (must stay in sync with src/defs.asm).
FSP_ZP = 0x02  # frame stack pointer (top of FS)
RSP_ZP = 0x04  # root stack pointer (top of RS)
FP_ZP = 0x06   # frame base pointer (stable within a routine)
RV = 0x0E      # volatile 16-bit return register
W0 = 0x10
W1 = 0x12
W2 = 0x14
W3 = 0x16
B0 = 0x18
B1 = 0x19
B2 = 0x1A
B3 = 0x1B
B4 = 0x1C
B5 = 0x1D
B6 = 0x1E
B7 = 0x1F

# Allocator ZP state (must stay in sync with src/defs.asm).
NEXT_HANDLE_ZP = 0x20
NEXT_DATA_ZP = 0x22
ALLOC_SIZE_ZP = 0x24   # word
ALLOC_TYPE_ZP = 0x26
ERROR_CODE_ZP = 0x27
FREE_HEAD_ZP = 0x28    # word
RESERVED_HEAD_ZP = 0x2B  # word
RESERVED_TAIL_ZP = 0x2D  # word

# Panic error codes (src/defs.asm).
ERR_OOM = 0x01

TYPE_INT = 0x20
TYPE_STR = 0x21
TYPE_BOOL = 0x22
TYPE_NONE = 0x23
TYPE_TUPLE = 0x24
TYPE_LIST = 0x25
TYPE_DICT = 0x26
TYPE_FLOAT = 0x27
TYPE_REF = 0x2A
TYPE_SUB = 0x2B

ERR_TYPE = 0x05
ERR_ARITY = 0x06

# Heap region bounds (must stay in sync with src/defs.asm).
HEAP_DATA_START = 0x8800
HEAP_HANDLE_START = 0xFFF8

# C64 BASIC ROM image (8 KB, mapped at $A000-$BFFF when bit 0 of $01 is set).
# Located in the local VICE installation. Tests that exercise float arithmetic
# need this loaded into py65 memory so JSRs into BASIC FP routines find code.
BASIC_ROM_PATH = Path(
    "/Applications/vice-arm64-gtk3-3.9/VICE.app/Contents/Resources/"
    "share/vice/C64/basic-901226-01.bin"
)
BASIC_ROM_START = 0xA000
BASIC_ROM_END = 0xC000  # exclusive

# C64 KERNAL ROM image (8 KB, mapped at $E000-$FFFF when bit 1 of $01 is set).
# Required for FP routines that call into BASIC's polynomial helpers (POLY1
# at $E043, POLYX at $E059) — used by FPWRT/EXP/LOG/SIN/COS/etc.
KERNAL_ROM_PATH = Path(
    "/Applications/vice-arm64-gtk3-3.9/VICE.app/Contents/Resources/"
    "share/vice/C64/kernal-901227-03.bin"
)
KERNAL_ROM_START = 0xE000
KERNAL_ROM_END = 0x10000  # exclusive

# FAC zero-page bases (must stay in sync with src/defs.asm).
FAC1 = 0x61
FAC2 = 0x69


def load_basic_rom(mpu: MPU) -> None:
    """Load the C64 BASIC ROM bytes into py65 memory at $A000-$BFFF.

    py65 doesn't emulate the C64 PLA banking, so $0001's value has no effect
    in tests; the ROM bytes are simply visible at all times. Real-hardware
    code that brackets BASIC calls with `lda #$37; sta $01` works the same
    way in py65 (the writes to $01 are no-ops here).
    """
    if not BASIC_ROM_PATH.exists():
        raise RuntimeError(
            f"BASIC ROM not found at {BASIC_ROM_PATH}. Float tests require "
            "the C64 BASIC ROM from a VICE installation."
        )
    rom = BASIC_ROM_PATH.read_bytes()
    expected = BASIC_ROM_END - BASIC_ROM_START
    if len(rom) != expected:
        raise RuntimeError(
            f"{BASIC_ROM_PATH} is {len(rom)} bytes; expected {expected}"
        )
    for i, b in enumerate(rom):
        mpu.memory[BASIC_ROM_START + i] = b

    # CHRGET ($0073..$008A) — BASIC interpreter's character-fetch routine.
    # On real hardware, KERNAL cold-boot copies CHRGET into ZP. py65 skips
    # that, so str_to_float (which calls FIN, which uses CHRGET) needs the
    # routine installed manually. The instruction at $0079 is `LDA $0000`
    # whose 16-bit operand IS TXTPTR ($7A-$7B); writes to $7A/$7B patch
    # this LDA at runtime. Standard 24-byte sequence (any C64 ROM ref).
    chrget = bytes([
        0xE6, 0x7A,            # INC $7A
        0xD0, 0x02,            # BNE +2
        0xE6, 0x7B,            # INC $7B
        0xAD, 0x00, 0x00,      # LDA $0000 (operand patched via $7A/$7B)
        0xC9, 0x3A,            # CMP #':'
        0xB0, 0x0A,            # BCS +10
        0xC9, 0x20,            # CMP #' '
        0xF0, 0xEF,            # BEQ -17 (skip space, loop)
        0x38,                  # SEC
        0xE9, 0x30,            # SBC #'0'
        0x38,                  # SEC
        0xE9, 0xD0,            # SBC #$D0
        0x60,                  # RTS
    ])
    for i, b in enumerate(chrget):
        mpu.memory[0x0073 + i] = b


def load_kernal_rom(mpu: MPU) -> None:
    """Load the C64 KERNAL ROM bytes at $E000-$FFFF.

    BASIC's transcendental routines (used by FPWRT/EXP/LOG and friends) JSR
    into POLY1 ($E043) / POLYX ($E059) which physically live in KERNAL ROM.
    Tests that exercise `**`, `%`, or `//` on floats must have KERNAL bytes
    present here, otherwise execution falls into uninitialized RAM.
    """
    if not KERNAL_ROM_PATH.exists():
        raise RuntimeError(
            f"KERNAL ROM not found at {KERNAL_ROM_PATH}. Tests that hit "
            "BASIC FP polynomial helpers require it from a VICE install."
        )
    rom = KERNAL_ROM_PATH.read_bytes()
    expected = KERNAL_ROM_END - KERNAL_ROM_START
    if len(rom) != expected:
        raise RuntimeError(
            f"{KERNAL_ROM_PATH} is {len(rom)} bytes; expected {expected}"
        )
    for i, b in enumerate(rom):
        mpu.memory[KERNAL_ROM_START + i] = b


# --- MS-Basic packed-float <-> Python float -----------------------------------
# Test helpers, not used by the running 6502 code. The packed format is what
# we store in TYPE_FLOAT heap objects (5 bytes).

def python_to_msbasic(x: float) -> bytes:
    """Convert a Python float to its MS-Basic 5-byte packed representation.

    Raises ValueError if the value is out of representable range.
    """
    import math

    if x == 0.0:
        return bytes(5)

    sign_bit = 0x80 if x < 0 else 0x00
    x = abs(x)

    exp = math.floor(math.log2(x))
    mantissa = x / (2.0 ** exp)
    # Handle the edge case where rounding of log2 produces mantissa = 2.0.
    if mantissa >= 2.0:
        mantissa /= 2.0
        exp += 1
    elif mantissa < 1.0:
        mantissa *= 2.0
        exp -= 1

    biased_exp = 129 + exp
    if not (1 <= biased_exp <= 255):
        raise ValueError(f"value {x} biased exponent {biased_exp} out of range")

    # 31-bit fraction (we drop the implicit leading 1).
    frac = mantissa - 1.0
    mantissa_int = int(round(frac * (1 << 31)))
    if mantissa_int >= (1 << 31):
        # Rounded up into the next exponent.
        mantissa_int = 0
        biased_exp += 1
        if biased_exp > 255:
            raise ValueError(f"value {x} overflows after rounding")

    byte1 = ((mantissa_int >> 24) & 0x7F) | sign_bit
    byte2 = (mantissa_int >> 16) & 0xFF
    byte3 = (mantissa_int >> 8) & 0xFF
    byte4 = mantissa_int & 0xFF
    return bytes([biased_exp, byte1, byte2, byte3, byte4])


def msbasic_to_python(b: bytes | list[int]) -> float:
    """Convert 5 packed bytes to a Python float."""
    if len(b) != 5:
        raise ValueError(f"expected 5 bytes, got {len(b)}")
    if b[0] == 0:
        return 0.0
    sign = -1.0 if b[1] & 0x80 else 1.0
    mantissa_int = ((b[1] & 0x7F) << 24) | (b[2] << 16) | (b[3] << 8) | b[4]
    mantissa = 1.0 + mantissa_int / (1 << 31)
    exp = b[0] - 129
    return sign * mantissa * (2.0 ** exp)


# --- Virtual 1541 / KERNAL disk mock -----------------------------------------
# py65 has no IEC bus emulation, and our running code banks KERNAL out
# anyway ($01=$34 steady state). Disk-touching tests need a mock that
# intercepts the KERNAL routines disk.asm uses, simulates a tiny 1541, and
# RTSes back to the caller — without ever executing real KERNAL bytes.
#
# Behaviour summary:
#   - SETLFS / SETNAM stash params (mirrors real KERNAL writing to $B7-$BC)
#   - OPEN parses the SETNAM string, wires up a per-LFN channel:
#       sec=15  → command/error channel
#       name=$  → directory channel (synthesizes BASIC-program format)
#       else    → SEQ read or write depending on `,S,R` / `,S,W` modifier
#   - CHRIN/CHROUT route through the active LFN (or default kbd/screen)
#   - CLOSE finalizes a write (commits buffer to self.files)
#   - READST returns the ST byte at zp $90 (we keep it in sync)
#
# Filenames are stored as PETSCII bytes; the mock doesn't case-fold or
# translate. The DOS-status string format mirrors real CBM error replies.


class _ReadChan:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.pos = 0

    def read_byte(self) -> tuple[int, bool]:
        if self.pos >= len(self.data):
            return 0, True
        b = self.data[self.pos]
        self.pos += 1
        return b, self.pos >= len(self.data)


class _WriteChan:
    def __init__(self, mock: "KernalDiskMock", name: bytes) -> None:
        self.mock = mock
        self.name = name
        self.buf = bytearray()

    def write_byte(self, b: int) -> None:
        self.buf.append(b)

    def close(self) -> None:
        self.mock.files[self.name] = bytes(self.buf)


class _CmdChan:
    def __init__(self, mock: "KernalDiskMock") -> None:
        self.mock = mock
        self.cmd_buf = bytearray()
        self._reply: bytes | None = None
        self._reply_pos = 0

    def write_byte(self, b: int) -> None:
        # CR ($0D) terminates a command; flush and execute now so subsequent
        # writes start a fresh command (matches real DOS behaviour).
        if b == 0x0D:
            if self.cmd_buf:
                self.mock.execute_dos_command(bytes(self.cmd_buf))
                self.cmd_buf = bytearray()
            return
        self.cmd_buf.append(b)

    def read_byte(self) -> tuple[int, bool]:
        if self._reply is None:
            c, m, t, s = self.mock.last_dos_error
            self._reply = (
                f"{c:02d},{m.decode('ascii')},{t:02d},{s:02d}\r"
            ).encode("ascii")
            self._reply_pos = 0
        if self._reply_pos >= len(self._reply):
            return 0, True
        b = self._reply[self._reply_pos]
        self._reply_pos += 1
        return b, self._reply_pos >= len(self._reply)

    def close(self) -> None:
        if self.cmd_buf:
            self.mock.execute_dos_command(bytes(self.cmd_buf))
            self.cmd_buf = bytearray()


class _DirChan:
    """Synthesizes the BASIC-program format `LOAD "$",8` returns.

    Stream layout (per CBM DOS):
        $0401 little-endian load address (2 bytes)
        per line:
            link_lo link_hi   ; 2 bytes; final 00 00 = end of program
            line#_lo line#_hi ; 2 bytes; for files = blocks-used count
            tokens / chars    ; ASCII content of the line
            00                ; line terminator
        00 00                 ; final program terminator (the link of the
                              ; last line is already 00 00)

    Our streaming parser only cares about quoted filename + line-number =
    block count, so we keep formatting loose: we don't bother computing
    real BASIC links or matching the exact column padding. Tests assert
    extracted (name, blocks) only.
    """

    def __init__(self, mock: "KernalDiskMock") -> None:
        self.data = self._build(mock)
        self.pos = 0

    def _build(self, mock: "KernalDiskMock") -> bytes:
        out = bytearray()
        out += b"\x01\x04"  # load address $0401

        # Header line: line# = 0, contents = "<diskname>" "<id> 2A"
        out += self._line(0, b'"' + mock.disk_name + b'" ' + mock.disk_id + b" 2A")

        # File lines: line# = blocks (size in disk blocks of 254 useful bytes)
        for name, contents in mock.files.items():
            blocks = (len(contents) + 253) // 254
            out += self._line(blocks, b'"' + name + b'" PRG')

        # End-of-program marker
        out += b"\x00\x00"
        return bytes(out)

    @staticmethod
    def _line(line_no: int, content: bytes) -> bytes:
        # Use a dummy non-zero link so the parser sees "more lines coming"
        # until our final 00 00 terminator. Exact value doesn't matter.
        link = 0x0101
        return (
            bytes([link & 0xFF, (link >> 8) & 0xFF])
            + bytes([line_no & 0xFF, (line_no >> 8) & 0xFF])
            + content
            + b"\x00"
        )

    def read_byte(self) -> tuple[int, bool]:
        if self.pos >= len(self.data):
            return 0, True
        b = self.data[self.pos]
        self.pos += 1
        return b, self.pos >= len(self.data)


class KernalDiskMock:
    """Hooks KERNAL disk routines in py65 to simulate a virtual 1541.

    Trapped routines (listed by jump-table address):
      $FFB7 READST, $FFBA SETLFS, $FFBD SETNAM,
      $FFC0 OPEN,   $FFC3 CLOSE,
      $FFC6 CHKIN,  $FFC9 CHKOUT, $FFCC CLRCHN,
      $FFCF CHRIN,  $FFD2 CHROUT.

    Inspectable state:
      .files: dict[bytes, bytes]  filename → contents
      .formatted: bool            set by N0: command
      .disk_name, .disk_id: bytes set by format
      .last_dos_error: tuple      (code, msg, track, sector)
    """

    READST = 0xFFB7
    SETLFS = 0xFFBA
    SETNAM = 0xFFBD
    OPEN = 0xFFC0
    CLOSE = 0xFFC3
    CHKIN = 0xFFC6
    CHKOUT = 0xFFC9
    CLRCHN = 0xFFCC
    CHRIN = 0xFFCF
    CHROUT = 0xFFD2

    TRAPS = frozenset(
        {READST, SETLFS, SETNAM, OPEN, CLOSE, CHKIN, CHKOUT, CLRCHN, CHRIN, CHROUT}
    )

    def __init__(self, mpu: MPU) -> None:
        self.mpu = mpu
        self.files: dict[bytes, bytes] = {}
        self.formatted = False
        self.disk_name = b"ADMIRAL"
        self.disk_id = b"01"
        # SETLFS/SETNAM staging (mirror of $B8 / $BA / $B9 / $B7 / $BB / $BC)
        self._setlfs_lfn = 0
        self._setlfs_dev = 8
        self._setlfs_sec = 0
        self._setnam_len = 0
        self._setnam_ptr = 0
        # Per-LFN channels
        self._channels: dict[int, _ReadChan | _WriteChan | _CmdChan | _DirChan] = {}
        # Active input/output LFN. 0 = default (kbd/screen — we discard).
        self._in_lfn = 0
        self._out_lfn = 0
        # Last DOS error (code, message, track, sector)
        self.last_dos_error: tuple[int, bytes, int, int] = (73, b"CBM DOS V2.6 1541", 0, 0)

    # --- public API used by tests ------------------------------------------

    def add_file(self, name: bytes, contents: bytes) -> None:
        """Pre-populate a file (e.g. for load-this-existing-file tests)."""
        self.files[name] = contents

    def execute_dos_command(self, cmd: bytes) -> None:
        """Parse + execute a DOS command (called from cmd-channel close/CR)."""
        # Strip optional trailing CR for parser robustness.
        if cmd.endswith(b"\r"):
            cmd = cmd[:-1]
        # N0:NAME,ID  — format
        if cmd.startswith(b"N0:") or cmd.startswith(b"N:"):
            payload = cmd.split(b":", 1)[1]
            if b"," in payload:
                name, did = payload.split(b",", 1)
            else:
                name, did = payload, b"01"
            self.disk_name = name
            self.disk_id = did
            self.files.clear()
            self.formatted = True
            self.last_dos_error = (0, b"OK", 0, 0)
            return
        # S:NAME or S0:NAME — scratch (delete)
        if cmd.startswith(b"S:") or cmd.startswith(b"S0:"):
            target = cmd.split(b":", 1)[1]
            n = 0
            if target in self.files:
                del self.files[target]
                n = 1
            self.last_dos_error = (1, b"FILES SCRATCHED", n, 0) if n else (62, b"FILE NOT FOUND", 0, 0)
            return
        # Anything else: ignore but flag as unknown command
        self.last_dos_error = (31, b"SYNTAX ERROR", 0, 0)

    # --- step hook ---------------------------------------------------------

    def step_hook(self) -> bool:
        """If PC is at a trapped address, simulate the routine and RTS.

        Returns True if a trap fired (caller should NOT also step the MPU).
        """
        pc = self.mpu.pc
        if pc not in self.TRAPS:
            return False
        if pc == self.SETLFS:
            self._do_setlfs()
        elif pc == self.SETNAM:
            self._do_setnam()
        elif pc == self.OPEN:
            self._do_open()
        elif pc == self.CLOSE:
            self._do_close()
        elif pc == self.CHKIN:
            self._do_chkin()
        elif pc == self.CHKOUT:
            self._do_chkout()
        elif pc == self.CLRCHN:
            self._do_clrchn()
        elif pc == self.CHRIN:
            self._do_chrin()
        elif pc == self.CHROUT:
            self._do_chrout()
        elif pc == self.READST:
            self._do_readst()
        self._simulate_rts()
        return True

    # --- KERNAL routine simulators -----------------------------------------

    def _do_setlfs(self) -> None:
        # A=lfn, X=dev, Y=sec
        self._setlfs_lfn = self.mpu.a
        self._setlfs_dev = self.mpu.x
        self._setlfs_sec = self.mpu.y

    def _do_setnam(self) -> None:
        # A=length, X=name_lo, Y=name_hi
        self._setnam_len = self.mpu.a
        self._setnam_ptr = self.mpu.x | (self.mpu.y << 8)

    def _do_open(self) -> None:
        if self._setlfs_dev != 8:
            # Device-not-present: C=1, A=$05.
            self.mpu.a = 0x05
            self.mpu.p |= 0x01  # set C
            return
        name = bytes(
            self.mpu.memory[(self._setnam_ptr + i) & 0xFFFF]
            for i in range(self._setnam_len)
        )
        lfn = self._setlfs_lfn
        sec = self._setlfs_sec
        if sec == 15:
            ch: _ReadChan | _WriteChan | _CmdChan | _DirChan = _CmdChan(self)
            self._channels[lfn] = ch
            if name:
                # Open with an inline command: execute it now.
                self.execute_dos_command(name)
        elif name == b"$":
            self._channels[lfn] = _DirChan(self)
            # Real DOS clears the error channel after a successful $ open.
            self.last_dos_error = (0, b"OK", 0, 0)
        else:
            self._open_file(lfn, name)
        self.mpu.p &= ~0x01  # clear C — no OPEN-level error

    def _open_file(self, lfn: int, name: bytes) -> None:
        # Strip optional `@0:` overwrite prefix and parse `NAME,T,M`.
        replace = False
        body = name
        if body.startswith(b"@"):
            replace = True
            body = body.lstrip(b"@")
            if body.startswith(b"0:"):
                body = body[2:]
        elif body.startswith(b"0:"):
            body = body[2:]
        parts = body.split(b",")
        fname = parts[0]
        mode = parts[2] if len(parts) >= 3 else b"R"
        if mode == b"W":
            if not replace and fname in self.files:
                self.last_dos_error = (63, b"FILE EXISTS", 0, 0)
                # Real DOS still opens the channel; the error appears on
                # ch15. Mirror that — installing a write channel that will
                # silently overwrite is wrong, so install a sink-channel
                # whose close() is a no-op.
                self._channels[lfn] = _WriteChan(_NullDict(), fname)
                return
            self._channels[lfn] = _WriteChan(self, fname)
            self.last_dos_error = (0, b"OK", 0, 0)
        else:  # default to read
            if fname not in self.files:
                self.last_dos_error = (62, b"FILE NOT FOUND", 0, 0)
                self._channels[lfn] = _ReadChan(b"")
                return
            self._channels[lfn] = _ReadChan(self.files[fname])
            self.last_dos_error = (0, b"OK", 0, 0)

    def _do_close(self) -> None:
        # A=lfn
        lfn = self.mpu.a
        ch = self._channels.pop(lfn, None)
        if ch is not None and hasattr(ch, "close"):
            ch.close()
        if self._in_lfn == lfn:
            self._in_lfn = 0
        if self._out_lfn == lfn:
            self._out_lfn = 0

    def _do_chkin(self) -> None:
        # X=lfn
        lfn = self.mpu.x
        if lfn in self._channels:
            self._in_lfn = lfn
            self.mpu.p &= ~0x01
        else:
            self.mpu.a = 0x03  # FILE NOT OPEN
            self.mpu.p |= 0x01

    def _do_chkout(self) -> None:
        lfn = self.mpu.x
        if lfn in self._channels:
            self._out_lfn = lfn
            self.mpu.p &= ~0x01
        else:
            self.mpu.a = 0x03
            self.mpu.p |= 0x01

    def _do_clrchn(self) -> None:
        self._in_lfn = 0
        self._out_lfn = 0

    def _do_chrin(self) -> None:
        if self._in_lfn == 0:
            # Default kbd: tests don't cover this path; return 0.
            self.mpu.a = 0
            self._set_st(0)
            return
        ch = self._channels.get(self._in_lfn)
        if ch is None:
            self.mpu.a = 0
            self._set_st(0x40)
            return
        b, eof = ch.read_byte()
        self.mpu.a = b & 0xFF
        self._set_st(0x40 if eof else 0)

    def _do_chrout(self) -> None:
        b = self.mpu.a
        if self._out_lfn == 0:
            return  # discard screen output
        ch = self._channels.get(self._out_lfn)
        if ch is None:
            return
        if hasattr(ch, "write_byte"):
            ch.write_byte(b)

    def _do_readst(self) -> None:
        # KERNAL READST simply returns the byte at $90.
        self.mpu.a = self.mpu.memory[0x0090]

    # --- helpers -----------------------------------------------------------

    def _set_st(self, st: int) -> None:
        self.mpu.memory[0x0090] = st & 0xFF

    def _simulate_rts(self) -> None:
        sp = (self.mpu.sp + 1) & 0xFF
        pcl = self.mpu.memory[0x0100 + sp]
        sp = (sp + 1) & 0xFF
        pch = self.mpu.memory[0x0100 + sp]
        self.mpu.sp = sp
        self.mpu.pc = (((pch << 8) | pcl) + 1) & 0xFFFF


class _NullDict:
    """Sink dict used when an OPEN-for-write fails (file-exists without @)."""
    def __setitem__(self, k, v): pass


@dataclass
class Harness:
    mpu: MPU
    sym: dict[str, int]
    kernal_mock: KernalDiskMock | None = None

    # --- memory helpers ---

    def read_word(self, addr: int) -> int:
        return self.mpu.memory[addr] | (self.mpu.memory[addr + 1] << 8)

    def write_word(self, addr: int, value: int) -> None:
        self.mpu.memory[addr] = value & 0xFF
        self.mpu.memory[addr + 1] = (value >> 8) & 0xFF

    def read_bytes(self, addr: int, length: int) -> list[int]:
        return [self.mpu.memory[addr + i] for i in range(length)]

    def write_bytes(self, addr: int, data: bytes | list[int]) -> None:
        for i, b in enumerate(data):
            self.mpu.memory[addr + i] = b & 0xFF

    # --- root stack helpers (Python-side, for test setup) ---

    @property
    def rsp(self) -> int:
        return self.read_word(RSP_ZP)

    @rsp.setter
    def rsp(self, value: int) -> None:
        self.write_word(RSP_ZP, value)

    def rs_push(self, value: int) -> None:
        self.rsp = (self.rsp - 2) & 0xFFFF
        self.write_word(self.rsp, value & 0xFFFF)

    def rs_pop(self) -> int:
        v = self.read_word(self.rsp)
        self.rsp = (self.rsp + 2) & 0xFFFF
        return v

    def rs_peek(self, offset: int = 0) -> int:
        """Read RS[top + offset words] without popping. offset=0 is top."""
        return self.read_word(self.rsp + offset * 2)

    # --- allocator helpers (Python-side, for test setup) ---

    def alloc(self, size: int, type_: int) -> int:
        """Preset ALLOC_SIZE/ALLOC_TYPE and call the allocator. Returns RV."""
        self.write_word(ALLOC_SIZE_ZP, size & 0xFFFF)
        self.mpu.memory[ALLOC_TYPE_ZP] = type_ & 0xFF
        self.call("alloc")
        return self.read_word(RV)

    def alloc_int(self, size: int) -> int:
        """Call alloc_int with the given payload size. Returns RV.

        NOTE: this allocates a *boxed* TYPE_INT (legacy shape). Real ints are
        inline now — use make_int(value) to create one holding a value.
        """
        self.write_word(ALLOC_SIZE_ZP, size & 0xFFFF)
        self.call("alloc_int")
        return self.read_word(RV)

    def make_int(self, value: int) -> int:
        """Allocate an inline TYPE_INT holding `value` (signed 32-bit). Returns RV."""
        value &= 0xFFFFFFFF
        self.write_word(W2, value & 0xFFFF)
        self.write_word(W3, (value >> 16) & 0xFFFF)
        self.call("alloc_inline_int")
        return self.read_word(RV)

    def alloc_str(self, size: int) -> int:
        """Call str_alloc with the given payload size. Returns RV."""
        self.write_word(ALLOC_SIZE_ZP, size & 0xFFFF)
        self.call("str_alloc")
        return self.read_word(RV)

    def alloc_tuple(self, count: int) -> int:
        """Call tuple_alloc with N=count (passed in A). Returns RV."""
        self.call("tuple_alloc", a=count)
        return self.read_word(RV)

    def alloc_list(self, count: int) -> int:
        """Call list_alloc with N=count (passed in A). Returns RV."""
        self.call("list_alloc", a=count)
        return self.read_word(RV)

    def alloc_dict(self) -> int:
        """Call dict_alloc — empty dict. Returns RV."""
        self.call("dict_alloc")
        return self.read_word(RV)

    def alloc_panics(self, size: int, type_: int, error_code: int) -> None:
        """Call alloc expecting a panic. Asserts ERROR_CODE matches."""
        self.write_word(ALLOC_SIZE_ZP, size & 0xFFFF)
        self.mpu.memory[ALLOC_TYPE_ZP] = type_ & 0xFF
        self.call("alloc", expect_panic=True)
        assert self.mpu.memory[ERROR_CODE_ZP] == error_code, (
            f"panicked with ERROR_CODE=${self.mpu.memory[ERROR_CODE_ZP]:02X}, "
            f"expected ${error_code:02X}"
        )

    def force_gap(self, gap: int) -> int:
        """Fill the heap via a single rooted int alloc, leaving exactly `gap`
        bytes between NEXT_DATA and NEXT_HANDLE.

        Unlike a raw NEXT_DATA poke, this keeps allocator state consistent so
        gc_compact preserves the gap (the live rooted handle can't be moved
        away). Use this when a test needs a genuinely unrecoverable tight heap.
        """
        full = HEAP_HANDLE_START - HEAP_DATA_START
        # After alloc: new gap = full - (payload + O_HEADER) - SIZEOF_HANDLE
        #                    = full - payload - 10.
        payload = full - 10 - gap
        if payload < 0:
            raise ValueError(
                f"gap={gap} exceeds max reachable ({full - 10} bytes)"
            )
        # Use a STR (boxed payload) rather than an int: inline ints carry no
        # heap payload and gc_compact skips them, so an int fill would be
        # "recoverable" and defeat the unrecoverable-gap intent.
        handle = self.alloc_str(payload)
        self.rs_push(handle)
        return handle

    # --- calling convention ---

    def call(self, label: str, *, a: int = 0, x: int = 0, y: int = 0,
             max_steps: int = 100_000, expect_panic: bool = False) -> None:
        """Invoke a routine by label. Sets A/X/Y before entry.

        Normal mode: return when the routine's RTS pops the sentinel return
        address (one byte past $FFFE). Raises if PC enters error_handler.

        expect_panic=True: return when PC enters error_handler. Raises if the
        routine returns normally instead.
        """
        sentinel = 0xFFFE
        self.mpu.memory[0x0100 + self.mpu.sp] = (sentinel >> 8) & 0xFF
        self.mpu.sp = (self.mpu.sp - 1) & 0xFF
        self.mpu.memory[0x0100 + self.mpu.sp] = sentinel & 0xFF
        self.mpu.sp = (self.mpu.sp - 1) & 0xFF

        self.mpu.a = a & 0xFF
        self.mpu.x = x & 0xFF
        self.mpu.y = y & 0xFF
        self.mpu.pc = self.sym[label]

        panic_pc = self.sym.get("error_handler", -1)

        for _ in range(max_steps):
            if self.mpu.pc == sentinel + 1:
                if expect_panic:
                    raise AssertionError(
                        f"{label}() returned normally; panic was expected"
                    )
                return
            if self.mpu.pc == panic_pc:
                if not expect_panic:
                    raise AssertionError(
                        f"{label}() panicked with ERROR_CODE="
                        f"${self.mpu.memory[ERROR_CODE_ZP]:02X}; normal "
                        f"return was expected"
                    )
                return
            if self.kernal_mock is not None and self.kernal_mock.step_hook():
                continue
            self.mpu.step()
        raise TimeoutError(
            f"{label}() did not return within {max_steps} steps "
            f"(pc=${self.mpu.pc:04X})"
        )


@pytest.fixture(scope="session")
def built():
    return _assemble()


@pytest.fixture
def h(built) -> Harness:
    """Fresh MPU per test, with the allocator and both software stacks reset."""
    prg, vs = built
    mpu = MPU()
    mpu.sp = 0xFF
    _load_prg(mpu, prg)
    syms = _load_symbols(vs)
    harness = Harness(mpu=mpu, sym=syms)
    harness.call("rs_init")
    harness.call("fs_init")
    harness.call("_heap_apply")  # sets HEAP_TOP from GFX_CONFIG (0 → $FFF8 text)
    harness.call("alloc_init")
    harness.call("rnd_init")
    return harness


@pytest.fixture
def hfp(built) -> Harness:
    """Like `h`, but with both the C64 BASIC ROM ($A000-$BFFF) and KERNAL ROM
    ($E000-$FFFF) loaded.

    Use this fixture for tests that JSR into BASIC FP routines (FADDT,
    FMULTT, GIVAYF, FOUT, FPWRT, INT, etc.). Some BASIC routines call into
    KERNAL ROM for polynomial helpers (POLY1 at $E043, POLYX at $E059), so
    KERNAL must be present too.

    The ROM bytes are mapped read/write in py65 — banking writes to $01 are
    no-ops in our emulator, so the ROMs are simply always visible.

    **Heap-vs-ROM collision** — on real hardware the heap handle table grows
    DOWN from $C000 into the area shadowed by BASIC ROM. With banking, our
    writes land in the RAM beneath the ROM and the ROM is unaffected. py65
    doesn't simulate banking, so a handle written at e.g. $BFF8 corrupts the
    ROM byte there. For tests, we move NEXT_HANDLE below BASIC ROM so the
    handle table never overlaps the loaded ROM image.
    """
    prg, vs = built
    mpu = MPU()
    mpu.sp = 0xFF
    _load_prg(mpu, prg)
    load_basic_rom(mpu)
    load_kernal_rom(mpu)
    syms = _load_symbols(vs)
    harness = Harness(mpu=mpu, sym=syms)
    harness.call("rs_init")
    harness.call("fs_init")
    harness.call("_heap_apply")  # sets HEAP_TOP from GFX_CONFIG (0 → $FFF8 text)
    harness.call("alloc_init")
    harness.call("rnd_init")
    # Move handle area below BASIC ROM so allocations don't trample ROM bytes
    # in the py65 image. NEXT_HANDLE = $A000 → first handle at $9FF8.
    harness.write_word(0x20, 0xA000)  # NEXT_HANDLE — must match defs.asm
    return harness


@pytest.fixture
def hd(built) -> Harness:
    """Like `h`, but with a virtual 1541 wired in as a KernalDiskMock.

    KERNAL ROM is NOT loaded — the mock traps PC entries to disk routines
    and simulates them in Python. Real disk.asm code that brackets KERNAL
    calls with `lda #$36; sta $01; jsr $FFD2; lda #$34; sta $01` works
    transparently: py65's writes to $01 are no-ops, the JSR to $FFD2 hits
    our trap, and the surrounding bank toggles do nothing observable.

    Inspect/seed the virtual disk via `harness.kernal_mock.files` and
    `harness.kernal_mock.add_file(name, contents)`.
    """
    prg, vs = built
    mpu = MPU()
    mpu.sp = 0xFF
    _load_prg(mpu, prg)
    syms = _load_symbols(vs)
    harness = Harness(mpu=mpu, sym=syms)
    harness.kernal_mock = KernalDiskMock(mpu)
    harness.call("rs_init")
    harness.call("fs_init")
    harness.call("_heap_apply")  # sets HEAP_TOP from GFX_CONFIG (0 → $FFF8 text)
    harness.call("alloc_init")
    harness.call("rnd_init")
    return harness


import os
import pathlib
import sys

ROOT = Path(__file__).resolve().parent.parent

# --- EDIT plugin support -----------------------------------------------------
# EDIT ships as a disk-loaded v2 TYPE_CODE plugin (plugins/edit.asm).
# Two session artifacts:
#   edit_plugin_record — the LOAD()-able TYPE_CODE record (interpreter tests)
#   edit_plugin_image  — (payload, syms) assembled at EDIT_IMAGE_BASE, for
#                        unit tests that drive edit_* routines by label.

EDIT_IMAGE_BASE = 0xE000


@pytest.fixture(scope="session")
def edit_plugin_record() -> bytes:
    out = ROOT / "build" / "plugin_edit.bin"
    r = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "build_plugin.py"),
         str(ROOT / "plugins" / "edit.asm"), str(out)],
        cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, f"build_plugin failed:\n{r.stdout}{r.stderr}"
    return out.read_bytes()


@pytest.fixture(scope="session")
def edit_plugin_image() -> tuple[bytes, dict[str, int]]:
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        out = pathlib.Path(td) / "edit_img.prg"
        r = subprocess.run(
            ["java", "-jar", os.path.expanduser("~/bin/KickAssembler/KickAss.jar"),
             str(ROOT / "plugins" / "edit.asm"),
             "-libdir", str(ROOT / "src"),
             "-odir", td, "-o", str(out), "-symbolfile",
             f":base={EDIT_IMAGE_BASE}"],
            cwd=ROOT, capture_output=True, text=True)
        assert r.returncode == 0, f"KickAss failed:\n{r.stdout}{r.stderr}"
        payload = out.read_bytes()[2:]
        syms = {}
        for line in (pathlib.Path(td) / "edit.sym").read_text().splitlines():
            line = line.strip()
            if line.startswith(".label "):
                name, _, val = line[7:].partition("=")
                syms[name] = int(val.lstrip("$"), 16)
    return payload, syms


def inject_edit_image(h: "Harness", image: tuple[bytes, dict[str, int]]) -> "Harness":
    payload, syms = image
    for i, byte in enumerate(payload):
        h.mpu.memory[EDIT_IMAGE_BASE + i] = byte
    h.sym.update(syms)
    return h
