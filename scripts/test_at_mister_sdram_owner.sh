#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/at-mister-sdram-owner"
mkdir -p "$BUILD_DIR"

iverilog -g2012 -Wall -Wno-timescale \
  -s spk286_at_mister_sdram_owner_tb \
  -o "$BUILD_DIR/sdram_owner_iv" \
  "$ROOT_DIR/rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv" \
  "$ROOT_DIR/rtl/spk286_integration/spk286_at_mister_sdram_owner.sv" \
  "$ROOT_DIR/sim/spk286_integration/spk286_at_mister_sdram_owner_tb.sv"
vvp "$BUILD_DIR/sdram_owner_iv"

if command -v verilator >/dev/null 2>&1; then
  verilator --binary --timing --Wno-fatal \
    --top-module spk286_at_mister_sdram_owner_tb \
    --Mdir "$BUILD_DIR/verilator" \
    "$ROOT_DIR/rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv" \
    "$ROOT_DIR/rtl/spk286_integration/spk286_at_mister_sdram_owner.sv" \
    "$ROOT_DIR/sim/spk286_integration/spk286_at_mister_sdram_owner_tb.sv"
  "$BUILD_DIR/verilator/Vspk286_at_mister_sdram_owner_tb"
fi

echo "AT_MISTER_SDRAM_OWNER_TEST_PASS"
