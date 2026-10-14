#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PCAT_BUILD_DIR:-$ROOT_DIR/build/at-mister-ddram-owner}"
mkdir -p "$BUILD_DIR"

SOURCES=(
  "$ROOT_DIR/sys/at_cdc_fifo.sv"
  "$ROOT_DIR/rtl/video/ega_ddr_arbiter.v"
  "$ROOT_DIR/rtl/spk286_integration/spk286_at_mister_ddram_owner.sv"
  "$ROOT_DIR/sim/spk286_integration/spk286_at_mister_ddram_owner_tb.sv"
)

iverilog -g2012 -Wall -Wno-timescale \
  -s spk286_at_mister_ddram_owner_tb \
  -o "$BUILD_DIR/ddram_owner_iv" "${SOURCES[@]}"
vvp "$BUILD_DIR/ddram_owner_iv"

if command -v verilator >/dev/null 2>&1; then
  verilator --binary --timing --Wno-fatal \
    --top-module spk286_at_mister_ddram_owner_tb \
    --Mdir "$BUILD_DIR/verilator" "${SOURCES[@]}"
  "$BUILD_DIR/verilator/Vspk286_at_mister_ddram_owner_tb"
fi

echo "AT_MISTER_DDRAM_OWNER_TEST_PASS"
