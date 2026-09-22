"""Check observer accounting and counterfactual results; emit reproducible JSON."""
import argparse
import hashlib
import json
from pathlib import Path
import re

WORKLOADS = ("dhrystone", "whetstone", "working_set", "dhrystone21")
ROOT = Path(__file__).resolve().parents[1]


def fields(line):
    return dict(item.split("=", 1) for item in line.split()[1:])


def read_run(path):
    records = {}
    for line in path.read_text().splitlines():
        if line.startswith(("PROFILE_", "CHECKIT_DIRECTED_PASS ")):
            records.setdefault(line.split()[0], []).append(fields(line))
    for tag in ("CHECKIT_DIRECTED_PASS", "PROFILE_ACCOUNTING_PASS", "PROFILE_SIGNATURE"):
        assert len(records.get(tag, [])) == 1, (path, tag)
    result = records["CHECKIT_DIRECTED_PASS"][0]
    signature = records["PROFILE_SIGNATURE"][0]
    cpu = {row["bucket"]: {key: int(value) for key, value in row.items() if key != "bucket"}
           for row in records["PROFILE_CPU"]}
    assert sum(row["cycles"] for row in cpu.values()) == int(result["cycles"])
    assert sum(row["bus_wait_overlap"] for row in cpu.values()) == int(result["external_wait"])
    latency = {}
    for row in records["PROFILE_LATENCY"]:
        values = {key: int(value) for key, value in row.items() if key != "kind"}
        assert values["total"] == values["front"] + values["backend"] + values["return"]
        values["mean_wait_clocks"] = values["total"] / values["count"] if values["count"] else None
        latency[row["kind"]] = values
    assert sum(row["count"] for row in latency.values()) == int(result["reads"]) + int(result["writes"])
    # Not all queued speculative code reads need finish before HLT. Keep the
    # final partial transaction outside the completed-transaction histogram.
    completed_waits = sum(row["total"] for row in latency.values())
    assert completed_waits <= int(result["external_wait"])
    miscellaneous = {key: int(value) for key, value in records["PROFILE_MISC"][0].items()}
    assert miscellaneous["code_transfers"] == sum(latency[k]["count"] for k in
                                                     ("code_hit", "code_miss", "code_bypass"))
    assert miscellaneous["data_admission"] + miscellaneous["data_response"] == cpu["operand_service"]["cycles"]
    return {
        "log": str(path), "log_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "result": {key: value if key == "workload" else int(value) for key, value in result.items()},
        "signature": signature, "cpu": cpu, "latency": latency,
        "bus_phases": records["PROFILE_BUS"], "owner": records["PROFILE_OWNER"],
        "misc": miscellaneous, "data_cache": records["PROFILE_DATA_CACHE"][0],
        "opcodes": records["PROFILE_OPCODE"], "microcode": records["PROFILE_MICRO"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_dir", type=Path)
    parser.add_argument("--reference-build-dir", type=Path)
    args = parser.parse_args()
    build = args.build_dir.resolve()
    source_lines = {}
    for line in (ROOT / "vendor/spk286/microcode/generated/spk286_microcode.lst").read_text().splitlines():
        match = re.match(r"([0-9A-F]{4})\s+[0-9A-F]+\s+(.*)  # (.*)", line)
        if match:
            source_lines[int(match[1], 16)] = {"operation": match[2], "source": match[3]}
    rows = []
    for workload in WORKLOADS:
        baselines = {}
        for p03 in (0, 1):
            run = read_run(build / f"{workload}-p03-{p03}.log")
            assert run["signature"]["ideal_owner"] == "0"
            if args.reference_build_dir:
                old_lines = (args.reference_build_dir / f"{workload}-p03-{p03}.log").read_text().splitlines()
                old = [fields(line) for line in old_lines if line.startswith("CHECKIT_DIRECTED_PASS ")]
                assert len(old) == 1
                assert old[0] == {key: str(value) for key, value in run["result"].items()}, workload
            for item in run["microcode"]:
                item.update(source_lines[int(item["pc"])])
            baselines[p03] = run
            rows.append(run)
        assert baselines[0]["signature"] == baselines[1]["signature"], workload
        physical = baselines[1]
        experiments = {}
        for mode in (1, 2, 3, 4, 5, 6):
            run = read_run(build / f"ideal-owner-{mode}/{workload}-p03-1.log")
            assert int(run["signature"]["ideal_owner"]) == mode
            for key in ("gpr", "flags", "memory"):
                assert run["signature"][key] == physical["signature"][key], (workload, mode, key)
            for key in ("retired", "writes"):
                assert run["result"][key] == physical["result"][key], (workload, mode, key)
            assert run["misc"]["fast_register_ops"] == physical["misc"]["fast_register_ops"]
            run["speedup_vs_physical"] = physical["result"]["cycles"] / run["result"]["cycles"]
            experiments[mode] = run
            rows.append(run)
        cycles = physical["result"]["cycles"]
        code = physical["cpu"]["opcode_starved"]["cycles"] + physical["cpu"]["instruction_byte_starved"]["cycles"]
        print(f"PROFILE_RESULT {workload}: operand={100*physical['cpu']['operand_service']['cycles']/cycles:.2f}% "
              f"code={100*code/cycles:.2f}% internal={100*physical['cpu']['internal_microcode']['cycles']/cycles:.2f}% "
              f"ideal_all={experiments[1]['speedup_vs_physical']:.3f}x ideal_code={experiments[2]['speedup_vs_physical']:.3f}x "
              f"ideal_data={experiments[3]['speedup_vs_physical']:.3f}x "
              f"ideal_read={experiments[4]['speedup_vs_physical']:.3f}x ideal_write={experiments[5]['speedup_vs_physical']:.3f}x "
              f"data_cache_1k={experiments[6]['speedup_vs_physical']:.3f}x")
    sources = ["sim/spk286_integration/spk286_checkit_workload_tb.sv",
               "sim/spk286_integration/spk286_checkit_profile.svh",
               "sim/spk286_integration/spk286_checkit_ideal_owner.svh",
               "scripts/test_checkit_directed.sh", "scripts/test_checkit_profile.sh",
               "scripts/report_checkit_profile.py", "scripts/at_performance_flags.sh"]
    macro_file = build / "performance-macros.txt"
    report = {"clock_mhz": 50, "note": "Synthetic directed firmware, not DOS CheckIt. Ideal owner is a counterfactual, not production RTL.",
              "performance_macros": macro_file.read_text().split() if macro_file.exists() else None,
              "source_sha256": {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources},
              "reference_build_verified": str(args.reference_build_dir) if args.reference_build_dir else None,
              "runs": rows}
    (build / "profile.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"CHECKIT_PROFILE_PASS runs={len(rows)} signatures_and_accounting=PASS report={build/'profile.json'}")


if __name__ == "__main__":
    main()
