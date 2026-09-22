"""Validate a physical-SDRAM code-buffer experiment and record its measurements."""
import argparse
import hashlib
import json
from pathlib import Path

from report_checkit_profile import WORKLOADS, fields, read_run

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compact(run, root):
    return {
        "log": str(Path(run["log"]).relative_to(root)),
        "log_sha256": run["log_sha256"],
        "result": run["result"], "signature": run["signature"],
        "cpu": run["cpu"], "latency": run["latency"], "misc": run["misc"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_dir", type=Path)
    args = parser.parse_args()
    build = args.build_dir.resolve()
    source_hashes = {}
    for line in (build / "source.sha256").read_text().splitlines():
        expected, path = line.split("  ", 1)
        assert digest(ROOT / path) == expected, f"Compiled input changed: {path}"
        source_hashes[path] = expected
    assert (build / "performance-macros.txt").read_bytes() == (
        build / "reference/performance-macros.txt").read_bytes()

    references = {
        (workload, enabled): read_run(build / "reference" / f"{workload}-p03-{enabled}.log")
        for workload in WORKLOADS for enabled in (0, 1)
    }
    runs, configurations = [], []
    for lines in (1, 2, 4, 8, 16, 32, 64, 128):
        for ways in (1, 2):
            if ways > lines:
                continue
            for extra in (0, 1):
                configurations.append((lines, ways, extra, True))
    configurations += [(1, 1, 0, False), (128, 2, 1, False)]
    for lines, ways, extra, enabled in configurations:
        name = ("" if enabled else "disabled-") + f"l{lines}-w{ways}-h{extra}"
        gains = []
        for workload in WORKLOADS:
            path = build / name / f"{workload}.log"
            run = read_run(path)
            config_rows = [fields(line) for line in path.read_text().splitlines()
                           if line.startswith("CODE_BUFFER_CONFIG ")]
            assert config_rows == [dict(lines=str(lines), ways=str(ways),
                                        line_bytes="8", hit_extra=str(extra))], path
            reference = references[workload, int(enabled)]
            # This compares complete memory, GPR and FLAGS independently of
            # timing, including traffic handled by the real physical owner.
            assert run["signature"] == reference["signature"], (name, workload, "state")
            assert run["signature"]["ideal_owner"] == "0", (name, workload)
            for key in ("retired", "writes", "sdram_writes"):
                assert run["result"][key] == reference["result"][key], (name, workload, key)
            # Separate capacity effects from model/protocol changes. Both
            # one-line/no-extra and disabled-buffer controls must be exact.
            if not enabled or (lines, ways, extra) == (1, 1, 0):
                assert run["result"] == reference["result"], (name, workload, "baseline")
                assert run["cpu"] == reference["cpu"], (name, workload, "baseline buckets")
            old_cycles = reference["result"]["cycles"]
            gain = 100 * (old_cycles / run["result"]["cycles"] - 1)
            gains.append(gain)
            record = compact(run, build)
            record.update(lines=lines, ways=ways, hit_extra=extra, enabled=enabled,
                          data_bytes=lines*8, speedup=old_cycles/run["result"]["cycles"],
                          gain_percent=gain)
            runs.append(record)
        print(f"CODE_CAPACITY {name}: " + ", ".join(
            f"{w}={gain:+.2f}%" for w, gain in zip(WORKLOADS, gains)))

    # Record scripts and firmware as well as the precise compiled input set.
    for path in ("scripts/test_code_buffer_capacity.sh", "scripts/report_code_buffer_capacity.py",
                 "scripts/test_checkit_directed.sh", "scripts/report_checkit_profile.py",
                 "scripts/at_performance_flags.sh"):
        source_hashes[path] = digest(ROOT/path)
    firmware = {}
    for workload in WORKLOADS:
        source = ROOT / "tests/firmware" / f"checkit_{workload}.asm"
        firmware[workload] = dict(source_sha256=digest(source),
                                 rom_sha256=digest(build/"reference"/f"checkit-{workload}.rom"))
    report = dict(
        baseline_commit=(build/"baseline.commit").read_text().strip(),
        simulator=(build/"simulator.txt").read_text().strip(), clock_mhz=50,
        performance_macros=(build/"performance-macros.txt").read_text().split(),
        note="Simulation-only model with physical SDRAM. Synthetic firmware, not DOS CheckIt. No BRAM inference or FPGA timing claim.",
        source_sha256=source_hashes, firmware=firmware,
        exact_baseline_and_bypass_controls_pass=True,
        references=[compact(run, build) for run in references.values()], runs=runs,
    )
    output = build / "capacity.json"
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"CODE_BUFFER_CAPACITY_REPORT_PASS variants={len(configurations)} runs={len(runs)} report={output}")


if __name__ == "__main__":
    main()
