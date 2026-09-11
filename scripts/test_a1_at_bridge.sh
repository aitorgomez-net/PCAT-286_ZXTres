#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/a1-at-bridge}"
mkdir -p "$build_dir"
cd "$root"

sources=(
  rtl/spk286_integration/spk286_at_bus_bridge.sv
  sim/spk286_integration/spk286_at_bus_bridge_tb.sv
)

iverilog -g2012 -s spk286_at_bus_bridge_tb \
  -o "$build_dir/at-bridge_iv" "${sources[@]}" \
  >"$build_dir/iverilog-build.log" 2>&1
vvp "$build_dir/at-bridge_iv" | tee "$build_dir/iverilog-run.log"

rm -rf "$build_dir/verilator-obj"
verilator --binary --timing --top-module spk286_at_bus_bridge_tb \
  -Wno-fatal --Mdir "$build_dir/verilator-obj" -o at_bridge_vlt \
  "${sources[@]}" >"$build_dir/verilator-build.log" 2>&1
"$build_dir/verilator-obj/at_bridge_vlt" | tee "$build_dir/verilator-run.log"

if command -v rg >/dev/null 2>&1; then
  search_pass() { rg -q 'A1_AT_BRIDGE_PASS' "$1"; }
else
  search_pass() { grep -q 'A1_AT_BRIDGE_PASS' "$1"; }
fi

if ! search_pass "$build_dir/iverilog-run.log"; then
  echo "Icarus AT bridge test did not report PASS" >&2
  exit 1
fi
if ! search_pass "$build_dir/verilator-run.log"; then
  echo "Verilator AT bridge test did not report PASS" >&2
  exit 1
fi

echo A1_AT_BRIDGE_TEST_PASS
