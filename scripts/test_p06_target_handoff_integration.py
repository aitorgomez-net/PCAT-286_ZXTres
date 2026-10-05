#!/usr/bin/env python3
"""Directed full-CPU target handoff checks with immutable architectural oracles.

Run under Linux/WSL with Icarus and optional Verilator. Full MAX public streams
are compressed while streaming; no uncompressed per-edge trace is stored.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

from build_p06_profile_cpu import build


ROOT = Path(__file__).resolve().parents[1]
CPU = ROOT / "vendor/spk286"
BENCH = ROOT / "sim/spk286_timing/spk286_target_handoff_integration_tb.sv"
TOP = "spk286_target_handoff_integration_tb"
PASS = "P06_TARGET_HANDOFF_INTEGRATION_PASS"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
    packages = [CPU / name for name in [
        "microcode/generated/spk286_microcode_pkg.sv",
        "microcode/generated/spk286_microcode_rom.sv",
        "microcode/generated/spk286_microcode_sync_rom.sv",
        "rtl/spk286_protected_pkg.sv", "rtl/spk286_tss_pkg.sv"]]
    return packages + [path for path in sorted((CPU / "rtl").glob("*.sv"))
                       if path not in packages]


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
    protected_results = []
    cancel_results = []
    hold_results = []
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
                        if line.startswith(b"PROTECTED_RESULT,"):
                            fields = line.decode().strip().split(",")[1:]
                            protected_results.append(dict(zip(
                                ["id", "profile", "variant", "source_retired", "frame_ip", "error_code"],
                                [*map(int, fields[:-2]), *[int(value, 16) for value in fields[-2:]]], strict=True)))
                        if line.startswith(b"CANCEL_RESULT,"):
                            fields = line.decode().strip().split(",")[1:]
                            cancel_results.append(dict(zip(
                                ["id", "profile", "reset", "source_retired", "ax", "dx"],
                                [*map(int, fields[:-2]), *[int(value, 16) for value in fields[-2:]]], strict=True)))
                        if line.startswith(b"HOLD_RESULT,"):
                            hold_results.append(dict(zip(
                                ["id", "profile", "source_retired", "target_retired"],
                                map(int, line.decode().strip().split(",")[1:]), strict=True)))
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
    if [row["variant"] for row in protected_results] != list(range(3)):
        raise AssertionError("protected source/truncated-successor case matrix is incomplete")
    if [row["reset"] for row in cancel_results] != ([0, 1] if profile != 0 else []):
        raise AssertionError("external redirect/reset cancellation matrix is incomplete")
    if len(hold_results) != (1 if profile != 0 else 0):
        raise AssertionError("HOLD during incomplete preview case is missing")
    return {"status": "PASS", "results": results, "event_results": event_results,
            "protected_results": protected_results, "cancel_results": cancel_results,
            "hold_results": hold_results,
            "trace": {"sha256": digest.hexdigest(), "bytes": size, "rows": count,
                      "normalization": "none; complete raw public stream"}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profiles", default="0,1,4,7")
    parser.add_argument("--dual", action="store_true")
    args = parser.parse_args()
    profiles = [int(value) for value in args.profiles.split(",")]
    if not profiles or len(profiles) != len(set(profiles)) or any(value not in range(8) for value in profiles):
        parser.error("profiles must be unique IDs0..7")
    output = args.output.resolve()
    if not output.is_relative_to((ROOT / "build").resolve()):
        parser.error("output must be a fresh workspace build subdirectory")
    output.mkdir(parents=True, exist_ok=False)
    original = sources()
    extras = [*sorted((ROOT / "rtl/spk286_timing").glob("*.sv")),
              ROOT / "rtl/spk286_integration/spk286_at_cpu_profile.sv"]
    inputs = [*original, *extras, BENCH, CPU / "sim/unit/spk286_signals.svh",
              ROOT / "scripts/build_p06_profile_cpu.py", Path(__file__).resolve()]
    before = {path.relative_to(ROOT).as_posix(): sha(path) for path in inputs}
    generated = build(output / "generated")
    selected = [path for path in original if path.name not in {"spk286.sv", "spk286_events.sv"}]
    selected += list(generated.values()) + extras
    include = ["-I" + str(CPU / "rtl"), "-I" + str(CPU / "sim/unit")]
    run(["iverilog", "-g2012", "-s", TOP, *include, "-o", output / "candidate.vvp",
         *selected, BENCH], output / "icarus-build.log")
    results = []
    for profile in profiles:
        trace = output / f"max-candidate.csv.gz" if profile == 0 else None
        result = execute(["vvp", output / "candidate.vvp", f"+profile={profile}",
                          f"+trace={1 if profile == 0 else 0}"],
                         output / f"candidate-{profile}.log", trace)
        results.append({"simulator": "iverilog", "profile": profile, **result})
        print(f"TARGET_HANDOFF_PASS Icarus profile={profile} cases=76", flush=True)
    if 0 in profiles:
        run(["iverilog", "-g2012", "-DHANDOFF_GOLDEN_FUNCTIONAL", "-s", TOP,
             *include, "-o", output / "golden.vvp", *original,
             ROOT / "rtl/spk286_integration/spk286_at_cpu_profile.sv", BENCH],
            output / "golden-build.log")
        golden = execute(["vvp", output / "golden.vvp", "+profile=0", "+trace=1"],
                         output / "golden.log", output / "max-golden.csv.gz")
        candidate = next(record for record in results if record["profile"] == 0)
        if golden["trace"] != candidate["trace"]:
            raise AssertionError("MAX full raw public trace diverges from original functional CPU")
        results.append({"simulator": "iverilog", "profile": 0,
                        "kind": "MAX complete public raw equivalence", **golden})
    if args.dual:
        run(["verilator", "--binary", "--timing", "--assert", "-CFLAGS", "-O0",
             "-j", "2", "--top-module", TOP, "--Mdir", output / "obj",
             "-o", "candidate", *include, *selected, BENCH],
            output / "verilator-build.log", timeout=1200)
        for profile in profiles:
            result = execute([output / "obj/candidate", f"+profile={profile}", "+trace=0"],
                             output / f"verilator-{profile}.log")
            candidate = next(record for record in results
                             if record["simulator"] == "iverilog" and record["profile"] == profile)
            if result["results"] != candidate["results"]:
                raise AssertionError("dual-simulator complete accepted case metrics differ")
            if result["event_results"] != candidate["event_results"]:
                raise AssertionError("dual-simulator complete event metrics differ")
            if result["protected_results"] != candidate["protected_results"]:
                raise AssertionError("dual-simulator protected fault metrics differ")
            if result["cancel_results"] != candidate["cancel_results"] or result["hold_results"] != candidate["hold_results"]:
                raise AssertionError("dual-simulator cancellation/HOLD metrics differ")
            results.append({"simulator": "verilator", "profile": profile, **result})
            print(f"TARGET_HANDOFF_PASS Verilator profile={profile} cases=76", flush=True)
    after = {path.relative_to(ROOT).as_posix(): sha(path) for path in inputs}
    changed = [name for name in before if before[name] != after[name]]
    receipt = {"status": "PASS" if not changed else "SOURCE_CHANGED",
               "scope": "Full CPU handoff architectural/deadline probes; not complete event coverage or fitted timing closure",
               "sources_sha256": before,
               "generated_sha256": {path.name: sha(path) for path in generated.values()},
               "profiles": profiles, "results": results, "source_changes": changed}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", newline="\n")
    if changed:
        raise AssertionError(f"sources changed during integration execution: {changed}")
    print("P06_TARGET_HANDOFF_INTEGRATION_PASS", flush=True)


if __name__ == "__main__":
    main()
