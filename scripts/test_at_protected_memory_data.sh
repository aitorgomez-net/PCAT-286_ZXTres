#!/usr/bin/env bash
# Verify the actual PCAT vendor, including its retained real-mode IP wrap.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=$(realpath -m "${1:-$root/build/at-protected-memory-data}")
[[ $# -le 1 && ! -e "$build_dir" ]]
mkdir -p "$build_dir"
cd "$root"
mapfile -t sources < <(sed -n 's/.*SYSTEMVERILOG_FILE "\(vendor\/[^\"]*\.sv\)".*/\1/p' \
  rtl/spk286_integration/spk286_integration.qip)
source scripts/at_performance_flags.sh
sha256sum "${sources[@]}" scripts/test_at_protected_memory_data.sh > "$build_dir/sources.sha256"
verilator --lint-only --language 1800-2012 --Wall --top-module spk286 \
  -Ivendor/spk286/rtl "${performance_flags[@]}" "${sources[@]}" > "$build_dir/lint.log" 2>&1
for unit in spk286_call_gate_accessed spk286_double_fault_cpu; do
  top=${unit}_tb
  bench=vendor/spk286/sim/unit/$top.sv
  stem=$build_dir/$unit
  mkdir -p "$stem"
  iverilog -g2012 -Ivendor/spk286/rtl -Ivendor/spk286/sim/unit \
    "${performance_flags[@]}" -s "$top" -o "$stem/test.vvp" \
    "${sources[@]}" "$bench" > "$stem/iverilog-build.log" 2>&1
  vvp "$stem/test.vvp" | tee "$stem/iverilog-run.log"
  verilator --binary --timing --assert --build-jobs 2 --top-module "$top" \
    --Mdir "$stem/obj" -o directed -Ivendor/spk286/rtl -Ivendor/spk286/sim/unit \
    "${performance_flags[@]}" "${sources[@]}" "$bench" > "$stem/verilator-build.log" 2>&1
  "$stem/obj/directed" | tee "$stem/verilator-run.log"
  grep ' PASS:' "$stem/iverilog-run.log" > "$stem/iverilog-result.txt"
  grep ' PASS:' "$stem/verilator-run.log" > "$stem/verilator-result.txt"
  cmp "$stem/iverilog-result.txt" "$stem/verilator-result.txt"
done
sha256sum --check "$build_dir/sources.sha256" > "$build_dir/sources-verified.log"
echo AT_PROTECTED_MEMORY_DATA_DIRECTED_PASS
