#!/usr/bin/env bash
# Verify the retained AT protocol in reference, P01/P02 and production modes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=${PCAT_BUILD_DIR:-$root/build/at-bus-latency}
mkdir -p "$build_dir"
cd "$root"
sed '/SPK286_P01_/d; /SPK286_P02_/d; /SPK286_P06_/d' config.tcl > "$build_dir/reference.tcl"
sed '/SPK286_P06_/d' config.tcl > "$build_dir/p01-p02.tcl"
for profile in reference p01-p02 production; do
  config="$build_dir/$profile.tcl"
  if [[ $profile == production ]]; then config="$root/config.tcl"; fi
  PCAT_PERF_CONFIG="$config" PCAT_BUILD_DIR="$build_dir/bridge-$profile" \
    bash scripts/test_a1_at_bridge.sh > "$build_dir/bridge-$profile.log" 2>&1
  echo "AT_BUS_LATENCY_BRIDGE_PASS $profile (Icarus and Verilator)"
done
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
