#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-serial}"
mkdir -p "$build_dir"
cd "$root"

iverilog -g2012 -DSPK286_AT_SIM_MODEL \
  -s spk286_at_serial_tb \
  -o "$build_dir/serial_iv" \
  rtl/spk286_integration/spk286_at_serial.sv \
  sim/spk286_integration/spk286_at_serial_tb.sv \
  >"$build_dir/iverilog-build.log" 2>&1
(cd "$root/rtl/video" && vvp "$build_dir/serial_iv") \
  | tee "$build_dir/iverilog-run.log"

echo AT_SERIAL_TEST_PASS
