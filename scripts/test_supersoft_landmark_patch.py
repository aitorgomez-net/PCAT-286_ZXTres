#!/usr/bin/env python3
"""Independent ROM integrity checks; CPU execution is tested by the SV bench."""
import argparse
import hashlib
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("original", type=Path)
p.add_argument("patched", type=Path)
a = p.parse_args()
original, patched = a.original.read_bytes(), a.patched.read_bytes()
assert hashlib.sha256(original).hexdigest() == "a8310f83de0f3e6b71e4a3ff82a01ffe3c3b5a957677aed2fad17b96bce2e577"
assert len(patched) == 65536 and patched[:32768] == patched[32768:]
allowed = set()
for base in (0, 32768):
    for start, end in ((0x0E70, 0x0E73), (0x14D8, 0x14DB),
                       (0x30F0, 0x30F2), (0x3100, 0x3115),
                       (0x3120, 0x3135), (0x3160, 0x3168)):
        allowed.update(range(base + start, base + end))
changes = [i for i, (x, y) in enumerate(zip(original, patched)) if x != y]
assert changes and set(changes) <= allowed, "Unexpected changes outside PM entry/stubs/checksums"
assert patched[0xFFF0:0xFFF5] == bytes.fromhex("EA 65 80 00 F0")
for base in (0, 32768):
    for lane in (0, 1):
        assert sum(patched[base+lane:base+32768:2]) % 256 == 0

def target(at, opcode):
    assert patched[at] == opcode
    return (at + 3 + int.from_bytes(patched[at+1:at+3], "little", signed=True)) & 65535

assert target(0x8E70, 0xE9) == 0xB100
assert target(0x94D8, 0xE9) == 0xB120
assert target(0xB10F, 0xE8) == target(0xB12F, 0xE8) == 0x9CC0
assert target(0xB112, 0xE9) == 0x8E8F
assert target(0xB132, 0xE9) == 0x972D
assert patched[0xB160:0xB168] == b"SKIPPED\0"
print(f"LANDMARK_PATCH_INTEGRITY_PASS changed_bytes={len(changes)} lane_checksums=0 mirrors=identical previous_RAM_refresh_unchanged=1 sha256={hashlib.sha256(patched).hexdigest().upper()}")
