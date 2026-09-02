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
    handle = place_str(h, 0x8500, list(src.encode("ascii")))
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
