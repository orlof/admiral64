"""Regression for the METHOD_RECEIVER leak through _llp_code_call.

Scenario: a TYPE_CODE method call (`obj._cmd(args)`) sets METHOD_RECEIVER
via led_dot, but the TYPE_CODE call dispatcher used to leave that value in
place. The next free-function call going through _call_dispatch (e.g.
RANGE(...) inside a FOR loop body) would then read stale METHOD_RECEIVER,
prepend a phantom `me` arg, and the target builtin would panic ERR_ARITY
one over its real arg count.

Pure-py65 minimal repro — no MC dict, no banking tricks. Build a dict
with one TYPE_CODE leaf and one wrapper STR-lambda that calls it; then
in a single source we call the wrapper (which internally calls the
TYPE_CODE method) followed by a free-function call. Before the fix this
panics ERR_ARITY; after the fix it returns cleanly.
"""

def _eval(h, src):
    payload = list(src.encode("ascii"))
    handle = h.alloc_str(len(payload))
    h.write_bytes(h.read_word(handle) + 2, payload)
    h.rs_push(handle)
    try:
        h.call("parser_eval", max_steps=5_000_000)
        return None
    except AssertionError:
        return h.mpu.memory[0x27]


def test_typecode_method_then_free_function(h):
    # _F is a bare-RTS CODE blob (returns whatever W0 holds — its load addr).
    # F wraps it as a method call. Then RANGE() runs at top level — should
    # succeed because METHOD_RECEIVER was properly cleared after _F's call.
    src = (
        'D = <>\n'
        'D["_F"] = CODE("\\x60")\n'                         # bare RTS
        'D["F"] = "ME._F()\\nRETURN NONE"\n'
        'D.F()\n'                                            # uses TYPE_CODE path
        'RANGE(3)\n'                                         # MUST succeed
    )
    err = _eval(h, src)
    assert err is None, f"expected success, got ERR_${err:02X}"


def test_typecode_method_then_range_in_for(h):
    """The exact MC-dict shape: method call followed by FOR ... IN RANGE(...)."""
    src = (
        'D = <>\n'
        'D["_F"] = CODE("\\x60")\n'
        'D["F"] = "ME._F()\\nRETURN NONE"\n'
        'D.F()\n'
        'FOR I IN RANGE(0, 3):\n'
        '  I\n'
    )
    err = _eval(h, src)
    assert err is None, f"expected success, got ERR_${err:02X}"
