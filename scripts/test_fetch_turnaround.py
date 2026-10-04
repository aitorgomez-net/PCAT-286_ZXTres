#!/usr/bin/env python3
"""Bounded dual-simulator READY-chain and six-byte reservation checks.

The production fetch and queue compile directly. The harness supplies explicit
ordinary requests and separate conservative READY-chain reservations; it does
not substitute the instruction engine, BIU timing policy or memory controller.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
TOP = "spk286_fetch_turnaround_tb"
SOURCES = ["vendor/spk286/rtl/spk286_fetch.sv",
           "vendor/spk286/rtl/spk286_prefetch_queue.sv",
           "sim/spk286_timing/" + TOP + ".sv"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, timeout, failure_expected=False):
    started = time.monotonic()
    with log.open("w") as stream:
        proc = subprocess.Popen(command, cwd=ROOT, stdout=stream,
                                stderr=subprocess.STDOUT,
                                start_new_session=(os.name != "nt"))
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                proc.kill()
            else:
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            raise RuntimeError("Hard timeout: " + str(log)) from None
    if code and not failure_expected:
        raise RuntimeError(f"Command failed ({code}): {log}")
    if not code and failure_expected:
        raise AssertionError("Negative READY-chain control unexpectedly passed: " + str(log))
    return round(time.monotonic() - started, 3)


def compare_traces(left_path, right_path):
    """Retain raw traces; exclude only state before the first reset edge."""
    with left_path.open() as stream:
        left = list(csv.DictReader(stream))
    with right_path.open() as stream:
        right = list(csv.DictReader(stream))
    if len(left) != len(right):
        raise AssertionError("Dual-simulator trace lengths differ")
    invalid_initial_fields = {"response_ip", "response_count", "response_data",
                              "response_valid", "queue_count"}
    ignored = []
    for row_index, (a, b) in enumerate(zip(left, right)):
        for key in a:
            if a[key] == b[key]:
                continue
            if (row_index == 0 and key in invalid_initial_fields and
                    a["cycle"] == b["cycle"] == "0" and
                    a["reset"] == b["reset"] == "1" and
                    a["bus_valid"] == b["bus_valid"] == "0" and
                    a["ready"] == b["ready"] == "0"):
                ignored.append({"row_index": row_index, "field": key,
                                "iverilog_raw": a[key], "verilator_raw": b[key]})
            else:
                raise AssertionError(f"Dual trace mismatch row {row_index} field {key}: {a[key]} != {b[key]}")
    return {"rows": len(left), "exact_rows_after_first_reset": len(left)-1,
            "policy": "Only the first pre-clock row's uninitialized response state "
                      "and queue occupancy are inapplicable before reset is sampled. "
                      "Every other signal/row compares exactly; raw CSVs are preserved.",
            "ignored_initial_differences": ignored}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        raise AssertionError("Use a fresh output directory")
    output.mkdir(parents=True)
    files = SOURCES + ["scripts/test_fetch_turnaround.py"]
    inputs = {name: sha(ROOT / name) for name in files}
    receipt = {"status": "RUNNING", "source_sha256": inputs,
               "requires_ready_chain": True, "simulators": [],
               "scope": "Direct production fetch+six-byte queue. Physical CODE response "
                        "scoreboard, independent byte FIFO, separate ordinary request and "
                        "chain reservation; no CPU instruction or AT bridge regression claim.",
               "bounds": {"compile_seconds": 120, "run_seconds": 30, "fabric_cycles": 12000}}
    receipt_path = output / "receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    rows = []
    traces = []
    for simulator in ("iverilog", "verilator"):
        compile_log = output / (simulator + "-build.log")
        if simulator == "iverilog":
            binary = output / "test_iv"
            command = ["iverilog", "-g2012", "-s", TOP, "-o", str(binary)] + SOURCES
            execute = ["vvp", str(binary)]
        else:
            build = output / "verilator-obj"
            command = ["verilator", "--binary", "--timing", "--assert", "--top-module",
                       TOP, "-Wno-fatal", "-j", "2", "--Mdir", str(build),
                       "-o", "test_vlt"] + SOURCES
            execute = [str(build / "test_vlt")]
        compile_seconds = run(command, compile_log, 120)
        run_log = output / (simulator + "-run.log")
        trace = output / (simulator + "-trace.csv")
        execute += ["+REQUIRE_CHAIN=1", "+TRACE=" + str(trace)]
        run_seconds = run(execute, run_log, 30)
        text = run_log.read_text()
        cases = re.findall(r"^FETCH_TURNAROUND_CASE (\d+) (\w+)$", text, re.MULTILINE)
        summary = re.search(r"^FETCH_TURNAROUND_PASS cases=(\d+) checks=(\d+) cycles=(\d+) "
                            r"completed=(\d+) delivered=(\d+) stale=(\d+) ready_chains=(\d+) "
                            r"hidden=(\d+) queue_bytes=(\d+) require_chain=(\d+)$", text, re.MULTILINE)
        if not summary or len(cases) != 16 or int(summary[1]) != 16:
            raise AssertionError("Incomplete directed bank: " + simulator)
        if [int(case[0]) for case in cases] != list(range(1, 17)):
            raise AssertionError("Duplicated or reordered cases: " + simulator)
        if re.search(r"(?:%Error|FATAL|ERROR:)", text):
            raise AssertionError("Directed bank error: " + simulator)
        rows.append(cases)
        traces.append(trace)
        receipt["simulators"].append({"simulator": simulator,
            "compile_seconds": compile_seconds, "run_seconds": run_seconds,
            "cases": cases, "summary": summary[0], "trace_sha256": sha(trace),
            "compile_log_sha256": sha(compile_log), "run_log_sha256": sha(run_log)})
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        print(simulator + ": " + summary[0], flush=True)
    if rows[0] != rows[1]:
        raise AssertionError("Dual-simulator directed cases differ")
    receipt["trace_comparison"] = compare_traces(traces[0], traces[1])
    # The same assertions must reject the old turnaround when only its new
    # parameter is disabled. No expected data, cursor or case is changed.
    negative_source = output / "negative-ready-chain-disabled.sv"
    bank = (ROOT / SOURCES[-1]).read_text()
    selector = ".READY_CHAINING(1'b1)"
    if bank.count(selector) != 1:
        raise AssertionError("Cannot derive the single disabled-feature negative control")
    negative_source.write_text(bank.replace(selector, ".READY_CHAINING(1'b0)"))
    negative_binary = output / "negative_iv"
    negative_build_log = output / "negative-build.log"
    run(["iverilog", "-g2012", "-s", TOP, "-o", str(negative_binary)] +
        SOURCES[:-1] + [str(negative_source)], negative_build_log, 120)
    negative_log = output / "negative-run.log"
    run(["vvp", str(negative_binary), "+REQUIRE_CHAIN=1"], negative_log, 30,
        failure_expected=True)
    negative_text = negative_log.read_text()
    if "physical fetch address/lane mismatch case=0" not in negative_text:
        raise AssertionError("Negative control failed for an unrelated reason")
    receipt["negative_control"] = {
        "mutation": "Only test instance READY_CHAINING=1 changed to READY_CHAINING=0",
        "detected": "First READY->next CODE request assertion rejects old turnaround",
        "source_sha256": sha(negative_source), "build_log_sha256": sha(negative_build_log),
        "run_log_sha256": sha(negative_log)}
    for name, expected in inputs.items():
        if sha(ROOT / name) != expected:
            raise AssertionError("Source changed during the run: " + name)
    receipt["status"] = "FETCH_TURNAROUND_DUAL_PASS"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(receipt["status"], flush=True)


if __name__ == "__main__":
    main()
