#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/at-splash-control"
mkdir -p "$BUILD_DIR"

iverilog -g2012 -Wall -Wno-timescale \
  -s spk286_at_splash_control_tb \
  -o "$BUILD_DIR/splash_control_iv" \
  "$ROOT_DIR/rtl/spk286_integration/spk286_at_splash_control.sv" \
  "$ROOT_DIR/vendor/spk286/rtl/spk286_fetch.sv" \
  "$ROOT_DIR/sim/spk286_integration/spk286_at_splash_control_tb.sv"
vvp "$BUILD_DIR/splash_control_iv"

if command -v verilator >/dev/null 2>&1; then
  verilator --binary --timing --Wno-fatal \
    --top-module spk286_at_splash_control_tb \
    --Mdir "$BUILD_DIR/verilator" \
    "$ROOT_DIR/rtl/spk286_integration/spk286_at_splash_control.sv" \
    "$ROOT_DIR/vendor/spk286/rtl/spk286_fetch.sv" \
    "$ROOT_DIR/sim/spk286_integration/spk286_at_splash_control_tb.sv"
  "$BUILD_DIR/verilator/Vspk286_at_splash_control_tb"
fi

echo "AT_SPLASH_CONTROL_TEST_PASS"
