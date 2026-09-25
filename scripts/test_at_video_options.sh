#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build="$root/build/at-video-options"
mkdir -p "$build"
iverilog -g2012 -Wall -Wno-timescale -s at_video_options_cdc_tb -o "$build/options.vvp" \
  "$root/sys/at_cdc_snapshot.sv" \
  "$root/sys/at_scanlines_status.sv" \
  "$root/rtl/spk286_integration/at_video_options_cdc.sv" \
  "$root/sim/spk286_integration/at_video_options_cdc_tb.sv" \
  >"$build/options.compile.log" 2>&1
vvp "$build/options.vvp" | tee "$build/options.log"
