#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=${PCAT_BUILD_DIR:-$root/build/at-profile-bridge}
mkdir -p "$build_dir"
cd "$root"
sources=(rtl/spk286_integration/spk286_at_cpu_profile.sv
         rtl/spk286_integration/spk286_at_bus_bridge.sv
         sim/spk286_integration/spk286_at_profile_bridge_tb.sv)
sha256sum "${sources[@]}" scripts/test_at_profile_bridge.sh > "$build_dir/sources.sha256"
verilator --lint-only --timing --assert -Wall --top-module spk286_at_bus_bridge \
    "${sources[1]}" > "$build_dir/lint.log" 2>&1
iverilog -g2012 -s spk286_at_profile_bridge_tb -o "$build_dir/bridge_iv" \
    "${sources[@]}" > "$build_dir/iverilog-build.log" 2>&1
vvp "$build_dir/bridge_iv" | tee "$build_dir/iverilog-run.log"
verilator --binary --timing --assert -j 2 -Wno-fatal \
    --top-module spk286_at_profile_bridge_tb --Mdir "$build_dir/obj" \
    -o bridge_vlt "${sources[@]}" > "$build_dir/verilator-build.log" 2>&1
"$build_dir/obj/bridge_vlt" | tee "$build_dir/verilator-run.log"
grep -q '^AT_PROFILE_BRIDGE_PASS' "$build_dir/iverilog-run.log"
grep -q '^AT_PROFILE_BRIDGE_PASS' "$build_dir/verilator-run.log"
sha256sum --check "$build_dir/sources.sha256" > "$build_dir/sources-verified.log"
echo AT_PROFILE_BRIDGE_TEST_PASS
