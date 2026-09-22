"""Validate architectural equivalence for the three physical bus configurations."""
import argparse
import hashlib
import json
from pathlib import Path

from report_checkit_profile import read_run, ROOT, WORKLOADS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_dir", type=Path)
    args = parser.parse_args()
    build = args.build_dir.resolve()
    expected = {
        "baseline": {"SPK286_P05_PARALLEL_LIMIT_CHECK"},
        "p01-p02": {"SPK286_P05_PARALLEL_LIMIT_CHECK", "SPK286_P01_FAST_MEMORY_START", "SPK286_P02_FETCH_CHAIN"},
        "candidate": {"SPK286_P05_PARALLEL_LIMIT_CHECK", "SPK286_P01_FAST_MEMORY_START", "SPK286_P02_FETCH_CHAIN", "SPK286_P06_EARLY_MEMORY_ADDRESS"},
    }
    for name, macros in expected.items():
        assert set((build/name/"performance-macros.txt").read_text().split()) == macros, name
    rows = []
    for workload in WORKLOADS:
        for p03 in (0, 1):
            runs = {name: read_run(build/name/f"{workload}-p03-{p03}.log") for name in expected}
            before, intermediate, after = (runs[name] for name in expected)
            assert before["signature"]["ideal_owner"] == "0"
            for run in (intermediate, after):
                assert run["signature"] == before["signature"], (workload, p03, "state")
                for key in ("retired", "writes", "sdram_writes"):
                    assert run["result"][key] == before["result"][key], (workload, p03, key)
                assert run["misc"]["fast_register_ops"] == before["misc"]["fast_register_ops"]
            assert after["result"]["cycles"] < intermediate["result"]["cycles"] < before["result"]["cycles"]
            # The faster bridge must not reduce physical owner service time.
            for kind in ("code_miss", "data_read", "data_write"):
                a, b = before["latency"][kind], after["latency"][kind]
                if a["count"]:
                    assert a["backend"] * b["count"] == b["backend"] * a["count"], (workload, p03, kind)
            ratio = before["result"]["cycles"] / after["result"]["cycles"]
            rows.append(dict(workload=workload, p03=p03,
                cycles={name:run["result"]["cycles"] for name,run in runs.items()},
                speedup=ratio, fewer_cycles_percent=100*(1-1/ratio),
                speedup_over_p01_p02=intermediate["result"]["cycles"]/after["result"]["cycles"],
                signatures=after["signature"], retired=after["result"]["retired"], writes=after["result"]["writes"],
                latency={name:run["latency"] for name,run in runs.items()},
                log_sha256={name:run["log_sha256"] for name,run in runs.items()}))
            if p03:
                print(f"AT_BUS_LATENCY_RESULT workload={workload} speedup={ratio:.4f}x "
                      f"cycles={before['result']['cycles']}->{after['result']['cycles']}")
    sources = ["config.tcl", "rtl/spk286_integration/spk286_at_bus_bridge.sv",
               "vendor/spk286/rtl/spk286_fetch.sv", "scripts/at_performance_flags.sh",
               "scripts/test_checkit_directed.sh", "scripts/report_at_bus_latency.py",
               "sim/spk286_integration/spk286_checkit_workload_tb.sv"]
    result = dict(clock_mhz=50, ideal_owner=False,
        note="Synthetic firmware, not DOS CheckIt. Baseline uses the actual old RBF configuration (P05 only); candidate enables P01/P02/P06.",
        macros={name:sorted(value) for name,value in expected.items()},
        source_sha256={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources}, rows=rows)
    target = build/"comparison.json"
    target.write_text(json.dumps(result, indent=2)+"\n")
    print(f"AT_BUS_LATENCY_COMPARISON_PASS runs=24 state_and_memory=identical report={target}")


if __name__ == "__main__":
    main()
