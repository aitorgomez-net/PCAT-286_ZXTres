#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build="${AT_HDMI_VSYNC_OUTPUT:-$root/build/at-hdmi-controls/vsync}"
mkdir -p "$build"
iverilog -g2012 -Wall -Wno-timescale -s at_hdmi_vsync_tb -o "$build/test.vvp" \
  "$root/sys/at_hdmi_vsync.sv" "$root/sim/spk286_integration/at_hdmi_vsync_tb.sv" \
  >"$build/compile.log" 2>&1
vvp "$build/test.vvp" | tee "$build/simulation.log"
