#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build="${AT_FRAME_TEST_OUTPUT:-$root/build/at-frame-shadowmask}"
mkdir -p "$build"
for tb in at_frame_counter at_shadowmask_cdc; do
  iverilog -g2012 -Wall -Wno-timescale -s "${tb}_tb" -o "$build/$tb.vvp" \
    "$root/sys/at_frame_counter.sv" "$root/sys/at_cdc_snapshot.sv" \
    "$root/sys/shadowmask.sv" "$root/sim/spk286_integration/${tb}_tb.sv" \
    >"$build/$tb.compile.log" 2>&1
  vvp "$build/$tb.vvp" | tee "$build/$tb.log"
done
