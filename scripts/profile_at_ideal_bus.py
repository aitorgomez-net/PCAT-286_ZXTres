"""Compare the current AT memory path with the 86Box-style always-READY bus.

Diagnostic simulation only. Generate a private copy of the directed harness;
never change the CPU or physical memory implementation. First run
PCAT_PROFILE=1 scripts/test_checkit_directed.sh into the same build directory.
The workloads are synthetic firmware, not the commercial CheckIt executable.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
WORKLOADS = ("dhrystone", "whetstone", "working_set", "dhrystone21")


def replace_once(source, old, new):
    assert source.count(old) == 1, old
    return source.replace(old, new)


def records(path):
    result = {}
    for line in path.read_text().splitlines():
        if line.startswith(("CHECKIT_DIRECTED_PASS ", "PROFILE_SIGNATURE ")):
            tag, *fields = line.split()
            assert tag not in result, (path, tag)
            result[tag] = dict(field.split("=", 1) for field in fields)
    assert set(result) == {"CHECKIT_DIRECTED_PASS", "PROFILE_SIGNATURE"}, path
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_dir", type=Path)
    args = parser.parse_args()
    build = args.build_dir.resolve()
    assert build.is_relative_to(ROOT / "build"), "Use a private build directory"
    # Require the baseline to match the current sources before compiling.
    receipt = build / "compiled-sources.sha256"
    subprocess.run(["sha256sum", "--check", str(receipt)], cwd=ROOT,
                   check=True, stdout=subprocess.DEVNULL)
    source = (ROOT / "sim/spk286_integration/spk286_checkit_workload_tb.sv").read_text()
    source = replace_once(source, "    wire halted, shutdown,", """    integer ideal_cpu_bus = 0;
    wire bridge_ready;
    wire [15:0] bridge_data_in;
    wire [23:0] direct_address = address[23:16] == 8'hFF
        ? {4'h0, 4'hF, address[15:0]} : address;
    wire [15:0] direct_word = dram.mem[direct_address[23:1]];
    assign ready = ideal_cpu_bus != 0 ? 1'b1 : bridge_ready;
    assign data_in = ideal_cpu_bus == 0 ? bridge_data_in :
        address[0] ? {direct_word[15:8], 8'h00} :
        bus_bhe_n ? {8'h00, direct_word[7:0]} : direct_word;
    // The bus handshakes at the CPU edge, exactly once per accepted beat.
    // Preserve odd-byte lanes and the explicit high-BIOS alias. This firmware
    // has no I/O, interrupts, DMA, self-modifying code or device reads.
    always @(posedge clk) begin
        if (ideal_cpu_bus != 0 && !cpu_reset && bus_valid) begin
            if (bus_status != 4'h5 && bus_status != 4'h6 && bus_status != 4'hD)
                $fatal(1, "Unsupported always-READY probe cycle");
            if (bus_write) begin
                if (address[0])
                    dram.mem[direct_address[23:1]][15:8] <= data_out[15:8];
                else begin
                    dram.mem[direct_address[23:1]][7:0] <= data_out[7:0];
                    if (!bus_bhe_n)
                        dram.mem[direct_address[23:1]][15:8] <= data_out[15:8];
                end
            end
        end
    end
    wire halted, shutdown,""")
    source = replace_once(source, ".cpu_bus_valid(bus_valid),",
                          ".cpu_bus_valid(bus_valid && ideal_cpu_bus == 0),")
    source = replace_once(source, ".cpu_ready(ready), .cpu_data_in(data_in),",
                          ".cpu_ready(bridge_ready), .cpu_data_in(bridge_data_in),")
    source = replace_once(source, "            if (halted) begin", """            if (halted) begin
                if (ideal_cpu_bus != 0) begin : direct_signature
                    logic [63:0] memory_hash;
                    memory_hash = 64'hcbf29ce484222325;
                    for (integer i = 0; i < dram.MEM_WORDS; i++) begin
                        memory_hash = (memory_hash ^ {56'd0, dram.mem[i][7:0]}) * 64'h100000001b3;
                        memory_hash = (memory_hash ^ {56'd0, dram.mem[i][15:8]}) * 64'h100000001b3;
                    end
                    $display("PROFILE_SIGNATURE gpr=%032h flags=%04h memory=%016h ideal_owner=0",
                        gpr, cpu.cpu.debug_flags, memory_hash);
                end""")
    source = replace_once(source, '        fd = $fopen(rom_path, "rb");', """        if ($value$plusargs("IDEAL_CPU_BUS=%d", ideal_cpu_bus)) begin end
        if (ideal_cpu_bus != 0 && (profile_enable != 0 || ideal_owner_mode != 0))
            $fatal(1, "Always-READY probe cannot use AT timestamps/ideal owner");
        fd = $fopen(rom_path, "rb");""")
    generated = build / "ideal_cpu_bus_tb.sv"
    generated.write_text(source)
    sources = re.findall(r'SYSTEMVERILOG_FILE "(vendor/[^"\n]+\.sv)"',
                         (ROOT / "rtl/spk286_integration/spk286_integration.qip").read_text())
    sources += ["rtl/spk286_integration/spk286_machine_cpu.sv",
                "rtl/spk286_integration/spk286_at_bus_bridge.sv",
                "rtl/spk286_integration/spk286_at_memory_decode.sv",
                "rtl/spk286_integration/spk286_at_mister_memory_port.sv",
                "rtl/spk286_integration/spk286_at_sdram_read_buffer.sv",
                "rtl/spk286_integration/spk286_at_sdram_data_buffer.sv",
                "rtl/spk286_integration/spk286_at_mister_sdram_owner.sv",
                "rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv",
                "sim/spk286_integration/spk286_sdram_pin_model.sv", str(generated)]
    macros = (build / "performance-macros.txt").read_text().split()
    obj = build / "ideal-cpu-obj"
    with (build / "ideal-cpu-build.log").open("w") as log:
        subprocess.run(["verilator", "--binary", "--timing", "-j", "4", "-Wno-fatal",
                        *(f"-D{macro}" for macro in macros), "--top-module",
                        "spk286_checkit_workload_tb", "--Mdir", str(obj),
                        "-o", "ideal_cpu_bus", *sources], cwd=ROOT, check=True,
                       stdout=log, stderr=subprocess.STDOUT)
    comparisons = []
    for workload in WORKLOADS:
        reference = records(build / f"{workload}-p03-1.log")
        variants = {}
        for mode in (0, 1):
            path = build / f"{workload}-ideal-cpu-{mode}.log"
            with path.open("w") as log:
                subprocess.run([str(obj / "ideal_cpu_bus"),
                                f"+ROM={build}/checkit-{workload}.rom", f"+NAME={workload}",
                                "+NATIVE=1", "+P03=1", f"+PROFILE={1-mode}",
                                f"+IDEAL_CPU_BUS={mode}"], cwd=ROOT, check=True, stdout=log,
                               stderr=subprocess.STDOUT)
            variants[mode] = records(path)
        assert variants[0] == reference, (workload, "instrumentation changed baseline")
        for key in ("gpr", "flags", "memory"):
            assert variants[1]["PROFILE_SIGNATURE"][key] == reference["PROFILE_SIGNATURE"][key]
        for key in ("retired", "writes"):
            assert variants[1]["CHECKIT_DIRECTED_PASS"][key] == reference["CHECKIT_DIRECTED_PASS"][key]
        physical = int(reference["CHECKIT_DIRECTED_PASS"]["cycles"])
        ideal = int(variants[1]["CHECKIT_DIRECTED_PASS"]["cycles"])
        assert variants[1]["CHECKIT_DIRECTED_PASS"]["external_wait"] == "0"
        comparisons.append({"workload": workload, "physical_cycles": physical,
                            "always_ready_cycles": ideal, "physical_over_ideal": physical/ideal,
                            "gpr_flags_memory_and_retire_write_counts_match": True,
                            "always_ready_signature": variants[1]["PROFILE_SIGNATURE"]})
        print(f"IDEAL_CPU_BUS_PASS {workload}: physical={physical} always_ready={ideal} ratio={physical/ideal:.3f}x",
              flush=True)
    subprocess.run(["sha256sum", "--check", str(receipt)], cwd=ROOT,
                   check=True, stdout=subprocess.DEVNULL)
    (build / "ideal-cpu-bus.json").write_text(json.dumps({
        "note": "Synthetic no-device firmware; same CPU/options, 50MHz, ideal bus is not a hardware proposal.",
        "probe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "generated_harness_sha256": hashlib.sha256(generated.read_bytes()).hexdigest(),
        "performance_macros": macros, "runs": comparisons}, indent=2) + "\n")


if __name__ == "__main__":
    main()
