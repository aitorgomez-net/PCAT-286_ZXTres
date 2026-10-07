#!/usr/bin/env python3
"""Check ten-byte completion and eleven-byte faults with a missing-guard negative control.

The corrected CPU must also reject an eleven-byte target at that target's IP.
Old/new receive the same 76 transfer probes and five event probes. Only old CPU
source guard differs; complete public traces are streamed to compressed files.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CPU = ROOT / "vendor/spk286"
BENCH = ROOT / "sim/spk286_timing/spk286_length_fault_boundary_tb.sv"
TOP = "spk286_length_fault_boundary_tb"
PASS = "P06_LENGTH_FAULT_CPU_PASS"

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, timeout=900):
    result = subprocess.run([str(item) for item in command], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=timeout)
    log.write_text(result.stdout, newline="\n")
    if result.returncode:
        raise RuntimeError(f"command failed {result.returncode}: {log}")
    return result.stdout


def execute(command, log, trace_path=None):
    digest = hashlib.sha256()
    count = size = 0
    results = []
    event_results = []
    passed = False
    with log.open("wb") as target:
        with subprocess.Popen([str(item) for item in command], cwd=ROOT,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
            compressor = gzip.open(trace_path, "wb", compresslevel=6) if trace_path else None
            try:
                for line in process.stdout:
                    if line.startswith(b"TRACE,"):
                        if compressor is None:
                            raise AssertionError("trace was enabled without a compressed sink")
                        compressor.write(line)
                        digest.update(line); count += 1; size += len(line)
                    else:
                        target.write(line)
                        if line.startswith(b"RESULT,"):
                            values = list(map(int, line.decode().strip().split(",")[1:]))
                            results.append(dict(zip(
                                ["id", "profile", "kind", "length", "odd", "stall", "clocks", "budget"],
                                values, strict=True)))
                        if line.startswith(b"EVENT_RESULT,"):
                            fields = line.decode().strip().split(",")[1:]
                            event_results.append(dict(zip(
                                ["id", "profile", "probe", "phase", "vector", "clocks", "frame_ip"],
                                [*map(int, fields[:-1]), int(fields[-1], 16)], strict=True)))
                        if PASS.encode() in line:
                            passed = True
                status = process.wait(timeout=900)
            finally:
                if compressor is not None:
                    compressor.close()
    if status or not passed:
        raise RuntimeError(f"integration simulator failed {status}: {log}")
    expected = [(kind, length, odd, 0) for length in range(1, 11)
                for odd in range(2) for kind in (0, 1)]
    expected += [(kind, 3, odd, 0) for kind in range(2, 15) for odd in range(2)]
    expected += [(1, length, length % 2, 7) for length in range(1, 11)]
    actual = [(row["kind"], row["length"], row["odd"], row["stall"]) for row in results]
    if actual != expected or [row["id"] for row in results] != list(range(1, 77)):
        raise AssertionError("accepted integration case matrix is incomplete")
    profile = results[0]["profile"]
    expected_events = [(1, 0), (2, 0), (3, 0)]
    expected_events += [(probe, phase) for phase in range(7 if profile != 0 else 1)
                        for probe in (4, 5)]
    if [(row["probe"], row["phase"]) for row in event_results] != expected_events:
        raise AssertionError("accepted event handoff matrix is incomplete")
    return {"status": "PASS", "results": results, "event_results": event_results,
            "trace": {"sha256": digest.hexdigest(), "bytes": size, "rows": count,
                      "normalization": "none; complete raw public stream"}}





OLD_ANCHOR = "assign length_fault = !event_active && instruction_bytes == 10 &&"
NEW_ANCHOR = "assign length_fault = !event_active && !raw_retired && !event_completed && instruction_bytes == 10 &&"


def execute_old(command, log, compressed):
    digest = hashlib.sha256(); rows = size = 0
    with log.open("wb") as target, gzip.open(compressed, "wb", compresslevel=6) as trace:
        with subprocess.Popen(list(map(str, command)), cwd=ROOT,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
            for line in process.stdout:
                if line.startswith(b"TRACE,"):
                    trace.write(line); digest.update(line); rows += 1; size += len(line)
                else:
                    target.write(line)
            status = process.wait(timeout=900)
    text = log.read_text()
    if status == 0 or "case=37" not in text or "len=10" not in text or "event=1" not in text:
        raise AssertionError("frozen old legal-ten-byte fault did not reproduce exactly")
    return {"status": "EXPECTED_FAILURE_REPRODUCED", "returncode": status,
            "case": 37, "encoding": "3E 3E 3E 3E C7 06 20 07 34 12",
            "trace": {"sha256": digest.hexdigest(), "rows": rows, "bytes": size},
            "failure": "Completed legal ten-byte target raises an unintended #GP instead of advancing"}


def compare_prefix(old, corrected):
    common = 0; mismatch = None
    with gzip.open(old, "rt") as a, gzip.open(corrected, "rt") as b:
        for row_a, row_b in zip(a, b):
            if row_a != row_b:
                mismatch = {"old": row_a.strip(), "corrected": row_b.strip()}
                break
            common += 1
    if mismatch is None:
        raise AssertionError("intentional fault correction produced no public stream change")
    return {"identical_initial_rows": common, "first_public_difference": mismatch,
            "normalization": "none"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dual", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / "build").resolve()):
        parser.error("output must be a fresh workspace build directory")
    output.mkdir(parents=True, exist_ok=False)
    current = (CPU / "rtl/spk286.sv").read_text()
    if current.count(NEW_ANCHOR) != 1 or OLD_ANCHOR in current:
        raise AssertionError("corrected source does not contain the exact guard")
    frozen_old = current.replace(NEW_ANCHOR, OLD_ANCHOR).encode()
    old_path = output / "missing_length_guard.sv"
    old_path.write_bytes(frozen_old)
    package_names = ["microcode/generated/spk286_microcode_pkg.sv",
                     "microcode/generated/spk286_microcode_rom.sv",
                     "microcode/generated/spk286_microcode_sync_rom.sv",
                     "rtl/spk286_protected_pkg.sv", "rtl/spk286_tss_pkg.sv"]
    original = [CPU / name for name in package_names]
    original += [path for path in sorted((CPU / "rtl").glob("*.sv")) if path not in original]
    shared = [ROOT / "rtl/spk286_integration/spk286_at_cpu_profile.sv", BENCH]
    include = ["-I" + str(CPU / "rtl"), "-I" + str(CPU / "sim/unit")]
    inputs = [*shared, *original, CPU / "sim/unit/spk286_signals.svh",
              Path(__file__).resolve()]
    before = {path.relative_to(ROOT).as_posix(): sha(path) for path in inputs}
    old_sources = [old_path if path.name == "spk286.sv" else path for path in original]
    for label, selected in [("old", old_sources), ("corrected", original)]:
        run(["iverilog", "-g2012", "-DHANDOFF_GOLDEN_FUNCTIONAL", "-s", TOP,
                   *include, "-o", output / f"{label}.vvp", *selected, *shared],
                  output / f"{label}-build.log")
    old = execute_old(["vvp", output / "old.vvp", "+profile=0", "+trace=1", "+debug=1"],
                      output / "old.log", output / "old.csv.gz")
    corrected = execute(["vvp", output / "corrected.vvp", "+profile=0", "+trace=1", "+debug=1"],
                              output / "corrected.log", output / "corrected.csv.gz")
    paired = compare_prefix(output / "old.csv.gz", output / "corrected.csv.gz")
    dual = None
    if args.dual:
        run(["verilator", "--binary", "--timing", "--assert", "-DHANDOFF_GOLDEN_FUNCTIONAL",
                   "-CFLAGS", "-O0", "-j", "2", "--top-module", TOP,
                   "--Mdir", output / "obj", "-o", "corrected", *include,
                   *original, *shared], output / "verilator-build.log", timeout=1200)
        dual = execute([output / "obj/corrected", "+profile=0", "+trace=0"],
                             output / "verilator.log")
        if dual["results"] != corrected["results"] or dual["event_results"] != corrected["event_results"]:
            raise AssertionError("corrected legal/illegal target outcomes differ between simulators")
    after = {path.relative_to(ROOT).as_posix(): sha(path) for path in inputs}
    changed = [name for name in before if before[name] != after[name]]
    receipt = {"status": "PASS" if not changed else "SOURCE_CHANGED",
               "negative_cpu_sha256": sha(old_path), "corrected_cpu_sha256": sha(CPU / "rtl/spk286.sv"),
               "minimal_change": {"old": OLD_ANCHOR, "new": NEW_ANCHOR},
               "source_sha256": before, "old": old, "corrected": corrected,
               "pair": paired, "dual": dual, "source_changes": changed,
               "scope": "RAW completion byte-demand qualification only; broader CPU regression remains separate"}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", newline="\n")
    if changed:
        raise AssertionError(f"sources changed during boundary proof: {changed}")
    print("P06_LENGTH_FAULT_BOUNDARY_PASS old-failure-reproduced legal10-pass illegal11-GP", flush=True)


if __name__ == "__main__":
    main()
