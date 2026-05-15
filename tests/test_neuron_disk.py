"""Verify the hand-packed NEURON SEQ deserializes to a TYPE_STR with the
expected payload — the precondition for `F = LOAD("NEURON") ; F()` to work
in Admiral.

Reuses the `hd` fixture's KERNAL mock: seed `kernal_mock.files` with the
packed bytes, open the file via disk_open_seq_r, call disk_deserialize,
inspect RV.
"""
import subprocess
from pathlib import Path

from conftest import RV
from test_disk import _stage_name

TYPE_STR = 0x21
H_TYPE = 6
O_HEADER = 2  # 2-byte O_LEN before payload

SOURCE = Path(__file__).parent.parent / "examples" / "neuron.admiral"
PACKER = Path(__file__).parent.parent / "tools" / "pack_str_record.py"


def _packed_bytes(tmp_path):
    out = tmp_path / "neuron.bin"
    subprocess.check_call(["python3", str(PACKER), str(SOURCE), str(out)])
    return out.read_bytes()


def test_load_returns_type_str_with_source(hd, tmp_path):
    packed = _packed_bytes(tmp_path)
    expected = SOURCE.read_bytes().replace(b"\n", b"\r")

    # hd doesn't set NEXT_HANDLE the way the plain `h` fixture does; deserialize
    # allocs into the heap so we need a sane handle-table base.
    hd.write_word(0x20, 0xA000)

    hd.kernal_mock.files[b"NEURON"] = packed

    _stage_name(hd, b"NEURON")
    hd.call("disk_open_seq_r")
    hd.call("disk_deserialize", max_steps=2_000_000)
    hd.call("disk_close_data")

    rv = hd.read_word(RV)
    assert rv != 0, "RV should hold a non-null handle"

    type_tag = hd.mpu.memory[rv + H_TYPE]
    assert type_tag == TYPE_STR, f"expected TYPE_STR ($21), got ${type_tag:02X}"

    payload_ptr = hd.read_word(rv)
    payload_len = hd.mpu.memory[payload_ptr] | (hd.mpu.memory[payload_ptr + 1] << 8)
    payload = bytes(hd.mpu.memory[payload_ptr + O_HEADER : payload_ptr + O_HEADER + payload_len])

    assert payload_len == len(expected)
    assert payload == expected
