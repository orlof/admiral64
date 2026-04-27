"""End-to-end boot smoke test.

Runs the full `boot` routine through to `boot_hang` and verifies the banner
ended up in screen RAM. This is the py65 half of the VICE ↔ py65 parity check:
what py65 shows here should visually match what VICE renders.
"""

from __future__ import annotations

from test_screen import SCREEN_BASE


def petscii_to_screen_code(b: int) -> int:
    if 0x40 <= b <= 0x5F:
        return b - 0x40
    return b


def _expected_screen_codes(text: str) -> list[int]:
    return [petscii_to_screen_code(ord(c)) for c in text]


def test_boot_prints_banner(h):
    # The `h` fixture already ran rs_init / fs_init / alloc_init. Boot is
    # end-to-end so it will redo those (harmless) plus run screen_init and
    # print the banner. We direct-call boot and stop when PC reaches
    # boot_hang — which the harness detects as a no-progress loop via its
    # step cap, but we can also just run a fixed number of steps and
    # inspect memory.
    boot_addr = h.sym["boot"]
    boot_hang_addr = h.sym["boot_hang"]

    # Arm the MPU at boot.
    h.mpu.pc = boot_addr
    # Step until we land at boot_hang's jmp or hit a cap.
    for _ in range(1_000_000):
        if h.mpu.pc == boot_hang_addr:
            break
        h.mpu.step()
    else:
        raise TimeoutError("boot did not reach boot_hang")

    expected = _expected_screen_codes("ADMIRAL C64")
    actual = [h.mpu.memory[SCREEN_BASE + i] for i in range(len(expected))]
    assert actual == expected, f"banner mismatch\nexpected: {expected}\nactual:   {actual}"

    # Cursor should be at row 1, col 0 (println added newline).
    assert h.mpu.memory[0x33] == 1, "cursor row after println_str should be 1"
    assert h.mpu.memory[0x34] == 0, "cursor col after println_str should be 0"

    # And a static cursor block should now be painted at (1, 0).
    cursor_addr = SCREEN_BASE + 1 * 40 + 0
    assert h.mpu.memory[cursor_addr] == 0xA0, "static cursor not painted"


def test_boot_sets_border_and_bg_to_green_theme(h):
    boot_addr = h.sym["boot"]
    boot_hang_addr = h.sym["boot_hang"]
    h.mpu.pc = boot_addr
    for _ in range(1_000_000):
        if h.mpu.pc == boot_hang_addr:
            break
        h.mpu.step()
    assert h.mpu.memory[0xD020] == 0x0D, "border should be light green"
    assert h.mpu.memory[0xD021] == 0x05, "background should be dark green"
    # First character cell should have the light-green foreground color.
    assert h.mpu.memory[0xD800] == 0x0D
