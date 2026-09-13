#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-keyboard}"
mkdir -p "$build_dir"
cd "$root"
sources=(
  rtl/spk286_integration/spk286_at_keyboard.sv
  rtl/spk286_integration/spk286_at_8042.sv
  sim/spk286_integration/spk286_at_keyboard_tb.sv
)
iverilog -g2012 -s spk286_at_keyboard_tb -o "$build_dir/keyboard_iv" \
  "${sources[@]}" >"$build_dir/iverilog-build.log" 2>&1
vvp "$build_dir/keyboard_iv" "+TRACE=$build_dir/scan_trace.txt" | tee "$build_dir/iverilog-run.log"
verilator --binary --timing --top-module spk286_at_keyboard_tb -Wno-fatal -j 4 \
  --Mdir "$build_dir/verilator-obj" -o keyboard_vlt \
  "${sources[@]}" >"$build_dir/verilator-build.log" 2>&1
"$build_dir/verilator-obj/keyboard_vlt" "+TRACE=$build_dir/scan_trace_verilator.txt" | tee "$build_dir/verilator-run.log"
cmp "$build_dir/scan_trace.txt" "$build_dir/scan_trace_verilator.txt"
echo AT_KEYBOARD_TEST_PASS
