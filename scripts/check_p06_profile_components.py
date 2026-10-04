#!/usr/bin/env python3
"""Focused general-profile elaboration, schedule oracle and isolated cost.

No Quartus, production fit or full regression is launched here. All simulator
and synthesis artifacts remain in the explicitly selected output directory.
"""
import argparse
import json
from pathlib import Path
from build_p06_profile_cpu import ROOT, build, sha
from run_p06_core_register import sources, run
from run_p06_pilot import generic_stats


def select(selected):
    paths = [p for p in sources() if p.name not in ("spk286.sv", "spk286_events.sv")]
    paths += [ROOT / "rtl/spk286_timing/spk286_instruction_timing.sv",
              ROOT / "rtl/spk286_timing/spk286_instruction_schedule.sv"]
    paths += list(selected.values())
    return paths


def prepare(out, selected):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    paths = select(selected)
    run(["verilator", "--lint-only", "--Wall", "--top-module", "spk286_profiled",
        "-I" + str(ROOT / "vendor/spk286/rtl"), *paths], out / "lint-profiled.log")
    print("PROFILE_FULL_CPU_STRICT_LINT_PASS", flush=True)
    policy = ROOT / "rtl/spk286_timing/spk286_instruction_schedule.sv"
    bench = ROOT / "sim/spk286_timing/spk286_instruction_schedule_tb.sv"
    binary = out / "schedule.vvp"
    run(["iverilog", "-g2012", "-s", "spk286_instruction_schedule_tb", "-o", binary,
         policy, bench], out / "schedule-iverilog-build.log")
    first = run(["vvp", binary], out / "schedule-iverilog-run.log")
    assert "PROFILE_SCHEDULE_PASS" in first
    obj = out / "schedule-verilator"
    run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal",
         "--top-module", "spk286_instruction_schedule_tb", "--Mdir", obj,
         policy, bench], out / "schedule-verilator-build.log", timeout=600)
    second = run([obj / "Vspk286_instruction_schedule_tb"], out / "schedule-verilator-run.log")
    assert first.split("PROFILE_SCHEDULE_PASS", 1)[1].splitlines()[0] == \
           second.split("PROFILE_SCHEDULE_PASS", 1)[1].splitlines()[0]
    print("PROFILE_SCHEDULE_DUAL_ORACLE_PASS", flush=True)
    prefix_bench = ROOT / "sim/spk286_timing/spk286_profile_prefix_tb.sv"
    prefix_binary = out / "prefix.vvp"
    include = "-I" + str(ROOT / "vendor/spk286/sim/unit")
    run(["iverilog", "-g2012", "-s", "spk286_profile_prefix_tb", include,
         "-o", prefix_binary, *paths, prefix_bench], out / "prefix-iverilog-build.log")
    prefix_first = run(["vvp", prefix_binary], out / "prefix-iverilog-run.log")
    assert "PROFILE_PREFIX_PASS cases8" in prefix_first
    prefix_obj = out / "prefix-verilator"
    run(["verilator", "--binary", "--timing", "--assert", "-Wno-fatal", include,
         "--top-module", "spk286_profile_prefix_tb", "--Mdir", prefix_obj,
         *paths, prefix_bench], out / "prefix-verilator-build.log", timeout=600)
    prefix_second = run([prefix_obj / "Vspk286_profile_prefix_tb"], out / "prefix-verilator-run.log")
    assert prefix_first.split("PROFILE_PREFIX_PASS", 1)[1].splitlines()[0] == \
           prefix_second.split("PROFILE_PREFIX_PASS", 1)[1].splitlines()[0]
    assert [v for v in prefix_first.splitlines() if v.startswith("PROFILE_PREFIX_CASE")] == \
           [v for v in prefix_second.splitlines() if v.startswith("PROFILE_PREFIX_CASE")]
    print("PROFILE_FULL_TOP_PREFIX_DUAL_ORACLE_PASS", flush=True)
    ys, net = out / "schedule-cost.ys", out / "schedule-cost.json"
    ys.write_text(f"read_verilog -sv {policy}\nsynth -top spk286_instruction_schedule -flatten\nwrite_json {net}\n")
    run(["yosys", "-Q", "-s", ys], out / "schedule-cost.log")
    receipt = {"status": "PROFILE_COMPONENT_PREPARATION_PASS_NOT_FULL_ACCEPTANCE",
        "sources_sha256": {str(p.relative_to(ROOT)): sha(p) for p in [Path(__file__), policy, bench, prefix_bench]},
        "generated_sha256": {name: sha(path) for name, path in selected.items()},
        "schedule_generic_cost": generic_stats(net),
        "scope": "Strict full-CPU lint, independent schedule oracle and passive full-TOP prefix budget oracle in two simulators, isolated generic schedule cost; compatibility/OSD/machine/FPGA acceptance separate"}
    (out / "components.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    selected = build(args.output / "candidate")
    print(json.dumps(prepare(args.output, selected), indent=2))
