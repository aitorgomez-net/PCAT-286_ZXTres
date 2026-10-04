#!/usr/bin/env python3
"""Build the fixed-work DOS timing reference with NASM, reproducibly."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--nasm", default="nasm")
    args = parser.parse_args()
    source = Path(__file__).resolve().with_name("t286ref.asm")
    root = source.parents[2]
    output = (args.output or root / "build/p06-timing-reference-20261003").resolve()
    output.mkdir(parents=True, exist_ok=True)
    binary = output / "T286REF.COM"
    listing = output / "T286REF.lst"
    command = [args.nasm, "-f", "bin", "-Wall", "-Werror", "-l", str(listing),
               "-o", str(binary), str(source)]
    result = subprocess.run(command, check=True, text=True, capture_output=True)
    version = subprocess.run([args.nasm, "-v"], check=True, text=True,
                             capture_output=True).stdout.strip()
    second = output / "T286REF.repro.COM"
    subprocess.run([args.nasm, "-f", "bin", "-Wall", "-Werror", "-o",
                    str(second), str(source)], check=True, text=True, capture_output=True)
    if binary.read_bytes() != second.read_bytes():
        raise SystemExit("NASM build is not byte reproducible")
    second.unlink()
    if not 0 < binary.stat().st_size < 0xFF00:
        raise SystemExit("Invalid DOS COM size")
    receipt = {
        "status": "T286REF_REPRODUCIBLE_BUILD_PASS",
        "assembler": version,
        "instruction_set_guard": "NASM cpu 8086; bits 16; org 0x100",
        "runtime_status": "NOT_RUN_BY_BUILDER",
        "command": command,
        "stdout": result.stdout,
        "stderr": result.stderr,
        "sources": {source.name: digest(source), Path(__file__).name: digest(Path(__file__))},
        "outputs": {binary.name: {"sha256": digest(binary), "bytes": binary.stat().st_size},
                    listing.name: {"sha256": digest(listing), "bytes": listing.stat().st_size}},
        "fixed_work": {"cases": ["R0", "B0", "M0"], "loops": 256, "repetitions": 7,
                       "kinds": ["baseline", "gross"]},
    }
    (output / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
