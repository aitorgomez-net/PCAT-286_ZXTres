#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-rtc-cmos}"
mkdir -p "$build_dir"
cd "$root"

for top in spk286_at_rtc_cmos_tb spk286_at_rtc_reset_tb; do
  sources=(rtl/spk286_integration/spk286_at_rtc_cmos.sv
           "sim/spk286_integration/$top.sv")
  iverilog -g2012 -s "$top" -o "$build_dir/$top.iv" "${sources[@]}" \
    >"$build_dir/$top.iverilog-build.log" 2>&1
  vvp "$build_dir/$top.iv" | tee "$build_dir/$top.iverilog-run.log"

  verilator --binary --timing --top-module "$top" -Wno-fatal -j 4 \
    --Mdir "$build_dir/$top-obj" -o run "${sources[@]}" \
    >"$build_dir/$top.verilator-build.log" 2>&1
  "$build_dir/$top-obj/run" | tee "$build_dir/$top.verilator-run.log"
done
echo AT_RTC_CMOS_TEST_PASS
