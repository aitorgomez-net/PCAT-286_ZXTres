"""Build a single DOS MZ executable from the supplied CheckIt 3.03C files.

Only this frontend/builder is maintained in the repository. The original input
files are read from the user's local installation and are never modified.
"""
import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

INPUT_HASHES = {
    "CHECKIT.EXE": "41e261db4393763ca632522f2e1c7a66e4ff7f52cc68ba05a582a894ffd02402",
    "CHECKIT.OVL": "ac9e11e77693500dd092dcf54bb68c7206ccd5cecc6a7130ae049f669b933be0",
}
TABLE = 0xE420
MAIN = 0x1DEA
MAIN_SEG = 0x1DE
DGROUP = 0x386E0
IMAGE_SIZE = 0x47C90


def sha(data):
    return hashlib.sha256(data).hexdigest()


def build(source, output, nasm="nasm"):
    inputs = {}
    for name, expected in INPUT_HASHES.items():
        data = (source / name).read_bytes()
        if sha(data) != expected:
            raise ValueError(f"Unsupported {name}: this builder requires the recorded 3.03C input")
        inputs[name] = data
    exe, ovl = inputs["CHECKIT.EXE"], inputs["CHECKIT.OVL"]
    image = bytearray(IMAGE_SIZE)
    image[:0xDA20] = exe[0x1000:0xEA20]
    relocations = [struct.unpack_from("<HH", exe, 0x1E + i * 4) for i in range(949)]
    modules = []

    # Phoenix overlay entries retain their original destinations. Module 19
    # contains both benchmarks; 32 contains resident library code and data.
    # Module 6 is the original resident overlay trampoline segment.
    for number in (6, 19, 32):
        entry = struct.unpack_from("<8H", exe, TABLE + (number - 1) * 16)
        following = struct.unpack_from("<8H", exe, TABLE + number * 16)
        src = exe if entry[7] == 0x208 else ovl
        reloc_start = following[0] * 16
        code_start = reloc_start + ((entry[4] + 3) // 4) * 16
        size = min(entry[6] - entry[5], following[2]) * 16
        destination = entry[5] * 16
        code = src[code_start:code_start + size]
        if len(code) != size or destination + size > len(image):
            raise ValueError("Invalid retained overlay extent")
        image[destination:destination + size] = code
        for index in range(entry[4]):
            off, seg = struct.unpack_from("<HH", src, reloc_start + index * 4)
            if off or seg:
                relocations.append((off, seg))
        modules.append({"number": number, "source": "CHECKIT.EXE" if src is exe else "CHECKIT.OVL",
                        "file_offset": code_start, "image_offset": destination,
                        "bytes": size, "sha256": sha(code)})

    assembler = Path(__file__).with_name("checknum.asm")
    with tempfile.TemporaryDirectory(prefix="checknum-") as temporary:
        binary = Path(temporary) / "frontend.bin"
        subprocess.run([nasm, "-f", "bin", str(assembler), "-o", str(binary)], check=True)
        assembled = binary.read_bytes()
    if assembled[-4:] != b"CKRL":
        raise ValueError("Missing frontend relocation footer")
    stub_size = struct.unpack_from("<H", assembled, len(assembled) - 6)[0]
    if stub_size + 14 != len(assembled) or stub_size > 0x200:
        raise ValueError("Invalid frontend size")
    stub = assembled[:stub_size]
    stub_relocs = struct.unpack_from("<4H", assembled, stub_size)
    for offset in stub_relocs:
        position = offset - 0xA
        if stub[position - 3] != 0x9A:
            raise ValueError("Frontend relocation does not address a far-call segment")
    relocations = [(off, seg) for off, seg in relocations
                   if not MAIN <= seg * 16 + off < MAIN + stub_size]
    relocations.extend((off, MAIN_SEG) for off in stub_relocs)
    patches = []

    def patch(address, replacement, reason, expected=None):
        original = bytes(image[address:address + len(replacement)])
        if expected is not None and original != expected:
            raise ValueError(f"Unexpected bytes at image offset {address:05X}")
        image[address:address + len(replacement)] = replacement
        patches.append({"image_offset": address, "original_hex": original.hex(),
                        "replacement_hex": replacement.hex(), "reason": reason})

    patch(MAIN, stub, "Numeric main frontend after original CRT initialization")
    patch(DGROUP + 0x6572, b"%.0f\r\n\0", "Original Dhrystone precision, numeric output only",
          b"%5.0f D")
    patch(DGROUP + 0x6583, b"%.1f\r\n\0", "Original Whetstone precision in thousands, numeric output only",
          b"%9.1fK ")
    for address in (0x6F80, 0x7050):
        patch(address, b"\x31\xC0\xCB", "Disable untimed GUI progress updates", b"\x55\x8B\xEC")
    patch(0x44E5, b"\x31\xC0\xCB", "Disable untimed GUI abort-dialog polling", b"\x55\x8B\xEC")
    patch(0x2D45E, b"\x31\xC0\xE9\x38\x00", "Always select original software FP, including hosts with an NPU",
          b"\xDB\xE3\x51\xB9\x14")

    benchmark = next(module for module in modules if module["number"] == 19)
    start, size = benchmark["image_offset"], benchmark["bytes"]
    assert sha(image[start:start + size]) == benchmark["sha256"], "Benchmark code changed"
    timer_start, timer_end = 0x6907, 0x6925
    assert image[timer_start:timer_end] == exe[0x1000 + timer_start:0x1000 + timer_end]
    relocations = sorted(set(relocations), key=lambda pair: pair[1] * 16 + pair[0])
    for off, seg in relocations:
        if seg * 16 + off + 2 > IMAGE_SIZE:
            raise ValueError("Relocation exceeds the DOS image")
    header_size = ((0x1C + len(relocations) * 4 + 15) // 16) * 16
    header = bytearray(header_size)
    length = header_size + IMAGE_SIZE
    # Entry is the original Microsoft CRT, bypassing the overlay loader.
    # Original SS:SP and the full allocated image extent preserve stack/BSS.
    struct.pack_into("<14H", header, 0, 0x5A4D, length % 512, (length + 511) // 512,
                     len(relocations), header_size // 16, 0, 0xFFFF,
                     0x45C9, 0x2000, 0, 0x22, 0x2691, 0x1C, 0)
    for index, pair in enumerate(relocations):
        struct.pack_into("<HH", header, 0x1C + index * 4, *pair)
    output.parent.mkdir(parents=True, exist_ok=True)
    result = header + image
    output.write_bytes(result)
    manifest = {"format": 1, "reference": "CheckIt 3.03C 04/08/91",
                "inputs": INPUT_HASHES, "frontend_sha256": sha(assembler.read_bytes()),
                "output": output.name, "output_bytes": len(result), "output_sha256": sha(result),
                "frontend_image_offset": MAIN, "frontend_bytes": stub_size,
                "frontend_relocation_offsets": list(stub_relocs),
                "retained_modules": modules, "relocations": len(relocations), "patches": patches,
                "timer_sha256": sha(image[timer_start:timer_end]),
                "output_lines": ["Dhrystones/second, zero decimals", "Thousands of Whetstones/second, one decimal"],
                "npu": "software FP forced", "external_runtime_files": []}
    output.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Directory containing the recorded CHECKIT.EXE and CHECKIT.OVL")
    parser.add_argument("output", type=Path, help="Destination DOS executable, normally CHECKNUM.EXE")
    parser.add_argument("--nasm", default="nasm", help="NASM executable")
    args = parser.parse_args()
    if shutil.which(args.nasm) is None:
        parser.error("NASM is required to assemble the numeric frontend")
    if args.output.resolve() in { (args.source / name).resolve() for name in INPUT_HASHES }:
        parser.error("Output must not replace an original CheckIt input")
    manifest = build(args.source.resolve(), args.output.resolve(), args.nasm)
    print(f"{args.output}: {manifest['output_bytes']} bytes; SHA256 {manifest['output_sha256']}")


if __name__ == "__main__":
    main()
