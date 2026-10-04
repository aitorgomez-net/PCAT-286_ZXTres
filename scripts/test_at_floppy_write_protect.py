#!/usr/bin/env python3
"""Bounded OSD/host write-protection matrix on the production AT FDC.

Run from Linux/WSL with Icarus and Verilator installed. The actual FDC wrapper,
shared floppy controller and FIFO are compiled without substitutes. Source
guards also bind the production OSD bits to the controller's combined mask.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
TOP = "spk286_at_floppy_write_protect_tb"
SOURCES = [
    "rtl/spk286_integration/spk286_at_fdc.sv",
    "rtl/common/floppy.v",
    "rtl/common/simple_fifo.v",
    "sim/spk286_integration/" + TOP + ".sv",
]
BOUNDARY_FILES = [
    "PCAT-286.sv", "config.tcl",
    "rtl/spk286_integration/spk286_at_machine.sv",
    "rtl/spk286_integration/spk286_at_device_router.sv",
    "rtl/spk286_integration/spk286_at_storage_video.sv",
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log):
    started = time.monotonic()
    with log.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen(command, cwd=ROOT, stdout=stream,
                                   stderr=subprocess.STDOUT,
                                   start_new_session=(os.name != "nt"))
        try:
            code = process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                process.kill()
            else:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise RuntimeError("180-second timeout: " + str(log)) from None
    if code:
        raise RuntimeError(f"Command failed ({code}): {log}")
    return round(time.monotonic() - started, 3)


def source_guards():
    checks = []

    def require(relative, expression, label):
        text = (ROOT / relative).read_text(encoding="utf-8")
        if re.search(expression, text) is None:
            raise AssertionError("Production binding changed: " + label)
        checks.append({"file": relative, "check": label})

    require("PCAT-286.sv", r'"OJK,Write Protect,None,A:,B:,A: & B:;"',
            "Single OSD mask: None/A/B/both at bits 20:19")
    text = (ROOT / "PCAT-286.sv").read_text(encoding="utf-8")
    if text.count('"OJK,Write Protect,None,A:,B:,A: & B:;"') != 1:
        raise AssertionError("Write-protect OSD entry is missing or duplicated")
    require("PCAT-286.sv", r'\.floppy_write_protect\s*\(hps_status\[20:19\]\)',
            "OSD bits reach the AT machine")
    for relative in BOUNDARY_FILES[2:]:
        require(relative, r'\.floppy_write_protect\s*\(floppy_write_protect\)',
                "Unmodified two-bit protection forwarding")
    require(SOURCES[0], r'\.wp\s*\(floppy_write_protect\)',
            "FDC wrapper binds protection to the shared controller")
    require(SOURCES[0], r'\.mgmt_fddn\s*\(mgmt_address\[7\]\)',
            "Host readonly mask independently addresses drive A/B")
    require(SOURCES[1], r'wire\s+\[1:0\]\s+media_writeprotected\s*=\s*wp_sys\s*\|\s*wp\s*;',
            "Host readonly and OSD protection are combined with OR")
    require(SOURCES[1], r'mgmt_write\s*&&\s*mgmt_address\s*==\s*4\x27d1\)\s*wp_sys\[mgmt_fddn\]\s*<=\s*mgmt_writedata\[0\]',
            "Management register 1 updates only the selected drive's readonly bit")
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        raise AssertionError("Use a fresh output directory")
    checks = source_guards()
    files = SOURCES + BOUNDARY_FILES + ["scripts/test_at_floppy_write_protect.py",
                                      "scripts/test_at_floppy_write_protect.sh"]
    inputs = {name: sha(ROOT / name) for name in files}
    output.mkdir(parents=True)
    receipt = {
        "status": "RUNNING", "source_sha256": inputs,
        "production_binding_checks": checks, "simulators": [],
        "clock_period_ns": 20, "cases": 32,
        "scope": "All 4 OSD masks x all 4 host readonly masks x both drives. "
                 "Every case checks Sense Drive Status and a full permitted read. "
                 "24 protected WRITE DATA and 24 protected FORMAT commands must "
                 "report write protection without DMA/HPS-write requests. "
                 "8 unprotected writes compare all 512 host bytes and complete; "
                 "8 unprotected formats compare the first sector filler.",
        "limitations": "Explicit DMA/HPS peers; no SDRAM, CPU bridge or actual "
                       "host filesystem. Formats stop after the first permitted "
                       "sector. No remount persistence or full regression claim.",
    }
    receipt_path = output / "receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
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
        build_seconds = run(command, compile_log)
        run_log = output / (simulator + "-run.log")
        run_seconds = run(execute, run_log)
        text = run_log.read_text(encoding="utf-8")
        cases = re.findall(r'^FDC_WP_CASE osd=(\d) host=(\d) drive=(\d) protected=(\d)$',
                           text, re.MULTILINE)
        expected = {(str(osd), str(host), str(drive), str(((osd | host) >> drive) & 1))
                    for osd in range(4) for host in range(4) for drive in range(2)}
        if len(cases) != 32 or set(cases) != expected:
            raise AssertionError("Incomplete or duplicated protection matrix: " + simulator)
        match = re.search(r'^AT_FLOPPY_WRITE_PROTECT_PASS cases=32 reads=32 '
                          r'blocked_writes=24 blocked_formats=24 allowed_writes=8 '
                          r'allowed_formats=8 sense=32 guarded_cycles=(\d+)$', text, re.MULTILINE)
        if not match or int(match[1]) == 0 or re.search(r'(?:%Error|FATAL|ERROR:)', text):
            raise AssertionError("Protection bank failed: " + simulator)
        receipt["simulators"].append({"simulator": simulator,
            "build_seconds": build_seconds, "run_seconds": run_seconds,
            "build_log_sha256": sha(compile_log), "run_log_sha256": sha(run_log),
            "guarded_cycles": int(match[1]), "case_rows": cases})
        print(simulator + ": " + match[0], flush=True)
    for relative, expected in inputs.items():
        if sha(ROOT / relative) != expected:
            raise AssertionError("Source changed during the run: " + relative)
    receipt["status"] = "AT_FLOPPY_WRITE_PROTECT_MATRIX_PASS"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(receipt["status"], flush=True)


if __name__ == "__main__":
    main()
