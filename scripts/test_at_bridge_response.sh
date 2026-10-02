#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=${PCAT_BUILD_DIR:-$root/build/at-bridge-response}
mkdir -p "$build_dir"
cd "$root"
source "$root/scripts/at_performance_flags.sh"

# A frozen reference source can run this identical functional bench. Only
# its measured response latency differs; production has no additional switch.
bridge_rtl=${PCAT_BRIDGE_RTL:-$root/rtl/spk286_integration/spk286_at_bus_bridge.sv}
if [[ ${PCAT_BRIDGE_EXPECT_REGISTERED:-0} == 1 ]]; then
    performance_flags+=(-DEXPECT_REGISTERED_MEMORY_RESPONSE)
fi
sources=("$bridge_rtl" sim/spk286_integration/spk286_at_bus_bridge_response_tb.sv)
printf '%s\n' "${performance_flags[@]}" > "$build_dir/compiler-flags.txt"
sha256sum "${sources[@]}" "$performance_config" \
    scripts/test_at_bridge_response.sh scripts/at_performance_flags.sh \
    "$build_dir/compiler-flags.txt" > "$build_dir/compiled-sources.sha256"
for sample_mode in 0 1; do
    verilator --lint-only --timing --assert -Wall "${performance_flags[@]}" \
        --top-module spk286_at_bus_bridge "-GCOMPLETE_ON_CPU_SAMPLE=1'b$sample_mode" \
        "$bridge_rtl" > "$build_dir/lint-sample-$sample_mode.log" 2>&1
done
iverilog -g2012 "${performance_flags[@]}" -s spk286_at_bus_bridge_response_tb \
    -o "$build_dir/response_iv" "${sources[@]}" > "$build_dir/iverilog-build.log" 2>&1
vvp "$build_dir/response_iv" | tee "$build_dir/iverilog-run.log"
verilator --binary --timing --assert -j 2 -Wno-fatal \
    "${performance_flags[@]}" --top-module spk286_at_bus_bridge_response_tb \
    --Mdir "$build_dir/verilator-obj" -o response_vlt "${sources[@]}" \
    > "$build_dir/verilator-build.log" 2>&1
"$build_dir/verilator-obj/response_vlt" | tee "$build_dir/verilator-run.log"
grep -q '^AT_BRIDGE_RESPONSE_PASS' "$build_dir/iverilog-run.log"
grep -q '^AT_BRIDGE_RESPONSE_PASS' "$build_dir/verilator-run.log"
sha256sum --check "$build_dir/compiled-sources.sha256" > "$build_dir/sources-verified.log"
echo AT_BRIDGE_RESPONSE_TEST_PASS
