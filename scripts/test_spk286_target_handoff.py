#!/usr/bin/env python3
"""Focused source-retained target-length deadline checks and isolated cost.

This does not claim whole-CPU event/fault/queue acceptance or FPGA ALM cost.
All generated data lives in one bounded build directory, with no copied PCH.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SCHEDULE = ROOT / "rtl/spk286_timing/spk286_instruction_schedule.sv"
HANDOFF = ROOT / "rtl/spk286_timing/spk286_target_handoff.sv"
REPLAY = ROOT / "rtl/spk286_timing/spk286_target_replay.sv"
BENCHES = [ROOT / "sim/spk286_timing/spk286_instruction_schedule_tb.sv",
           ROOT / "sim/spk286_timing/spk286_target_handoff_tb.sv",
           ROOT / "sim/spk286_timing/spk286_target_replay_tb.sv"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, timeout=300, check=True):
    result = subprocess.run([str(item) for item in command], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=timeout)
    log.write_text(result.stdout, newline="\n")
    if check and result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {log}")
    return result


def synthesize(out, top, inputs):
    script = out / f"{top}.ys"
    net = out / f"{top}.json"
    script.write_text("read_verilog -sv " + " ".join(map(str, inputs)) +
                      f"\nsynth -top {top} -flatten\nwrite_json {net}\n", newline="\n")
    run(["yosys", "-Q", "-s", script], out / f"{top}-yosys.log")
    design = json.loads(net.read_text())["modules"][top]
    cells = design["cells"]
    registers = sum(len(cell["connections"].get("Q", [])) for cell in cells.values()
                    if "DFF" in cell["type"].upper())
    return {"generic_cells": len(cells), "register_bits": registers,
            "memories": len(design.get("memories", {})),
            "scope": "isolated generic logic; not fitted FPGA ALMs"}


def negatives(out):
    checks = [
        ("missing-source-length", SCHEDULE,
         "{8'd0, target_length_clocks}", "12'd0"),
        ("premature-source-publication", SCHEDULE,
         "metadata_available && target_length_ready &&", "metadata_available &&"),
        ("fixed-target-penalty", HANDOFF,
         "length_q <= preview_fault ? 4'd0 : preview_length;",
         "length_q <= preview_fault ? 4'd0 : 4'd2;"),
        ("max-pending-leak", HANDOFF,
         "assign pending = historical_enable && pending_q;", "assign pending = pending_q;"),
        ("saturated-total-overflow", SCHEDULE,
         "logic [11:0]", "logic [10:0]"),
    ]
    results = {}
    for label, source, before, after in checks:
        directory = out / f"negative-{label}"
        directory.mkdir()
        original = source.read_text()
        expected = {"saturated-total-overflow": 3, "missing-source-length": 4}.get(label, 1)
        assert original.count(before) == expected, label
        mutated = directory / source.name
        mutated.write_text(original.replace(before, after), newline="\n")
        rtl = [mutated if item == source else item for item in [SCHEDULE, HANDOFF]]
        bench = BENCHES[0] if label == "saturated-total-overflow" else BENCHES[1]
        marker = "SCHEDULE_ORACLE_FAILED" if bench == BENCHES[0] else "HANDOFF_ORACLE_FAILED"
        run(["iverilog", "-g2012", "-s", bench.stem, "-o",
             directory / "test.vvp", *rtl, bench], directory / "build.log")
        result = run(["vvp", directory / "test.vvp"], directory / "run.log", check=False)
        assert result.returncode != 0 and marker in result.stdout, label
        results[label] = {"returncode": result.returncode, "marker": marker}
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    if not out.is_relative_to((ROOT / "build").resolve()):
        parser.error("output must be under build")
    out.mkdir(parents=True, exist_ok=False)
    inputs = [SCHEDULE, HANDOFF, REPLAY, *BENCHES, Path(__file__).resolve()]
    before = {p.relative_to(ROOT).as_posix(): sha(p) for p in inputs}
    results = {}
    for top, rtl, marker, bench in [
            ("spk286_instruction_schedule_tb", [SCHEDULE], "PROFILE_SCHEDULE_PASS", BENCHES[0]),
            ("spk286_target_handoff_tb", [SCHEDULE, HANDOFF], "TARGET_HANDOFF_PASS", BENCHES[1]),
            ("spk286_target_replay_tb", [REPLAY], "TARGET_REPLAY_PASS", BENCHES[2])]:
        directory = out / top
        directory.mkdir()
        # RTL-only strict lint: bench clock/blocking stimulus is intentionally
        # separate from production warnings.
        for source in rtl:
            run(["verilator", "--lint-only", "--Wall", "--top-module", source.stem, source],
                directory / f"{source.stem}-lint.log")
        run(["iverilog", "-g2012", "-s", top, "-o", directory / "test.vvp", *rtl, bench],
            directory / "iverilog-build.log")
        run(["verilator", "--binary", "--timing", "--assert", "-j", "2", "--top-module", top,
             "--Mdir", directory / "obj", "-o", "handoff-test", *rtl, bench],
            directory / "verilator-build.log", timeout=600)
        pass_lines = []
        for label, command in [("iverilog", ["vvp", directory / "test.vvp"]),
                               ("verilator", [directory / "obj/handoff-test"])]:
            result = run(command, directory / f"{label}-run.log")
            lines = [line for line in result.stdout.splitlines() if marker in line]
            assert len(lines) == 1, f"missing pass marker: {directory}/{label}"
            pass_lines.append(lines[0])
        assert pass_lines[0] == pass_lines[1], "dual simulator check counts differ"
        results[top] = {"status": "PASS", "marker": pass_lines[0]}

    # Generic before/after scheduler uses the immutable parent source. This
    # records a logic delta without producing or copying a whole CPU image.
    baseline = subprocess.run(["git", "show", "HEAD:rtl/spk286_timing/spk286_instruction_schedule.sv"],
                              cwd=ROOT, check=True, stdout=subprocess.PIPE).stdout
    baseline_path = out / "schedule-baseline.sv"
    baseline_path.write_bytes(baseline)
    baseline_out = out / "baseline-cost"
    baseline_out.mkdir()
    cost = {"handoff": synthesize(out, HANDOFF.stem, [HANDOFF]),
            "schedule": synthesize(out, SCHEDULE.stem, [SCHEDULE]),
            "schedule_before": synthesize(baseline_out, SCHEDULE.stem, [baseline_path])}
    cost["schedule_baseline_sha256"] = sha(baseline_path)
    assert before == {p.relative_to(ROOT).as_posix(): sha(p) for p in inputs}, "sources changed"
    receipt = {"status": "PASS", "scope": "source retained target-length controller/scheduler units",
               "checks": results, "source_sha256": before, "isolated_cost": cost,
               "negative": negatives(out),
               "excluded": ["whole CPU event/fault/queue acceptance", "FPGA fitted cost/timing"],
               "artifacts_sha256": {p.relative_to(out).as_posix(): sha(p)
                                    for p in sorted(out.rglob("*.log"))}}
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", newline="\n")
    print("TARGET_HANDOFF_DUAL_COST_PASS", flush=True)
    print(json.dumps(cost, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
