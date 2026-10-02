#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output=$(realpath -m "${1:-$root/build/at-sdram-entry}")
[[ $# -le 1 && ! -e "$output" ]]
mkdir -p "$output"
cd "$root"
sources=(rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv
         rtl/spk286_integration/spk286_at_mister_sdram_owner.sv
         sim/spk286_integration/spk286_sdram_pin_model.sv
         sim/spk286_integration/spk286_at_sdram_entry_tb.sv)
sha256sum "${sources[@]}" scripts/test_at_sdram_entry.sh > "$output/sources.sha256"
top=spk286_at_sdram_entry_tb
# Existing KFSDRAM has no timescale, four benign width extensions and an
# unused legacy timing parameter. Owner metadata/byte-address bit 0 are also
# intentionally unused. Keep warnings fatal except these recorded classes.
verilator --lint-only -Wall --top-module spk286_at_mister_sdram_owner \
  -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  "${sources[@]:0:2}" > "$output/lint.log" 2>&1
iverilog -g2012 -s "$top" -o "$output/test.vvp" "${sources[@]}" > "$output/iverilog-build.log" 2>&1
timeout 30s vvp "$output/test.vvp" | tee "$output/iverilog-run.log"
verilator --binary --timing --assert -j 2 -Wno-fatal --top-module "$top" \
  --Mdir "$output/obj" -o directed "${sources[@]}" > "$output/verilator-build.log" 2>&1
timeout 30s "$output/obj/directed" | tee "$output/verilator-run.log"
grep '^SDRAM_ENTRY_PASS' "$output/iverilog-run.log" > "$output/iverilog-result.txt"
grep '^SDRAM_ENTRY_PASS' "$output/verilator-run.log" > "$output/verilator-result.txt"
cmp "$output/iverilog-result.txt" "$output/verilator-result.txt"
sha256sum --check "$output/sources.sha256" > "$output/sources-verified.log"
echo SDRAM_ENTRY_DIRECTED_PASS
