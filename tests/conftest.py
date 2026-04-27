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

# Heap region bounds (must stay in sync with src/defs.asm).
HEAP_DATA_START = 0x8800
HEAP_HANDLE_START = 0xD000

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


@dataclass
class Harness:
    mpu: MPU
    sym: dict[str, int]

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
        """Call alloc_int with the given payload size. Returns RV."""
        self.write_word(ALLOC_SIZE_ZP, size & 0xFFFF)
        self.call("alloc_int")
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
        handle = self.alloc_int(payload)
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
    harness.call("alloc_init")
    harness.call("rnd_init")
    # Move handle area below BASIC ROM so allocations don't trample ROM bytes
    # in the py65 image. NEXT_HANDLE = $A000 → first handle at $9FF8.
    harness.write_word(0x20, 0xA000)  # NEXT_HANDLE — must match defs.asm
    return harness
