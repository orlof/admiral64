#!/usr/bin/env python3
# Build the ternary search tree (TST) used by parser.asm to map free-function
# builtin names → impl-address. The 6502 walker reads the input string
# right-to-left (it lets the loop test end-of-input via `dey; bmi` rather than
# a separate compare against length), so names are inserted with characters in
# reversed order.
#
# Output is a KickAssembler include with five parallel SoA arrays, indexed by
# 1-byte node id, plus a dense impl-address payload table:
#
#   tst_char[i]    discriminator char at node i
#   tst_lt[i]      left-child node index, or 0 = "no child"
#   tst_eq[i]      eq-child  node index, or 0 = "no child"
#   tst_gt[i]      right-child node index, or 0 = "no child"
#   tst_payload[i] 0 if node is non-terminal, else 1-based index into tst_impl_*
#   tst_impl_lo / tst_impl_hi   impl-address per registered name
#
# The 0-as-"no child" sentinel doubles as "root index". A root cannot be its
# own child (no cycles in a tree), so the dual use never collides.
#
# Usage: build_tst.py <output.asm>

from __future__ import annotations

import math
import sys
from pathlib import Path

# (admiral-source name, kickass impl label).
# Insertion order shapes the tree, but main() sorts by reversed name and
# inserts median-first so the source order below is purely cosmetic.
BUILTINS = [
    ("LEN",   "builtin_len"),
    ("RANGE", "builtin_range"),
    ("BOOL",  "builtin_bool"),
    ("ABS",   "builtin_abs"),
    ("CHR",   "builtin_chr"),
    ("ORD",   "builtin_ord"),
    ("TYPE",  "builtin_type"),
    ("INT",   "builtin_int"),
    ("FLOAT", "builtin_float"),
    ("STR",   "builtin_str"),
    ("ID",    "builtin_id"),
    ("CMP",   "builtin_cmp"),
    ("HEX",   "builtin_hex"),
    ("REPR",  "builtin_repr"),
    ("SORT",  "builtin_sort"),
    ("RND",   "builtin_rnd"),
    ("MEM",     "builtin_mem"),
    ("GLOBALS", "builtin_globals"),
    ("LOCALS",  "builtin_locals"),
    ("WSET",    "builtin_wset"),
    ("WGET",    "builtin_wget"),
    ("CURSOR",  "builtin_cursor"),
    ("FORMAT",  "builtin_format"),
    ("RM",      "builtin_rm"),
    ("DIR",     "builtin_dir"),
    ("SAVE",    "builtin_save"),
    ("LOAD",    "builtin_load"),
    ("GETC",    "builtin_getc"),
    ("KEY",     "builtin_key"),
    ("INPUT",   "builtin_input"),
    ("EDIT",    "builtin_edit"),
    ("PEEK",    "builtin_peek"),
    ("POKE",    "builtin_poke"),
    ("CALL",    "builtin_call"),
    ("EXP",     "builtin_exp"),
    ("LOG",     "builtin_log"),
    ("SQRT",    "builtin_sqrt"),
    ("SIN",     "builtin_sin"),
    ("COS",     "builtin_cos"),
    ("TAN",     "builtin_tan"),
    ("ATAN",    "builtin_atan"),
]


class Node:
    __slots__ = ("char", "lt", "eq", "gt", "payload", "idx")

    def __init__(self, char: str) -> None:
        self.char = char
        self.lt: Node | None = None
        self.eq: Node | None = None
        self.gt: Node | None = None
        self.payload: str | None = None
        self.idx: int = -1


def insert(root: Node | None, chars: list[str], i: int, payload: str) -> Node:
    if root is None:
        root = Node(chars[i])
    if chars[i] < root.char:
        root.lt = insert(root.lt, chars, i, payload)
    elif chars[i] > root.char:
        root.gt = insert(root.gt, chars, i, payload)
    elif i + 1 < len(chars):
        root.eq = insert(root.eq, chars, i + 1, payload)
    else:
        if root.payload is not None:
            raise ValueError(f"duplicate name → payload {payload}")
        root.payload = payload
    return root


def dfs_assign(root: Node) -> list[Node]:
    nodes: list[Node] = []

    def walk(n: Node | None) -> None:
        if n is None:
            return
        n.idx = len(nodes)
        nodes.append(n)
        walk(n.lt)
        walk(n.eq)
        walk(n.gt)

    walk(root)
    return nodes


def lookup(root: Node, name: str) -> str | None:
    """Reference TST walk used to verify the built tree before emit."""
    payload, _ = walk(root, name)
    return payload


def walk(root: Node, name: str) -> tuple[str | None, int]:
    """Like lookup, but also returns the node-visit count for cost-checking."""
    chars = list(reversed(name))
    if not chars:
        return None, 0
    n: Node | None = root
    i = 0
    visits = 0
    while n is not None:
        visits += 1
        c = chars[i]
        if c < n.char:
            n = n.lt
        elif c > n.char:
            n = n.gt
        else:
            i += 1
            if i == len(chars):
                return n.payload, visits
            n = n.eq
    return None, visits


def fmt_chars(values: list[str]) -> str:
    # Emit ASCII byte values as hex literals: KickAssembler's default text
    # encoding is screencode/PETSCII, so `'n'` would assemble to $0E or $4E,
    # not $6E. Hex bytes are unambiguous.
    return ", ".join(f"${ord(c):02X}" for c in values)


def fmt_ints(values: list[int]) -> str:
    return ", ".join(str(v) for v in values)


def emit(nodes: list[Node], names_in_order: list[tuple[str, str]],
        output_path: Path) -> None:
    payload_for_label: dict[str, int] = {}
    payloads: list[str] = []
    for _, label in names_in_order:
        payloads.append(label)
        payload_for_label[label] = len(payloads)  # 1-based

    if len(nodes) > 255:
        raise ValueError(f"too many TST nodes ({len(nodes)}) for 1-byte indexing")

    chars = [n.char for n in nodes]
    lt    = [n.lt.idx if n.lt else 0 for n in nodes]
    eq    = [n.eq.idx if n.eq else 0 for n in nodes]
    gt    = [n.gt.idx if n.gt else 0 for n in nodes]
    pay   = [payload_for_label[n.payload] if n.payload else 0 for n in nodes]

    lines = [
        "// Auto-generated by tools/build_tst.py — do not edit by hand.",
        "// Builtin-name TST: 6502 walks the input string right-to-left, so",
        "// names were inserted with characters in reversed order. Sentinel 0",
        "// = no child (root is at index 0; root is never anyone's child).",
        "",
        f"// {len(nodes)} nodes, {len(payloads)} payloads",
        "",
        "tst_char:",
        f"    .byte {fmt_chars(chars)}",
        "tst_lt:",
        f"    .byte {fmt_ints(lt)}",
        "tst_eq:",
        f"    .byte {fmt_ints(eq)}",
        "tst_gt:",
        f"    .byte {fmt_ints(gt)}",
        "tst_payload:",
        f"    .byte {fmt_ints(pay)}",
        "",
        "// payload index is 1-based (0 reserved for non-terminals); subtract 1",
        "// before reading these tables.",
        "tst_impl_lo:",
        "    .byte " + ", ".join(f"<{lbl}" for lbl in payloads),
        "tst_impl_hi:",
        "    .byte " + ", ".join(f">{lbl}" for lbl in payloads),
        "",
    ]
    output_path.write_text("\n".join(lines))


def build_balanced(builtins: list[tuple[str, str]]) -> Node:
    """Insert names median-first by reversed-name order so the resulting tree
    is well-balanced regardless of source-file order. Each recursive half is
    again inserted median-first, which keeps the per-level BSTs balanced too."""
    items = sorted(builtins, key=lambda it: it[0][::-1])

    root: Node | None = None

    def insert_median(lo: int, hi: int) -> None:
        nonlocal root
        if lo >= hi:
            return
        mid = (lo + hi) // 2
        name, label = items[mid]
        root = insert(root, list(reversed(name)), 0, label)
        insert_median(lo, mid)
        insert_median(mid + 1, hi)

    insert_median(0, len(items))
    assert root is not None
    return root


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: build_tst.py <output.asm>", file=sys.stderr)
        return 2
    out_path = Path(sys.argv[1])

    root = build_balanced(BUILTINS)

    # Sanity: every registered name resolves through the built tree to its
    # own label, and a few negative cases miss.
    for name, label in BUILTINS:
        got = lookup(root, name)
        if got != label:
            raise SystemExit(f"self-check failed: {name!r} → {got}, expected {label}")
    for negative in ["", "le", "lens", "ranges", "z", "rang"]:
        if lookup(root, negative) is not None:
            raise SystemExit(f"self-check failed: {negative!r} should miss")

    # Cost ceiling: in a TST, a hit visits at least len(name) nodes (one char
    # match per position) plus lt/gt steps inside each level's BST. A balanced
    # per-level BST adds at most ceil(log2(N)) visits across all levels, so
    # max_name_len + ceil(log2(N)) is a safe defensive ceiling. If a future
    # builtin pushes us over, this trips and we know to look at the layout.
    max_name_len = max(len(name) for name, _ in BUILTINS)
    ceiling = max_name_len + max(1, math.ceil(math.log2(len(BUILTINS))))
    worst_name, worst_visits = max(
        ((name, walk(root, name)[1]) for name, _ in BUILTINS),
        key=lambda it: it[1],
    )
    if worst_visits > ceiling:
        raise SystemExit(
            f"build_tst.py: walk depth regression — {worst_name!r} costs "
            f"{worst_visits} node visits, ceiling is {ceiling}. Reorder "
            f"BUILTINS or revisit build_balanced()."
        )

    nodes = dfs_assign(root)
    emit(nodes, BUILTINS, out_path)
    print(f"build_tst.py: wrote {out_path} ({len(nodes)} nodes, "
          f"{len(BUILTINS)} payloads, worst walk = {worst_visits} visits "
          f"on {worst_name!r}, ceiling = {ceiling})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
