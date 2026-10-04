#!/usr/bin/env python3
"""Bounded composed RAM->DMA->FDC->host WRITE DATA and readback regression.

Run inside WSL: python3 scripts/test_at_floppy_write.py --output build/DIR
Both Icarus and Verilator are mandatory. A negative run uses the original
unretained machine connection and must fail specifically on FIFO payload.
The production machine payload region and endpoint connection are extracted
literally; no alternative correction is reconstructed in the harness.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
TOP = "spk286_at_floppy_write_tb"
BASELINE_COMMIT = "7cb6e2efb942e8d49b0f1ed44613e1d186a450d7"
SOURCES = [
    "rtl/spk286_integration/spk286_at_dma.sv",
    "rtl/spk286_integration/spk286_at_mister_memory_port.sv",
    "rtl/spk286_integration/spk286_at_sdram_read_buffer.sv",
    "rtl/spk286_integration/spk286_at_sdram_data_buffer.sv",
    "rtl/spk286_integration/spk286_at_posted_write_buffer.sv",
    "rtl/spk286_integration/spk286_at_fdc.sv",
    "rtl/common/floppy.v", "rtl/common/simple_fifo.v",
    "sim/spk286_integration/spk286_at_floppy_write_tb.sv",
]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(command, log, timeout=180):
    start = time.monotonic()
    with log.open("w") as stream:
        process = subprocess.Popen(list(map(str, command)), cwd=ROOT,
                                   stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise RuntimeError(f"Timed out after {timeout}s: {log}") from None
    return {"exit_code": code, "elapsed_seconds": round(time.monotonic()-start, 3),
            "log": str(log.relative_to(ROOT)), "log_sha256": sha(log)}

def adapter(region):
    return """`timescale 1ns/1ps
module spk286_at_dma_read_payload_adapter (
 input logic clk, reset, dma_transfer_valid,
 input logic [2:0] dma_active_channel,
 input logic [1:0] dma_transfer_byte_enable,
 input logic dma_transfer_read_from_memory, dma_memory_response_valid, dma_transfer_complete,
 input logic [15:0] dma_memory_data_in,
 output wire [15:0] dma_endpoint_data
);
""" + region.replace("wire [15:0] dma_endpoint_data =", "assign dma_endpoint_data =") + "\nendmodule\n"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--baseline-ref", default=BASELINE_COMMIT,
                        help="Pre-fix commit supplying the original machine endpoint expression")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        raise RuntimeError("Fresh output directory required")
    for tool in ("iverilog", "vvp", "verilator"):
        if not shutil.which(tool):
            raise RuntimeError("Missing required simulator: " + tool)
    machine_path = ROOT / "rtl/spk286_integration/spk286_at_machine.sv"
    machine = machine_path.read_text()
    match = re.search(r"// BEGIN DMA_READ_PAYLOAD_RETENTION\n(.*?)// END DMA_READ_PAYLOAD_RETENTION", machine, re.S)
    if match is None:
        raise RuntimeError("Missing production payload-retention region")
    connection = re.findall(r"\.dma_transfer_data_in\s*\((.*?)\),", machine, re.S)
    if connection != ["dma_endpoint_data"]:
        raise RuntimeError("Unexpected machine endpoint binding: " + repr(connection))
    baseline = subprocess.check_output(
        ["git", "show", args.baseline_ref+":rtl/spk286_integration/spk286_at_machine.sv"],
        cwd=ROOT, text=True, timeout=15)
    original = re.findall(r"\.dma_transfer_data_in\s*\((.*?)\),", baseline, re.S)
    if len(original) != 1 or "dma_memory_data_in" not in original[0]:
        raise RuntimeError("Baseline must supply the original unretained payload binding")
    output.mkdir(parents=True)
    frozen = output/"source"
    for relative in SOURCES:
        destination = frozen/relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT/relative, destination)
    (frozen/"machine-current.sv").write_text(machine)
    (frozen/"machine-original.sv").write_text(baseline)
    shutil.copyfile(Path(__file__), frozen/"runner.py")
    report = {
        "status": "RUNNING", "source_sha256": {p: sha(frozen/p) for p in SOURCES},
        "machine_sha256": sha(machine_path), "runner_sha256": sha(Path(__file__)),
        "baseline_ref": args.baseline_ref,
        "baseline_machine_sha256": hashlib.sha256(baseline.encode()).hexdigest(),
        "baseline_endpoint_connection": original[0],
        "endpoint_connection": connection[0],
        "extracted_region_sha256": hashlib.sha256(match[1].encode()).hexdigest(),
        "adapter_transform": "Only wire [15:0] dma_endpoint_data = becomes assign dma_endpoint_data = because the generated module exposes the same net as an output port; all payload logic is copied literally.",
        "scope": "Production DMA + memory port + P03 code buffer + RAM data buffer + posted buffer + FDC/FIFO; source-extracted machine payload adapter. Five 512-byte WRITE DATA sectors, four READ DATA readbacks, even/odd start, decrement, auto-init/reuse, stalls, TC/IRQ/results and HPS LBA/payload checks. Adapter checks: channel1 live response, channel5 retained 16-bit word, transfer/response/read capture guards and reset.",
        "limits": "Physical SDRAM is an abstract RAM responder, with response data withdrawn immediately after READY. Host image is a byte array transferred over real FDC management ports; no MiSTer HPS software, actual SD-card filesystem or CPU instructions.",
        "runs": []
    }
    (output/"receipt.json").write_text(json.dumps(report, indent=2)+"\n")
    for variant in ("corrected", "original-negative"):
        variant_dir = output / variant
        variant_dir.mkdir()
        region = match[1] if variant == "corrected" else (
            "wire [15:0] dma_endpoint_data = " + original[0] + ";\n")
        source = variant_dir / "machine_payload_adapter.sv"
        source.write_text(adapter(region))
        common = [str(frozen/p) for p in SOURCES] + [str(source)]
        expected = 0 if variant == "corrected" else 1
        for simulator in ("iverilog", "verilator"):
            prefix = variant_dir/simulator
            if simulator == "iverilog":
                binary = prefix.with_suffix(".vvp")
                build = ["iverilog", "-g2012", "-s", TOP, "-o", binary]+common
                execute = ["vvp", binary]
            else:
                obj = variant_dir/"verilator-obj"
                build = ["verilator", "--binary", "--timing", "--assert", "-Wno-fatal",
                         "-j", "2", "--top-module", TOP, "--Mdir", obj, "-o", "run"]+common
                execute = [obj/"run"]
            built = run(build, prefix.with_name(prefix.name+"-build.log"))
            if built["exit_code"] != 0:
                raise RuntimeError("Compile failed: " + built["log"])
            executed = run(execute, prefix.with_name(prefix.name+"-run.log"), timeout=60)
            log = (ROOT/executed["log"]).read_text()
            if expected == 0:
                if executed["exit_code"] != 0 or "AT_FLOPPY_WRITE_PASS" not in log:
                    raise RuntimeError("Positive regression failed: " + executed["log"])
                if log.count("FLOPPY_WRITE_CASE_PASS") != 4:
                    raise RuntimeError("Incomplete directed-case bank")
                if log.count("FLOPPY_PAYLOAD_UNIT_PASS") != 1:
                    raise RuntimeError("Missing payload adapter compatibility checks")
            elif executed["exit_code"] == 0 or "FLOPPY_WRITE_PAYLOAD_MISMATCH case=0 byte=0" not in log:
                raise RuntimeError("Negative control did not catch original bug: " + executed["log"])
            report["runs"].append({"variant": variant, "simulator": simulator,
                                   "adapter_sha256": sha(source), "build": built, "execution": executed,
                                   "expected_failure": bool(expected)})
            (output/"receipt.json").write_text(json.dumps(report, indent=2)+"\n")
            print(variant, simulator, "PASS", flush=True)
    report["status"] = "AT_FLOPPY_WRITE_COMPOSED_DIRECTED_PASS"
    (output/"receipt.json").write_text(json.dumps(report, indent=2)+"\n")
    print(report["status"], flush=True)

if __name__ == "__main__":
    main()
