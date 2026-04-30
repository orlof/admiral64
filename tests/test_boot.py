"""End-to-end boot smoke test.

Runs the full `boot` routine through to `boot_hang` and verifies the banner
ended up in screen RAM. This is the py65 half of the VICE ↔ py65 parity check:
what py65 shows here should visually match what VICE renders.
"""

from __future__ import annotations

from test_screen import SCREEN_BASE


from test_print import petscii_to_screen_code  # full PETSCII → screen-code lookup


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
    stop_addr = h.sym["repl_main"]      # boot now jumps into the REPL

    # Arm the MPU at boot.
    h.mpu.pc = boot_addr
    # Step until we land at boot_hang's jmp or hit a cap.
    for _ in range(1_000_000):
        if h.mpu.pc == stop_addr:
            break
        h.mpu.step()
    else:
        raise TimeoutError("boot did not reach repl_main")

    expected = _expected_screen_codes("     **** COMMODORE 64 ADMIRAL ****")
    actual = [h.mpu.memory[SCREEN_BASE + i] for i in range(len(expected))]
    assert actual == expected, f"banner mismatch\nexpected: {expected}\nactual:   {actual}"

    # Line 2: "  64K RAM SYSTEM  " <heap-free-int> " HEAP BYTES FREE".
    # The middle integer's width depends on the heap layout (test harness uses
    # NEXT_HANDLE=$A000 → 4 digits; production uses $D000 → 5 digits), so we
    # check the prefix at col 0 and the suffix immediately after a digit run.
    line2 = bytes(h.mpu.memory[SCREEN_BASE + 40 : SCREEN_BASE + 80])
    prefix = bytes(_expected_screen_codes(" 64K RAM SYSTEM  "))
    suffix = bytes(_expected_screen_codes(" HEAP BYTES FREE"))
    assert line2.startswith(prefix), f"banner line 2 prefix wrong: {line2!r}"
    # After the prefix, scan past the digit screen-codes ($30..$39).
    i = len(prefix)
    digits = 0
    while i < 40 and 0x30 <= line2[i] <= 0x39:
        i += 1
        digits += 1
    assert digits >= 1, "banner line 2 has no heap-free digits"
    assert line2[i : i + len(suffix)] == suffix, (
        f"banner line 2 suffix wrong at col {i}: {line2!r}"
    )

    # After the two-line banner + println, cursor is at row 2, col 0.
    assert h.mpu.memory[0x33] == 2, "cursor row after banner should be 2"
    assert h.mpu.memory[0x34] == 0, "cursor col after banner should be 0"

    # Static cursor block painted at (2, 0).
    cursor_addr = SCREEN_BASE + 2 * 40 + 0
    assert h.mpu.memory[cursor_addr] == 0xA0, "static cursor not painted"


def test_boot_sets_border_and_bg_to_green_theme(h):
    boot_addr = h.sym["boot"]
    stop_addr = h.sym["repl_main"]      # boot now jumps into the REPL
    h.mpu.pc = boot_addr
    for _ in range(1_000_000):
        if h.mpu.pc == stop_addr:
            break
        h.mpu.step()
    assert h.mpu.memory[0xD020] == 0x0D, "border should be light green"
    assert h.mpu.memory[0xD021] == 0x05, "background should be dark green"
    # First character cell should have the light-green foreground color.
    assert h.mpu.memory[0xD800] == 0x0D
