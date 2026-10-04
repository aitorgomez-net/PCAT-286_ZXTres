#!/usr/bin/env python3
"""Directed dual-simulator acceptance of the reset-applied CPU profile clock.

Run under WSL/Linux with Icarus, Verilator and Yosys installed. This qualifies
the selector and rational generator only, not full historical CPU timing.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/spk286_integration/spk286_at_cpu_profile.sv"
BENCH = ROOT / "sim/spk286_integration/spk286_at_cpu_profile_tb.sv"
TOP = "spk286_at_cpu_profile_tb"
PASS = "SPK286_AT_CPU_PROFILE_PASS"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, timeout=240, check=True):
    completed = subprocess.run([str(item) for item in command], cwd=ROOT,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, timeout=timeout)
    log.write_text(completed.stdout, newline="\n")
    if check and completed.returncode != 0:
        raise RuntimeError(f"command failed ({completed.returncode}); see {log}")
    return completed


def rows(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def validate_summary(path):
    data = rows(path)
    expected_counts = {0: 8, 1: 64, 2: 64, 3: 64, 4: 800, 5: 256, 6: 256}
    if len(data) != sum(expected_counts.values()):
        raise AssertionError("profile summary has an unexpected case count")
    increments = [0, 12, 16, 20, 25, 32, 40, 50]
    for index, row in enumerate(data, 1):
        if int(row["id"]) != index:
            raise AssertionError("profile summary IDs are not consecutive")
        profile = int(row["active"])
        start, edges = int(row["start_age"]), int(row["edges"])
        numerator = increments[profile]
        phase_count = ((start + edges) * numerator) // 50 - (start * numerator) // 50
        cpu_count = edges if profile == 0 else (
            ((start + edges) * numerator) // 100 - (start * numerator) // 100)
        if (int(row["phases"]), int(row["cpu_count"])) != (phase_count, cpu_count):
            raise AssertionError("independent Python window count failed")
    observed = {kind: sum(int(row["kind"]) == kind for row in data) for kind in expected_counts}
    if observed != expected_counts:
        raise AssertionError("profile summary coverage count failed")
    long_runs = data[:8]
    if [int(row["active"]) for row in long_runs] != list(range(8)):
        raise AssertionError("long-run coverage is incomplete")
    pairs = [(int(row["active"]), int(row["requested"]))
             for row in data if int(row["kind"]) == 2]
    if pairs != [(old, new) for old in range(8) for new in range(8)]:
        raise AssertionError("all reset-only profile transitions are not covered")
    return observed


def negative(out):
    original = RTL.read_text()
    changes = [
        ("wrong-12p5", "3'd4: phase_increment = 6'd25;",
         "3'd4: phase_increment = 6'd26;", "profile rational boundary oracle failed"),
        ("live-selection", "end else if (historical) begin",
         "end else if (historical) begin\n            active <= requested_normalized;",
         "profile reset-only selection oracle failed"),
        ("reset-phase", "active <= requested_normalized;\n            phase_accumulator_q <= 6'd0;\n            phase_parity_q <= 1'b0;",
         "active <= requested_normalized;\n            phase_accumulator_q <= 6'd1;\n            phase_parity_q <= 1'b1;",
         "profile rational boundary oracle failed"),
        ("unknown-selection", "default: requested_normalized = 3'd0;",
         "default: requested_normalized = requested;",
         "profile omitted request normalization oracle failed"),
    ]
    results = {}
    for label, old, new, marker in changes:
        if original.count(old) != 1:
            raise AssertionError(f"ambiguous mutation: {label}")
        source = out / f"negative-{label}.sv"
        source.write_text(original.replace(old, new), newline="\n")
        executable = out / f"negative-{label}.vvp"
        run(["iverilog", "-g2012", "-s", TOP, "-o", executable, source, BENCH],
            out / f"negative-{label}-build.log")
        result = run(["vvp", executable], out / f"negative-{label}-run.log", check=False)
        if result.returncode == 0 or marker not in result.stdout:
            raise AssertionError(f"negative {label} escaped its independent oracle")
        results[label] = {"returncode": result.returncode, "marker": marker}
    return results


def synthesize(out):
    net = out / "generic.json"
    script = out / "generic.ys"
    # These generic cells and register bits are not Quartus/FPGA ALMs.
    script.write_text(f"read_verilog -sv {RTL}\nsynth -top spk286_at_cpu_profile -flatten\n"
                      f"write_json {net}\n", newline="\n")
    run(["yosys", "-Q", "-s", script], out / "yosys.log")
    design = json.loads(net.read_text())["modules"]["spk286_at_cpu_profile"]
    cells = design["cells"]
    register_bits = sum(len(cell["connections"].get("Q", []))
                        for cell in cells.values() if "DFF" in cell["type"].upper())
    return {"generic_cells": len(cells), "register_bits": register_bits,
            "scope": "isolated selector/generator; not FPGA ALMs or full CPU"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    if not out.is_relative_to((ROOT / "build").resolve()):
        parser.error("--output must be a fresh directory under the workspace build directory")
    out.mkdir(parents=True, exist_ok=False)
    inputs = [RTL, BENCH, Path(__file__).resolve()]
    before = {path.relative_to(ROOT).as_posix(): sha(path) for path in inputs}
    versions = {}
    for tool, command in [("iverilog", ["iverilog", "-V"]),
                          ("verilator", ["verilator", "--version"]),
                          ("yosys", ["yosys", "-V"])]:
        versions[tool] = run(command, out / f"{tool}-version.log").stdout.splitlines()[0]
    run(["verilator", "--lint-only", "--Wall", "--top-module", "spk286_at_cpu_profile", RTL],
        out / "lint.log")
    run(["iverilog", "-g2012", "-s", TOP, "-o", out / "test.vvp", RTL, BENCH],
        out / "iverilog-build.log")
    run(["verilator", "--binary", "--timing", "--assert", "-j", "4", "--top-module", TOP,
         "--Mdir", out / "obj", "-o", "profile-test", RTL, BENCH],
        out / "verilator-build.log", timeout=600)
    markers = []
    for label, command in [("iverilog", ["vvp", out / "test.vvp"]),
                           ("verilator", [out / "obj/profile-test"])]:
        result = run([*command, f"+trace={out}/{label}-trace.csv",
                      f"+summary={out}/{label}-summary.csv"], out / f"{label}-run.log")
        found = [line for line in result.stdout.splitlines() if line.startswith(PASS)]
        if len(found) != 1:
            raise AssertionError(f"{label} did not emit exactly one PASS marker")
        markers.extend(found)
        validate_summary(out / f"{label}-summary.csv")
    if markers[0] != markers[1]:
        raise AssertionError("dual-simulator counters differ")
    for kind in ["trace", "summary"]:
        if (out / f"iverilog-{kind}.csv").read_bytes() != (out / f"verilator-{kind}.csv").read_bytes():
            raise AssertionError(f"dual-simulator {kind} differs")
    run(["iverilog", "-g2012", "-DPROFILE_FOUR_STATE", "-s", TOP, "-o", out / "four-state.vvp", RTL, BENCH],
        out / "four-state-build.log")
    fourstate = run(["vvp", out / "four-state.vvp", "+fourstate=1"], out / "four-state-run.log")
    fourstate_marker = "SPK286_AT_CPU_PROFILE_FOUR_STATE_PASS cases=8 unknown_encodings=4 omitted=1"
    if fourstate_marker not in fourstate.stdout:
        raise AssertionError("four-state request normalization coverage failed")
    receipt = {"status": "PASS", "scope": "reset-applied selector and rational enables only",
               "source_sha256": before, "tools": versions, "pass": markers[0],
               "cases": 1512, "coverage": validate_summary(out / "iverilog-summary.csv"),
               "four_state_cases": 8, "four_state_pass": fourstate_marker,
               "negative": negative(out), "isolated_cost": synthesize(out),
               "artifacts_sha256": {name: sha(out / name) for name in
                   ["iverilog-trace.csv", "verilator-trace.csv", "iverilog-summary.csv", "verilator-summary.csv"]}}
    after = {path.relative_to(ROOT).as_posix(): sha(path) for path in inputs}
    if before != after:
        raise AssertionError("selector sources changed during acceptance")
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", newline="\n")
    print(markers[0], flush=True)
    print("SPK286_AT_CPU_PROFILE_DUAL_NEGATIVE_COST_PASS", flush=True)


if __name__ == "__main__":
    main()
