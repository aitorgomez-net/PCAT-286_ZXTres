#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/a2-memory-arbiter}"
mkdir -p "$build_dir"
cd "$root"

memory_sources=(
  rtl/spk286_integration/spk286_at_memory_decode.sv
  sim/spk286_integration/spk286_at_memory_decode_tb.sv
)
arbiter_sources=(
  rtl/spk286_integration/spk286_at_arbiter.sv
  sim/spk286_integration/spk286_at_arbiter_tb.sv
)

iverilog -g2012 -s spk286_at_memory_decode_tb \
  -o "$build_dir/memory_iv" "${memory_sources[@]}" \
  >"$build_dir/memory-iverilog-build.log" 2>&1
vvp "$build_dir/memory_iv" | tee "$build_dir/memory-iverilog-run.log"

iverilog -g2012 -s spk286_at_arbiter_tb \
  -o "$build_dir/arbiter_iv" "${arbiter_sources[@]}" \
  >"$build_dir/arbiter-iverilog-build.log" 2>&1
vvp "$build_dir/arbiter_iv" | tee "$build_dir/arbiter-iverilog-run.log"

rm -rf "$build_dir/memory-verilator-obj" "$build_dir/arbiter-verilator-obj"
verilator --binary --timing --top-module spk286_at_memory_decode_tb \
  -Wno-fatal --Mdir "$build_dir/memory-verilator-obj" -o memory_vlt \
  "${memory_sources[@]}" >"$build_dir/memory-verilator-build.log" 2>&1
"$build_dir/memory-verilator-obj/memory_vlt" | tee "$build_dir/memory-verilator-run.log"

verilator --binary --timing --top-module spk286_at_arbiter_tb \
  -Wno-fatal --Mdir "$build_dir/arbiter-verilator-obj" -o arbiter_vlt \
  "${arbiter_sources[@]}" >"$build_dir/arbiter-verilator-build.log" 2>&1
"$build_dir/arbiter-verilator-obj/arbiter_vlt" | tee "$build_dir/arbiter-verilator-run.log"

echo A2_MEMORY_ARBITER_TEST_PASS
