#!/usr/bin/env python3
"""Directed host check of T286REF's conditional 65536 PIT phase arithmetic.

This does not execute DOS instructions or certify a real PIT reload/crystal.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def phase(count: int, out: int, mode: int) -> int:
    value = (-count) & 0xFFFF
    return (value >> 1) + (0 if out else 32768) if mode == 3 else value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    source = Path(__file__).with_name("t286ref.asm")
    source_text = source.read_text(encoding="utf-8")
    assert "cpu 8086\n" in source_text and "bits 16\n" in source_text
    assert "mov al, 0c2h\n    out 43h, al" in source_text
    # A single read-back OUT is the only I/O write in this program.
    io_writes = [line.strip() for line in source_text.splitlines()
                 if line.strip().startswith("out ")]
    assert io_writes == ["out 43h, al"]
    checked = 0
    for mode in (2, 3):
        for tick in range(65536):
            if mode == 3:
                count = (-2 * (tick % 32768)) & 0xFFFF
                out = int(tick < 32768)
            else:
                count = (-tick) & 0xFFFF
                out = int(tick != 65535)
            assert phase(count, out, mode) == tick
            checked += 1
    # Check every admitted start phase at a few kernel/window endpoints.
    deltas = (0, 1, 127, 255, 256, 2048, 9999, 10000)
    windows = 0
    for start in range(8192, 16384):
        for delta in deltas:
            end = start + delta
            assert end < 32768 and end - start <= 10000
            count0 = (-2 * start) & 0xFFFF
            count1 = (-2 * end) & 0xFFFF
            assert phase(count1, 1, 3) - phase(count0, 1, 3) == delta
            assert ((count0 - count1) & 0xFFFF) == 2 * delta
            windows += 1
    # Actual bad controls must differ: using raw mode3 delta as ticks, or
    # dropping the low-OUT half-period term. These are mathematical negatives,
    # not assertions of an assembled executable or hardware failure.
    start, end = 8192, 9000
    raw = (((-2 * start) & 0xFFFF) - ((-2 * end) & 0xFFFF)) & 0xFFFF
    assert raw != end - start
    assert (((-((-2 * 40000) & 0xFFFF)) & 0xFFFF) >> 1) != 40000
    receipt = {
        "status": "T286REF_HOST_MATH_PASS",
        "scope": "Conditional divisor65536 phase arithmetic and exact source I/O guard only",
        "not_proved": ["DOS executable semantics", "real programmed reload", "PIT input frequency",
                       "absence of full-period CPU stalls", "physical CPU or pin timing"],
        "phase_states_checked": checked,
        "safe_window_endpoint_checks": windows,
        "negative_controls_rejected": ["raw mode3 delta used as ticks", "mode3 low-OUT term omitted"],
        "asm_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "tool_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    output = args.output or source.parents[2] / "build/p06-timing-reference-20261003"
    output.mkdir(parents=True, exist_ok=True)
    (output / "host-math-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
