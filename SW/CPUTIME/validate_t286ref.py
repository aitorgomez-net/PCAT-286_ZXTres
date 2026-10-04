#!/usr/bin/env python3
"""Validate a complete T286REF2 raw fixed-work CSV; never certify PIT timing."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


VALIDATOR_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
CASES = ("R0", "B0", "M0")
KINDS = ("baseline", "gross")
LOOPS = 256
REPETITIONS = 7
WINDOW_LOW = 8192
WINDOW_HIGH = 16384
MAX_TICKS = 10000
SAMPLE_FIELDS = (
    "case", "kind", "rep", "loops", "status_start", "count_start", "out_start",
    "phase_start", "status_end", "count_end", "out_end", "phase_end",
    "raw_delta", "ticks", "result_ax", "result_bx", "result_cx", "result_dx",
    "result_di",
)
SUMMARY_FIELDS = ("case", "kind", "loops", "min_ticks", "median_ticks", "max_ticks")
FIXED_METADATA = {
    "version": "T286REF2",
    "cpu_contract": "REAL_MODE_8086_INSTRUCTIONS_286_TARGET",
    "timer_qualification": "NOT_CALIBRATED",
    "timer_divisor": "65536",
    "divisor_source": "ASSUMED_STANDARD_BIOS",
    "pit_input_hz": "1193182_NOMINAL",
    "interrupt_policy": "IF_PRESERVED_SHORT_CLI_NO_IRQ_TIMING_CLAIM",
    "window_phase_min": "8192",
    "window_phase_max_exclusive": "16384",
    "max_sample_ticks": "10000",
    "repetitions": "7",
}
VARIABLE_METADATA = {
    "nominal_mhz", "code_segment_decimal", "aligned_word_offset_decimal",
    "pit_mode", "pit_status_without_out", "probe_max_raw_count",
    "probe_observed_raw_zero",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def unsigned(value: str, maximum: int, name: str) -> int:
    require(re.fullmatch(r"0|[1-9][0-9]*", value) is not None,
            f"{name}: expected canonical unsigned decimal")
    number = int(value)
    require(number <= maximum, f"{name}: out of range 0..{maximum}")
    return number


def phase(count: int, output: int, mode: int) -> int:
    # Conditional on the stated, unproved even reload divisor 65536.
    elapsed = (-count) & 0xFFFF
    return elapsed if mode == 2 else elapsed // 2 + (0 if output else 32768)


def validate_csv(text: str, expected_nominal: str | None = None) -> dict:
    """Return a raw-validation receipt or raise ValueError on any failed check.

    Nominal MHz is metadata only. The PIT divisor/crystal and complete-period
    stalls remain unproved even when every arithmetic/functional check passes.
    """
    require(isinstance(text, str), "CSV must be decoded text")
    require(0 < len(text) <= 65536, "CSV is empty or exceeds the bounded format")
    require(text.endswith("\n"), "CSV is truncated: final newline is missing")
    require(all(c in "\r\n" or 32 <= ord(c) < 127 for c in text),
            "CSV contains unsupported control/non-ASCII characters")
    metadata, samples, summaries = {}, {}, {}
    headers = set()
    result_count = 0
    body_started = False
    for line_number, line in enumerate(text.splitlines(), 1):
        fields = line.split(",")
        kind = fields[0]
        context = f"line {line_number}"
        require(bool(line), f"{context}: empty row")
        require(result_count == 0, f"{context}: rows after terminal result")
        if kind == "meta":
            require(not body_started and len(fields) == 3, f"{context}: invalid metadata row")
            name, value = fields[1:]
            require(name in FIXED_METADATA or name in VARIABLE_METADATA,
                    f"{context}: unknown metadata {name}")
            require(name not in metadata, f"{context}: duplicate metadata {name}")
            metadata[name] = value
        elif kind in ("header_sample", "header_summary"):
            body_started = True
            wanted = SAMPLE_FIELDS if kind == "header_sample" else SUMMARY_FIELDS
            require(tuple(fields[1:]) == wanted, f"{context}: wrong {kind} schema")
            require(kind not in headers and not samples and not summaries,
                    f"{context}: duplicate/late header")
            headers.add(kind)
        elif kind in ("sample", "summary"):
            body_started = True
            require(headers == {"header_sample", "header_summary"}, f"{context}: missing headers")
            wanted = SAMPLE_FIELDS if kind == "sample" else SUMMARY_FIELDS
            require(len(fields) == len(wanted) + 1, f"{context}: wrong field count")
            record = dict(zip(wanted, fields[1:]))
            require(record["case"] in CASES and record["kind"] in KINDS,
                    f"{context}: unknown case/kind")
            for name in wanted[2:]:
                record[name] = unsigned(record[name], 65535, f"{context} {name}")
            require(record["loops"] == LOOPS, f"{context}: work count differs")
            key = (record["case"], record["kind"])
            if kind == "sample":
                require(1 <= record["rep"] <= REPETITIONS, f"{context}: invalid repetition")
                key += (record["rep"],)
                require(key not in samples, f"{context}: duplicate sample {key}")
                samples[key] = record
            else:
                require(key not in summaries, f"{context}: duplicate summary {key}")
                summaries[key] = record
        elif kind == "result":
            require(fields == ["result", "PASS_RAW_FIXED_WORK"],
                    f"{context}: missing/rejected/truncated raw PASS result")
            result_count += 1
        else:
            raise ValueError(f"{context}: unknown row type {kind}")

    require(result_count == 1, "Exactly one terminal PASS_RAW_FIXED_WORK is required")
    require(set(metadata) == set(FIXED_METADATA) | VARIABLE_METADATA,
            "Missing metadata fields")
    for name, value in FIXED_METADATA.items():
        require(metadata[name] == value, f"Wrong metadata {name}")
    nominal = metadata["nominal_mhz"]
    require(1 <= len(nominal) <= 16 and "$" not in nominal and " " not in nominal,
            "Invalid nominal frequency label")
    if expected_nominal is not None:
        require(nominal == expected_nominal, "Nominal metadata differs from requested reference")
    unsigned(metadata["code_segment_decimal"], 65535, "code segment")
    offset = unsigned(metadata["aligned_word_offset_decimal"], 65528, "RAM offset")
    require(offset % 16 == 0, "Four-word RAM fixture is not 16-byte aligned")
    mode = unsigned(metadata["pit_mode"], 3, "PIT mode")
    require(mode in (2, 3), "Only PIT modes 2/3 are supported")
    base_status = unsigned(metadata["pit_status_without_out"], 127, "PIT status")
    require((base_status & 0x71) == 0x30 and ((base_status >> 1) & 3) == mode,
            "PIT status is not stable binary LSB/MSB mode 2/3 with a loaded count")
    probe_max = unsigned(metadata["probe_max_raw_count"], 65535, "PIT probe maximum")
    probe_zero = unsigned(metadata["probe_observed_raw_zero"], 1, "PIT probe zero")
    require(probe_zero == 1 or probe_max >= 0xFF00, "PIT compatibility probe is insufficient")
    require(mode != 3 or probe_max % 2 == 0, "Mode 3 probe count must be even")

    expected_keys = {(c, k, r) for c in CASES for k in KINDS for r in range(1, REPETITIONS + 1)}
    require(set(samples) == expected_keys, "Expected exactly 42 unique samples (3 cases x 2 kinds x 7)")
    require(set(summaries) == {(c, k) for c in CASES for k in KINDS},
            "Expected exactly six summaries")
    for key, sample in samples.items():
        for suffix in ("start", "end"):
            status = sample[f"status_{suffix}"]
            output = sample[f"out_{suffix}"]
            count = sample[f"count_{suffix}"]
            require(status <= 255 and output in (0, 1), f"{key}: invalid status/OUT")
            require((status & 0x7F) == base_status and (status >> 7) == output,
                    f"{key}: status/OUT disagree or status changed")
            require(mode != 3 or count % 2 == 0, f"{key}: mode 3 count is odd")
            require(sample[f"phase_{suffix}"] == phase(count, output, mode),
                    f"{key}: incorrect conditional phase")
            require(output == 1, f"{key}: OUT low is outside the accepted sample window")
        start, end = sample["phase_start"], sample["phase_end"]
        require(WINDOW_LOW <= start < WINDOW_HIGH, f"{key}: start outside window")
        require(0 < end - start <= MAX_TICKS, f"{key}: zero/backwards/overlong interval")
        require(sample["ticks"] == end - start, f"{key}: tick delta differs")
        require(sample["raw_delta"] == ((sample["count_start"] - sample["count_end"]) & 0xFFFF),
                f"{key}: raw counter delta differs")
        expected_ax, expected_bx = 0x1234, 0x5678
        if sample["kind"] == "gross":
            if sample["case"] == "R0":
                expected_ax, expected_bx = 0x09B4, 0x5778
            elif sample["case"] == "M0":
                expected_ax = 0x68AC
        expected_registers = (expected_ax, expected_bx, 0, 0x9ABC, 0xDEF0)
        require(tuple(sample[f"result_{n}"] for n in ("ax", "bx", "cx", "dx", "di"))
                == expected_registers, f"{key}: functional register signature differs")
    for key, summary in summaries.items():
        values = sorted(samples[key + (r,)]["ticks"] for r in range(1, REPETITIONS + 1))
        require((summary["min_ticks"], summary["median_ticks"], summary["max_ticks"])
                == (values[0], values[3], values[6]), f"{key}: summary differs from raw samples")
    return {
        "status": "T286REF_RAW_FIXED_WORK_VALIDATION_PASS",
        "timer_calibrated": False,
        "csv_sha256": hashlib.sha256(text.encode("ascii")).hexdigest(),
        "validator_sha256": VALIDATOR_SHA256,
        "metadata": metadata,
        "sample_count": len(samples),
        "summary_count": len(summaries),
        "controls": {name: True for name in (
            "complete_schema", "fixed_work_256", "seven_unique_repetitions",
            "uncalibrated_assumption_explicit", "mode_status_out_consistent",
            "conditional_phase_arithmetic", "positive_bounded_interval",
            "raw_delta_arithmetic", "register_signatures", "summaries_recomputed",
        )},
        "samples": [samples[k] for k in sorted(samples)],
        "summaries": [summaries[k] for k in sorted(summaries)],
        "limits": ["reload_divisor_assumed", "pit_crystal_not_measured",
                   "whole_period_stalls_not_excluded", "no_cpu_cycle_or_pin_accuracy_claim"],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    parser.add_argument("--expected-nominal")
    parser.add_argument("--output", type=Path, help="Optional JSON receipt path")
    args = parser.parse_args()
    if args.output and args.output.resolve() == args.csv.resolve():
        parser.error("The JSON output must not replace its input CSV")
    try:
        data = args.csv.read_bytes()
        receipt = validate_csv(data.decode("ascii"), args.expected_nominal)
    except (OSError, UnicodeError, ValueError) as error:
        print(json.dumps({"status": "T286REF_VALIDATION_REJECT", "error": str(error)}), file=sys.stderr)
        raise SystemExit(1)
    receipt["csv_path"] = str(args.csv.resolve())
    rendered = json.dumps(receipt, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")


if __name__ == "__main__":
    main()
