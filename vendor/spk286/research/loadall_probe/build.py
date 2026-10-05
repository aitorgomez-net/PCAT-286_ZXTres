"""Build the DOS LOADALL hardware probe and its reproducibility manifest."""

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def nasm_options(nasm: str) -> list[str]:
    options = ["-Wall", "-Werror"]
    help_text = subprocess.check_output([nasm, "-h"], text=True)
    if "reloc-abs-word" in help_text:
        options.append("-w-reloc-abs-word")
    return options


def build(output: Path, nasm: str) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    target = output / "LOADALL.COM"
    listing = output / "LOADALL.COM.lst"
    subprocess.run(
        [nasm, "-f", "bin", *nasm_options(nasm), "-l", str(listing),
         "-o", str(target), str(HERE / "loadall_probe.asm")],
        check=True,
    )
    payload = target.read_bytes()
    manifest = {
        "version": "0.1",
        "assembler": subprocess.check_output([nasm, "-v"], text=True).strip(),
        "program": target.name,
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "source_sha256": hashlib.sha256((HERE / "loadall_probe.asm").read_bytes()).hexdigest(),
        "scope": "80286 real-mode LOADALL opcode/cache/FLAGS probe; no protected-mode entry",
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/loadall-probe")
    parser.add_argument("--nasm", default=shutil.which("nasm") or "nasm")
    args = parser.parse_args()
    build(args.output, args.nasm)
