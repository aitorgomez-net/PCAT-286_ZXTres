#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-mouse}"
mkdir -p "$build_dir"
cd "$root"

iverilog -g2012 -s msmouse_wrapper_tb \
  -o "$build_dir/msmouse_wrapper.vvp" \
  rtl/common/MSMouseWrapper.v \
  sim/spk286_integration/msmouse_wrapper_tb.sv \
  >"$build_dir/compile.log" 2>&1
vvp "$build_dir/msmouse_wrapper.vvp" | tee "$build_dir/run.log"

iverilog -g2012 -DSPK286_AT_SIM_MODEL -s spk286_at_com1_mouse_tb \
  -o "$build_dir/com1_mouse.vvp" \
  rtl/common/MSMouseWrapper.v \
  rtl/spk286_integration/spk286_at_serial.sv \
  sim/spk286_integration/spk286_at_com1_mouse_tb.sv \
  >"$build_dir/com1-compile.log" 2>&1
vvp "$build_dir/com1_mouse.vvp" | tee "$build_dir/com1-run.log"

echo AT_MOUSE_TEST_PASS
