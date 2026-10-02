"""Focused checks for the CheckIt numeric frontend; no CPU regression suite."""
import argparse
import json
import struct
import tempfile
from pathlib import Path

from build_checknum import build, sha, INPUT_HASHES, MAIN_SEG, IMAGE_SIZE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("executable", type=Path)
    args = parser.parse_args()
    supplied = args.executable.read_bytes()
    with tempfile.TemporaryDirectory(prefix="checknum-verify-") as temporary:
        root = Path(temporary)
        first, second = root / "one.exe", root / "two.exe"
        manifest = build(args.source, first)
        build(args.source, second)
        assert first.read_bytes() == second.read_bytes() == supplied, "Non-reproducible executable"
        bad = root / "bad-input"
        bad.mkdir()
        for name in INPUT_HASHES:
            (bad / name).write_bytes((args.source / name).read_bytes())
        changed = bytearray((bad / "CHECKIT.OVL").read_bytes())
        changed[0] ^= 1
        (bad / "CHECKIT.OVL").write_bytes(changed)
        rejected = root / "rejected.exe"
        try:
            build(bad, rejected)
        except ValueError:
            pass
        else:
            raise AssertionError("Changed CheckIt input was accepted")
        assert not rejected.exists(), "Failure wrote an executable"

    header = struct.unpack_from("<14H", supplied)
    signature, remainder, pages, count, paragraphs = header[:5]
    assert signature == 0x5A4D
    assert (pages - 1) * 512 + (remainder or 512) == len(supplied)
    assert count * 4 + header[12] <= paragraphs * 16
    original = supplied[paragraphs * 16:]
    assert len(original) == IMAGE_SIZE
    assert header[10:12] == (0x22, 0x2691)
    relocations = [struct.unpack_from("<HH", supplied, header[12] + index * 4)
                   for index in range(count)]
    assert len(relocations) == len(set(relocations))
    # Simulate DOS relocation at two load segments. Each word must receive
    # exactly one load-segment addition, including all frontend far calls.
    for load_segment in (0x1000, 0x2000):
        image = bytearray(original)
        for offset, segment in relocations:
            position = segment * 16 + offset
            value = struct.unpack_from("<H", image, position)[0]
            struct.pack_into("<H", image, position, (value + load_segment) & 0xFFFF)
        for offset, segment in relocations:
            position = segment * 16 + offset
            before = struct.unpack_from("<H", original, position)[0]
            after = struct.unpack_from("<H", image, position)[0]
            assert after == (before + load_segment) & 0xFFFF
        frontend = [(offset, segment) for offset, segment in relocations
                    if segment == MAIN_SEG and 0xA <= offset < 0xA + manifest["frontend_bytes"]]
        assert len(frontend) == 4
        assert [offset for offset, _ in frontend] == manifest["frontend_relocation_offsets"]
        for offset, segment in frontend:
            assert image[segment * 16 + offset - 3] == 0x9A
    print(json.dumps({"result": "PASS", "output_sha256": sha(supplied),
                      "checks": ["two deterministic rebuilds", "modified input rejected before output",
                                 "MZ extent and relocation bounds", "two DOS load segments",
                                 "four frontend far-call relocations",
                                 "original benchmark module and BIOS timer byte identity"]}, indent=2))


if __name__ == "__main__":
    main()
