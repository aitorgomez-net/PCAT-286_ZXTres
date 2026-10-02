#!/usr/bin/env bash
# Pin-level CL2/tAC/tOH model at unchanged 50 MHz, two real clock phases.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output=$(realpath -m "${1:-$root/build/at-sdram-phase}")
[[ $# -le 1 && ! -e "$output" ]]
mkdir -p "$output";cd "$root"
sources=(rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv
 rtl/spk286_integration/spk286_at_mister_sdram_owner.sv
 sim/spk286_integration/spk286_sdram_pin_model.sv
 sim/spk286_integration/spk286_at_sdram_entry_tb.sv)
sha256sum "${sources[@]}" scripts/test_at_sdram_phase.sh > "$output/sources.sha256"
top=spk286_at_sdram_entry_tb
for phase in 0 3;do
 stem=$output/advance-$phase;mkdir -p "$stem"
 iverilog -g2012 -s "$top" -P"$top.CHIP_CLK_ADVANCE_NS=$phase" -o "$stem/test.vvp" "${sources[@]}" > "$stem/iverilog-build.log" 2>&1
 timeout 30s vvp "$stem/test.vvp" | tee "$stem/iverilog-run.log"
 verilator --binary --timing --assert -j 2 -Wno-fatal --top-module "$top" -GCHIP_CLK_ADVANCE_NS=$phase --Mdir "$stem/obj" -o directed "${sources[@]}" > "$stem/verilator-build.log" 2>&1
 timeout 30s "$stem/obj/directed" | tee "$stem/verilator-run.log"
 grep '^SDRAM_ENTRY_PASS' "$stem/iverilog-run.log" > "$stem/iverilog-result.txt"
 grep '^SDRAM_ENTRY_PASS' "$stem/verilator-run.log" > "$stem/verilator-result.txt"
 cmp "$stem/iverilog-result.txt" "$stem/verilator-result.txt"
done
sha256sum --check "$output/sources.sha256" > "$output/sources-verified.log"
echo SDRAM_PHASE_DIRECTED_PASS
