#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build="$root/build/at-scaler-config"
mkdir -p "$build"
iverilog -g2012 -Wall -Wno-timescale -s at_scaler_config_tb -o "$build/config.vvp" \
  "$root/sys/at_cdc_snapshot.sv" "$root/sys/math.sv" "$root/sys/at_scaler_config.sv" \
  "$root/sim/spk286_integration/at_scaler_config_tb.sv" >"$build/compile.log" 2>&1
vvp "$build/config.vvp" | tee "$build/simulation.log"
