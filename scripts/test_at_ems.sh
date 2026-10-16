#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PCAT_BUILD_DIR:-$ROOT_DIR/build/at-ems}"
mkdir -p "$BUILD_DIR"

SOURCES=(
  "$ROOT_DIR/rtl/spk286_integration/spk286_at_ems.sv"
  "$ROOT_DIR/sim/spk286_integration/spk286_at_ems_tb.sv"
)

iverilog -g2012 -Wno-timescale -s spk286_at_ems_tb \
  -o "$BUILD_DIR/ems_iv" "${SOURCES[@]}"
vvp "$BUILD_DIR/ems_iv" | tee "$BUILD_DIR/ems-iverilog.log"
grep -q AT_EMS_REGISTERS_PASS "$BUILD_DIR/ems-iverilog.log"
# Icarus only: under Verilator 5.020 this bench never reaches $finish.

echo "AT_EMS_TEST_PASS"
