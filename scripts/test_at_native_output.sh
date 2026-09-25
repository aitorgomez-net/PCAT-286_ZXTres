#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build="${AT_NATIVE_OUTPUT_TEST_OUTPUT:-$root/build/at-native-output/sim}"
mkdir -p "$build"
for setting in '148 3.366 0.0' '74 6.734 1.417' '25 20.0 2.739'; do
  read -r label half phase <<< "$setting"
  iverilog -g2012 -Wall -Wno-timescale -s at_native_output_tb \
    -Pat_native_output_tb.HDMI_HALF_NS="$half" -Pat_native_output_tb.HDMI_PHASE_NS="$phase" \
    -o "$build/test-$label.vvp" \
    "$root/sys/at_cdc_snapshot.sv" "$root/sys/at_video_output_config.sv" \
    "$root/sys/at_hdmi_output.sv" "$root/sim/spk286_integration/at_native_output_tb.sv" \
    >"$build/compile-$label.log" 2>&1
  vvp "$build/test-$label.vvp" | tee "$build/simulation-$label.log"
done
