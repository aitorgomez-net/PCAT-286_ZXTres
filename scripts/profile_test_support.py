#!/usr/bin/env python3
"""Shared source ordering and bounded subprocess helpers for CPU regressions."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CPU = ROOT / "vendor/spk286"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
    packages = ["microcode/generated/spk286_microcode_pkg.sv",
                "microcode/generated/spk286_microcode_rom.sv",
                "microcode/generated/spk286_microcode_sync_rom.sv",
                "rtl/spk286_protected_pkg.sv", "rtl/spk286_tss_pkg.sv"]
    paths = [CPU / p for p in packages]
    paths += [p for p in sorted((CPU / "rtl").glob("*.sv")) if p not in paths]
    return paths


def run(args, log, cwd=ROOT, timeout=300):
    result = subprocess.run([str(x) for x in args], cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    log.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stdout[-5000:]}")
    return result.stdout


def generic_stats(path):
    design = json.loads(path.read_text())
    modules = design["modules"]
    assert len(modules) == 1, "synthesis must flatten the measured component"
    module = next(iter(modules.values()))
    cells = module.get("cells", {})
    counts = {}
    registers = 0
    for cell in cells.values():
        kind = cell["type"]
        counts[kind] = counts.get(kind, 0) + 1
        if "DFF" in kind.upper():
            registers += len(cell["connections"]["Q"])
    return {"generic_cells": len(cells), "register_bits": registers,
            "cell_types": counts,
            "scope": "Yosys generic mapping; not Cyclone V ALMs, fit or STA"}
