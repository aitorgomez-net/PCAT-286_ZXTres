"""Check physical PCAT RAM-buffer A/B runs and record cycles/state equality."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

WORKLOADS = ("dhrystone", "whetstone", "working_set", "dhrystone21")


def read_log(path):
    rows = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        tag, *fields = line.split()
        if tag in ("CHECKIT_DIRECTED_PASS", "PROFILE_SIGNATURE", "PROFILE_ACCOUNTING_PASS", "RAM_BUFFER_RESULT"):
            assert tag not in rows, (path, tag)
            rows[tag] = dict(field.split("=", 1) for field in fields)
        elif tag == "PROFILE_LATENCY":
            values = dict(field.split("=", 1) for field in fields)
            kind = values.pop("kind")
            rows.setdefault("latency", {})[kind] = {key: int(value) for key, value in values.items()}
    assert all(tag in rows for tag in ("CHECKIT_DIRECTED_PASS", "PROFILE_SIGNATURE", "PROFILE_ACCOUNTING_PASS", "RAM_BUFFER_RESULT")), path
    assert rows["PROFILE_SIGNATURE"]["ideal_owner"] == "0", path
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_dir", type=Path)
    args = parser.parse_args()
    build = args.build_dir.resolve()
    root = Path(__file__).resolve().parents[1]
    comparisons = []
    for name in WORKLOADS:
        off_path, on_path = build/f"{name}-data-off.log", build/f"{name}-p03-1.log"
        off, on = read_log(off_path), read_log(on_path)
        assert off["RAM_BUFFER_RESULT"]["enabled"] == "0"
        assert on["RAM_BUFFER_RESULT"]["enabled"] == "1"
        for key in ("gpr", "flags", "memory"):
            assert off["PROFILE_SIGNATURE"][key] == on["PROFILE_SIGNATURE"][key], (name, key)
        for key in ("retired", "writes"):
            assert off["CHECKIT_DIRECTED_PASS"][key] == on["CHECKIT_DIRECTED_PASS"][key], (name, key)
        baseline, candidate = int(off["CHECKIT_DIRECTED_PASS"]["cycles"]), int(on["CHECKIT_DIRECTED_PASS"]["cycles"])
        assert candidate < baseline, name
        assert int(on["RAM_BUFFER_RESULT"]["hits"]) > 0
        assert int(on["CHECKIT_DIRECTED_PASS"]["sdram_reads"]) < int(off["CHECKIT_DIRECTED_PASS"]["sdram_reads"])
        entry = {"workload": name, "baseline": off, "candidate": on,
                 "throughput_gain_percent": 100*(baseline/candidate-1),
                 "fewer_cycles_percent": 100*(1-candidate/baseline),
                 "architectural_signature_and_retirement_write_counts_match": True,
                 "logs_sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (off_path, on_path)}}
        comparisons.append(entry)
        print(f"RAM_BUFFER_PERF_PASS {name}: off={baseline} on={candidate} gain={entry['throughput_gain_percent']:.2f}%", flush=True)
    result = {"scope": "Four synthetic firmware kernels, physical SDRAM with refresh, no DMA/HPS/IRQ contention.",
              "clock_mhz": 50, "code_buffer_bytes": 512, "data_buffer_bytes": 1024,
              "performance_macros": (build/"performance-macros.txt").read_text().split(),
              "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
              "compiled_sources_sha256": hashlib.sha256((build/"compiled-sources.sha256").read_bytes()).hexdigest(),
              "runs": comparisons}
    (build/"ram-buffer-comparison.json").write_text(json.dumps(result, indent=2)+"\n")
    print("RAM_BUFFER_COMPARISON_PASS signatures=4 gains=4", flush=True)


if __name__ == "__main__":
    main()
