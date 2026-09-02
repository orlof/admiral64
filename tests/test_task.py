"""Cooperative multitasking core (src/task.asm): SPAWN + YIELD + context switch.

Two tasks share the heap and screen but have SEPARATE scopes (process-scope
isolation — a task can't see main's variables) and their own FS/RS, ZP
register file and hardware stack (copy-swapped). Preemption (timer IRQ) is a
later layer; these drive the switch cooperatively via YIELD.

Because scopes are isolated, the observable shared channel here is the screen:
each context has its own cursor, so tasks write to distinct cells via CURSOR.
"""
from __future__ import annotations

import pytest

from test_parser import _eval, _eval_str

SCREEN = 0x0400


def scr(h, col, row):
    return h.mpu.memory[SCREEN + row * 40 + col]


def run(h, src, max_steps=15_000_000):
    from test_str import place_str
    handle = place_str(h, 0x8A00, list(src.encode("ascii")))
    h.rs_push(handle)
    h.call("parser_eval", max_steps=max_steps)


def test_spawn_runs_task_body(h):
    # Task writes 'T' at (0,2); it must actually execute after the yield.
    run(h, 'SPAWN("CURSOR(0, 2)\\nPRINT \\"T\\"")\nYIELD()')
    assert scr(h, 0, 2) == 0x14        # 'T'


def test_task_returns_control_to_main(h):
    # After the task runs and exits, main continues and prints 'M' at (0,4).
    run(h, 'SPAWN("CURSOR(0, 2)\\nPRINT \\"T\\"")\nYIELD()\nCURSOR(0, 4)\nPRINT "M"')
    assert scr(h, 0, 2) == 0x14        # 'T' (task)
    assert scr(h, 0, 4) == 0x0D        # 'M' (main, screencode $0D)


def test_interleave_ordering(h):
    # main:'A'@(0,0) yield task:'B'@(1,0) yield main:'C'@(2,0) yield task:'D'@(3,0)
    src = ('SPAWN("CURSOR(1,0)\\nPRINT \\"B\\"\\nYIELD()\\nCURSOR(3,0)\\nPRINT \\"D\\"")\n'
           'CURSOR(0,0)\nPRINT "A"\n'
           'YIELD()\n'
           'CURSOR(2,0)\nPRINT "C"\n'
           'YIELD()')
    run(h, src)
    assert scr(h, 0, 0) == 0x01        # 'A'
    assert scr(h, 1, 0) == 0x02        # 'B'
    assert scr(h, 2, 0) == 0x03        # 'C'
    assert scr(h, 3, 0) == 0x04        # 'D'


def test_task_scope_is_isolated(h):
    # G defined in main is invisible to the task; the task defining its own G
    # doesn't touch main's. Task writes G to screen; main writes its own.
    src = ('G = 5\n'
           'SPAWN("G = 9\\nCURSOR(0,6)\\nPRINT STR(G)")\n'
           'YIELD()\n'
           'CURSOR(0,7)\nPRINT STR(G)')
    run(h, src)
    assert scr(h, 0, 6) == 0x39        # '9' (task's G)
    assert scr(h, 0, 7) == 0x35        # '5' (main's G, unchanged)


def test_slot_reused_after_task_exits(h):
    run(h, ('SPAWN("CURSOR(0,2)\\nPRINT \\"X\\"")\nYIELD()\n'
            'SPAWN("CURSOR(0,3)\\nPRINT \\"Y\\"")\nYIELD()'))
    assert scr(h, 0, 2) == 0x18        # 'X' (first task)
    assert scr(h, 0, 3) == 0x19        # 'Y' (second task in the reused slot)


def test_yield_with_no_other_task_is_noop(h):
    assert _eval(h, 'X = 3\nYIELD()\nX') == 3


def test_task_survives_gc_in_main(h):
    # The task holds a list across a yield; main churns the heap (mark/sweep/
    # compact) between yields; the task's roots must survive.
    src = ('SPAWN("T = [7, 8, 9]\\nYIELD()\\nCURSOR(0,5)\\nPRINT STR(T[1])")\n'
           'YIELD()\n'                       # task builds T, yields back
           'i = 0\n'
           'WHILE i < 40:\n'
           '  junk = "z" * 40\n'
           '  i = i + 1\n'
           'YIELD()')                        # resume task; T[1] must be 8
    run(h, src, max_steps=30_000_000)
    assert scr(h, 0, 5) == 0x38            # '8'


def test_three_tasks_spawn_and_run(h):
    # Spawn three tasks (slots 1,2,3), each writes to a distinct screen row;
    # round-robin YIELDs let each run once.
    src = ('SPAWN("CURSOR(0,10)\\nPRINT \\"A\\"")\n'
           'SPAWN("CURSOR(0,11)\\nPRINT \\"B\\"")\n'
           'SPAWN("CURSOR(0,12)\\nPRINT \\"C\\"")\n'
           'YIELD()\nYIELD()\nYIELD()')
    run(h, src, max_steps=20_000_000)
    assert scr(h, 0, 10) == 0x01       # 'A'
    assert scr(h, 0, 11) == 0x02       # 'B'
    assert scr(h, 0, 12) == 0x03       # 'C'


def test_spawn_all_slots_then_full_errors(h):
    # 3 spawnable slots (1..3); a 4th SPAWN with all busy panics ERR_TASK ($09).
    import pytest as _pt
    from test_str import place_str
    from conftest import ERROR_CODE_ZP
    body = 'WHILE 1:\\n  YIELD()'          # never exits → keeps its slot
    src = (f'SPAWN("{body}")\nSPAWN("{body}")\nSPAWN("{body}")\nSPAWN("{body}")')
    handle = place_str(h, 0x8A00, list(src.encode("ascii")))
    h.rs_push(handle)
    with _pt.raises(Exception):
        h.call("parser_eval", max_steps=8_000_000)
    assert h.mpu.memory[ERROR_CODE_ZP] == 0x09    # ERR_TASK


def test_preemption_switches_at_statement_boundary(h):
    # No explicit YIELD in main. Simulate a periodic timer IRQ (set the flag
    # every ~800 instructions); parser_stmt switches at statement boundaries.
    # Main runs a long loop so the task gets preempted-in and finishes.
    from test_str import place_str
    src = ('SPAWN("CURSOR(0,13)\\nPRINT \\"P\\"")\n'
           'i = 0\nWHILE i < 150:\n  i = i + 1')
    handle = place_str(h, 0x8A00, list(src.encode("ascii")))
    h.rs_push(handle)
    pend = h.sym["TASK_SWITCH_PENDING"]
    sentinel = 0xFFFE
    h.mpu.memory[0x0100 + h.mpu.sp] = (sentinel >> 8) & 0xFF
    h.mpu.sp = (h.mpu.sp - 1) & 0xFF
    h.mpu.memory[0x0100 + h.mpu.sp] = sentinel & 0xFF
    h.mpu.sp = (h.mpu.sp - 1) & 0xFF
    h.mpu.pc = h.sym["parser_eval"]
    n = 0
    for _ in range(15_000_000):
        if h.mpu.pc == sentinel + 1:
            break
        n += 1
        if n % 800 == 0:
            h.mpu.memory[pend] = 1        # periodic timer tick
        h.mpu.step()
    assert scr(h, 0, 13) == 0x10          # 'P' — task ran with no explicit YIELD


def test_getc_yields_to_task_while_waiting(hd):
    # GETC() spins on an empty keyboard; while waiting it must yield to a
    # spawned task (blocking-call yield). Queue is empty ($00) for a few
    # polls, then 'X'. The task prints during the empty polls.
    from test_parser import _stub_getin_queue
    from test_str import place_str
    _stub_getin_queue(hd, bytes([0, 0, 0, 0, 0, ord("X")]))
    src = ('SPAWN("CURSOR(0,14)\\nPRINT \\"Y\\"")\n'
           'GETC()')
    handle = place_str(hd, 0x8A00, list(src.encode("ascii")))
    hd.rs_push(handle)
    hd.call("parser_eval", max_steps=15_000_000)
    assert scr(hd, 0, 14) == 0x19       # 'Y' — task ran during the GETC wait


def test_each_task_writes_to_its_own_window(h):
    # The crash fix: current-window is per-task. Task 1 opens window A and
    # prints into it; main opens window B and prints into it. Neither's output
    # lands in the other's window (shared global current-window used to cross
    # them and overflow a heap buffer -> GC JAM).
    src = ('SPAWN("A = WINDOW(2, 2, 8, 4, \\"A\\")\\nPRINT \\"X\\"")\n'
           'YIELD()\n'                                   # task: opens A, prints X, exits
           'B = WINDOW(20, 2, 8, 4, "B")\n'
           'PRINT "Y"')
    run(h, src, max_steps=20_000_000)
    # A interior origin (3,3); X there. B interior origin (21,3); Y there.
    assert scr(h, 3, 3) == 0x18       # 'X' in task's window A
    assert scr(h, 21, 3) == 0x19      # 'Y' in main's window B
    # A's cell must NOT hold main's 'Y' and vice versa (no cross-write).
    assert scr(h, 3, 3) != 0x19
    assert scr(h, 21, 3) != 0x18


def test_only_focused_task_reads_keyboard(hd):
    # Focus gates the keyboard: task 0 (REPL) is focused at boot; a spawned
    # task's GETC must NOT steal keys — it yields until focused. Here the
    # spawned task loops GETC-ing into a screen cell; with focus on task 0
    # it should read NOTHING even though keys are queued for task 0.
    from test_parser import _stub_getin_queue
    from test_str import place_str
    _stub_getin_queue(hd, bytes([ord("A"), ord("B"), ord("C"), 0, 0, 0]))
    # Task tries to GETC and mark row 15; main GETCs 3 keys (it is focused).
    src = ('SPAWN("K = GETC()\\nCURSOR(0,15)\\nPRINT K")\n'
           'A = GETC()\nB = GETC()\nC = GETC()\n'
           'CURSOR(0,16)\nPRINT A')
    handle = place_str(hd, 0x8A00, list(src.encode("ascii")))
    hd.rs_push(handle)
    hd.call("parser_eval", max_steps=20_000_000)
    # Main (focused) got 'A'; the task never read (row 15 still blank).
    assert scr(hd, 0, 16) == 0x01       # 'A' read by focused main
    assert scr(hd, 0, 15) == 0x00       # task read nothing (unfocused)


def test_focus_cycle_hands_keyboard_to_task(h):
    # task_focus_next moves focus to the next active task; then that task's
    # GETC reads while the (now unfocused) main would yield.
    from test_parser import _stub_getin_queue
    from test_str import place_str
    _stub_getin_queue(h, bytes([ord("Z"), 0, 0]))
    src = 'SPAWN("K = GETC()\\nCURSOR(0,17)\\nPRINT K")\nYIELD()'
    handle = place_str(h, 0x8A00, list(src.encode("ascii")))
    h.rs_push(handle)
    # Simulate a C= tap: hand focus to task 1 before running.
    h.mpu.memory[h.sym["TASK_FOCUS"]] = 1
    h.call("parser_eval", max_steps=20_000_000)
    assert scr(h, 0, 17) == 0x1A        # 'Z' read by the now-focused task


def test_line_editor_state_is_per_task(h):
    """The in-progress line edit (repl_line_buf + anchor/base_col/len) must
    round-trip per task. Two shells (main REPL + a spawned shell's INPUT) each
    sit parked mid-edit inside _rpl_read_line; a shared buffer let one clobber
    the other's anchor row, so the main line 'jumped' into the spawned
    window. Verify the task switch saves/restores each task's edit state."""
    LBUF = h.sym["repl_line_buf"]
    LEN = h.sym["repl_line_len"]
    ANCHOR = h.sym["repl_line_anchor_row"]
    BASE = h.sym["repl_base_col"]
    # Both tasks default to fullscreen (wm_cur_h == 0) so ts_load_target_zp's
    # wm_reactivate takes the safe no-list path.
    for slot in range(2):
        h.mpu.memory[h.sym["t_wmcur_lo"] + slot] = 0
        h.mpu.memory[h.sym["t_wmcur_hi"] + slot] = 0

    # Task 0 is mid-edit on "MAIN" at anchor row 5, base col 1.
    h.mpu.memory[ts := h.sym["ts_cur"]] = 0
    for i, c in enumerate(b"MAIN"):
        h.mpu.memory[LBUF + i] = c
    h.mpu.memory[LEN] = 4
    h.mpu.memory[ANCHOR] = 5
    h.mpu.memory[BASE] = 1
    h.call("ts_save_cur_zp")            # -> t_ledit[0]

    # Switch in task 1 (fresh), then edit "SHELL" at anchor row 20, base col 2.
    h.mpu.memory[h.sym["ts_target"]] = 1
    h.call("ts_load_target_zp")
    for i, c in enumerate(b"SHELL"):
        h.mpu.memory[LBUF + i] = c
    h.mpu.memory[LEN] = 5
    h.mpu.memory[ANCHOR] = 20
    h.mpu.memory[BASE] = 2
    h.mpu.memory[ts] = 1
    h.call("ts_save_cur_zp")            # -> t_ledit[1]

    # Switch back to task 0: its edit must be exactly as left, not "SHELL".
    h.mpu.memory[h.sym["ts_target"]] = 0
    h.call("ts_load_target_zp")
    assert bytes(h.mpu.memory[LBUF:LBUF + 4]) == b"MAIN"
    assert h.mpu.memory[LEN] == 4
    assert h.mpu.memory[ANCHOR] == 5    # not 20 — the bug's smoking gun
    assert h.mpu.memory[BASE] == 1
