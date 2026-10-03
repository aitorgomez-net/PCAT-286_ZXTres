#!/usr/bin/env bash
# Verify the fixed production bridge/fetch protocol in both simulators.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=${PCAT_BUILD_DIR:-$root/build/at-bus-latency}
mkdir -p "$build_dir"
cd "$root"
PCAT_BUILD_DIR="$build_dir/bridge-production" \
  bash scripts/test_a1_at_bridge.sh > "$build_dir/bridge-production.log" 2>&1
echo 'AT_BUS_LATENCY_BRIDGE_PASS fixed production (Icarus and Verilator)'
source scripts/at_performance_flags.sh
fetch_sources=(vendor/spk286/rtl/spk286_fetch.sv vendor/spk286/sim/unit/spk286_fetch_tb.sv)
iverilog -g2012 "${performance_flags[@]}" -s spk286_fetch_tb \
  -o "$build_dir/fetch_iv" "${fetch_sources[@]}" > "$build_dir/fetch-iv-build.log" 2>&1
vvp "$build_dir/fetch_iv" > "$build_dir/fetch-iv.log"
verilator --binary --timing --assert -Wno-fatal "${performance_flags[@]}" \
  --top-module spk286_fetch_tb --Mdir "$build_dir/fetch-obj" -o fetch_vlt \
  "${fetch_sources[@]}" > "$build_dir/fetch-vlt-build.log" 2>&1
"$build_dir/fetch-obj/fetch_vlt" > "$build_dir/fetch-vlt.log"
echo 'AT_BUS_LATENCY_FETCH_PASS (Icarus and Verilator)'
PCAT_BUILD_DIR="$build_dir/arbiter" bash scripts/test_a2_memory_arbiter.sh > "$build_dir/arbiter.log" 2>&1
PCAT_BUILD_DIR="$build_dir/dma-refresh" bash scripts/test_a4_dma_refresh_pit.sh > "$build_dir/dma-refresh.log" 2>&1
echo AT_BUS_LATENCY_TEST_PASS
