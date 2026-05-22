"""Tests for REBOOT(graphics_capable) + the dynamic heap ceiling.

REBOOT warm-restarts into one of two memory configs by setting GFX_CONFIG and
re-entering `boot`; boot's `_heap_apply` turns that into HEAP_TOP, which
`alloc_init` uses as the handle-table ceiling. Two angles:
  - the heap-config selection (`_heap_apply` + `alloc_init`) lands NEXT_HANDLE
    at $FFF8 (text) or $DC00 (graphics);
  - `builtin_reboot` maps its arg's truthiness to GFX_CONFIG, then JMPs to boot
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


def _reboot_via_eval(h, source: str) -> int:
    """Evaluate `source` (a REBOOT(...) call); run until PC reaches boot and
    return GFX_CONFIG. builtin_reboot JMPs to boot and never returns."""
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
            raise AssertionError("parser_eval returned without rebooting")
        h.mpu.step()
    raise TimeoutError("did not reach boot")


def test_reboot_true_selects_graphics(h):
    assert _reboot_via_eval(h, "REBOOT(TRUE)") == 1


def test_reboot_false_selects_text(h):
    h.mpu.memory[h.sym["GFX_CONFIG"]] = 1   # prove it gets cleared
    assert _reboot_via_eval(h, "REBOOT(FALSE)") == 0


def test_reboot_truthy_int_selects_graphics(h):
    assert _reboot_via_eval(h, "REBOOT(5)") == 1


def test_reboot_zero_int_selects_text(h):
    h.mpu.memory[h.sym["GFX_CONFIG"]] = 1
    assert _reboot_via_eval(h, "REBOOT(0)") == 0
