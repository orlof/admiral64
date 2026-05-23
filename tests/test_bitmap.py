"""Tests for BITMAP(graphics_capable) + the dynamic heap ceiling.

BITMAP warm-restarts into one of two memory configs by setting GFX_CONFIG and
re-entering `boot`; boot's `_heap_apply` turns that into HEAP_TOP, which
`alloc_init` uses as the handle-table ceiling. Two angles:
  - the heap-config selection (`_heap_apply` + `alloc_init`) lands NEXT_HANDLE
    at $FFF8 (text) or $DC00 (graphics);
  - `builtin_bitmap` maps its arg's truthiness to GFX_CONFIG, then JMPs to boot
    (it never RTSes, so we run until PC reaches `boot` and inspect the flag).

The VIC bitmap / banking itself is not testable in py65 (CPU+RAM only, no VIC,
$01 writes are no-ops) — that's verified under VICE.
"""

from __future__ import annotations

from conftest import NEXT_HANDLE_ZP

TEXT_CEIL = 0xFFF8
GFX_CEIL = 0xDC00


def _select(h, cfg: int) -> int:
    """Apply config `cfg` via the real boot path pieces; return NEXT_HANDLE."""
    h.mpu.memory[h.sym["GFX_CONFIG"]] = cfg
    h.call("_heap_apply")
    h.call("alloc_init")
    return h.read_word(NEXT_HANDLE_ZP)


def test_text_config_ceiling(h):
    assert _select(h, 0) == TEXT_CEIL


def test_graphics_config_ceiling(h):
    assert _select(h, 1) == GFX_CEIL


def test_heap_top_word_set(h):
    h.mpu.memory[h.sym["GFX_CONFIG"]] = 1
    h.call("_heap_apply")
    assert h.read_word(h.sym["HEAP_TOP"]) == GFX_CEIL
    h.mpu.memory[h.sym["GFX_CONFIG"]] = 0
    h.call("_heap_apply")
    assert h.read_word(h.sym["HEAP_TOP"]) == TEXT_CEIL


def _bitmap_via_eval(h, source: str) -> int:
    """Evaluate `source` (a BITMAP(...) call); run until PC reaches boot and
    return GFX_CONFIG. builtin_bitmap JMPs to boot and never returns."""
    payload = list(source.encode("ascii"))
    handle = h.alloc_str(len(payload))
    h.write_bytes(h.read_word(handle) + 2, payload)
    h.rs_push(handle)

    sentinel = 0xFFFE
    h.mpu.memory[0x0100 + h.mpu.sp] = (sentinel >> 8) & 0xFF
    h.mpu.sp = (h.mpu.sp - 1) & 0xFF
    h.mpu.memory[0x0100 + h.mpu.sp] = sentinel & 0xFF
    h.mpu.sp = (h.mpu.sp - 1) & 0xFF
    h.mpu.pc = h.sym["parser_eval"]

    boot = h.sym["boot"]
    for _ in range(5_000_000):
        if h.mpu.pc == boot:
            return h.mpu.memory[h.sym["GFX_CONFIG"]]
        if h.mpu.pc == sentinel + 1:
            raise AssertionError("parser_eval returned without bitmaping")
        h.mpu.step()
    raise TimeoutError("did not reach boot")


def test_bitmap_true_selects_graphics(h):
    assert _bitmap_via_eval(h, "BITMAP(TRUE)") == 1


def test_bitmap_false_selects_text(h):
    h.mpu.memory[h.sym["GFX_CONFIG"]] = 1   # prove it gets cleared
    assert _bitmap_via_eval(h, "BITMAP(FALSE)") == 0


def test_bitmap_truthy_int_selects_graphics(h):
    assert _bitmap_via_eval(h, "BITMAP(5)") == 1


def test_bitmap_zero_int_selects_text(h):
    h.mpu.memory[h.sym["GFX_CONFIG"]] = 1
    assert _bitmap_via_eval(h, "BITMAP(0)") == 0


# -----------------------------------------------------------------------------
# _vic_toggle — the F8-handler swap routine. The IRQ buffer-scan that invokes
# it can't run in py65 (no real IRQs), but the swap itself is just memory
# writes and is fully exercisable: prime the VIC regs and the SAVED_* cells,
# JSR _vic_toggle, assert.
# -----------------------------------------------------------------------------

def _set_vic(h, d018: int, d011: int, d016: int, dd00: int) -> None:
    h.mpu.memory[0xD018] = d018
    h.mpu.memory[0xD011] = d011
    h.mpu.memory[0xD016] = d016
    h.mpu.memory[0xDD00] = dd00


def test_vic_toggle_text_to_gfx_uses_saved(h):
    # Start in text mode ($D011 BMM clear). The SAVED_* cells were assembled
    # with the hi-res defaults ($78/$3B/$C8/$00), so a toggle from here lands
    # in mono hi-res; other $DD00 bits stay put.
    _set_vic(h, 0x15, 0x1B, 0xC8, 0x97)
    h.call("_vic_toggle")
    assert h.mpu.memory[0xD018] == 0x78
    assert h.mpu.memory[0xD011] == 0x3B
    assert h.mpu.memory[0xD016] == 0xC8
    assert (h.mpu.memory[0xDD00] & 0x03) == 0x00
    assert (h.mpu.memory[0xDD00] & 0xFC) == 0x94


def test_vic_toggle_gfx_to_text_saves_live_state(h):
    # Pretend HIRES.SHOW just ran. A toggle captures those values into SAVED_*
    # and writes text values to VIC.
    _set_vic(h, 0x78, 0x3B, 0xC8, 0x94)
    h.call("_vic_toggle")
    assert h.mpu.memory[0xD018] == 0x15
    assert h.mpu.memory[0xD011] == 0x1B
    assert h.mpu.memory[0xD016] == 0xC8
    assert (h.mpu.memory[0xDD00] & 0x03) == 0x03
    assert h.mpu.memory[h.sym["SAVED_D018"]] == 0x78
    assert h.mpu.memory[h.sym["SAVED_D011"]] == 0x3B
    assert h.mpu.memory[h.sym["SAVED_D016"]] == 0xC8
    assert h.mpu.memory[h.sym["SAVED_DD00_BANK"]] == 0x00


def test_vic_toggle_round_trip_preserves_mc(h):
    # MC mode: $D016 = $D8 (MCM set). Round-trip must restore MC, not hi-res.
    _set_vic(h, 0x78, 0x3B, 0xD8, 0x94)
    h.call("_vic_toggle")                          # gfx -> text
    assert h.mpu.memory[0xD016] == 0xC8
    assert h.mpu.memory[h.sym["SAVED_D016"]] == 0xD8
    h.call("_vic_toggle")                          # text -> gfx
    assert h.mpu.memory[0xD016] == 0xD8
    assert (h.mpu.memory[0xDD00] & 0x03) == 0x00
