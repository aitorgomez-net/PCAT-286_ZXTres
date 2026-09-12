#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/at-hps-rom-loader"
mkdir -p "$BUILD_DIR"

iverilog -g2012 -Wall -Wno-timescale \
  -s spk286_at_hps_rom_loader_tb \
  -o "$BUILD_DIR/hps_rom_loader_iv" \
  "$ROOT_DIR/rtl/spk286_integration/spk286_at_hps_rom_loader.sv" \
  "$ROOT_DIR/sim/spk286_integration/spk286_at_hps_rom_loader_tb.sv"
vvp "$BUILD_DIR/hps_rom_loader_iv"

if command -v verilator >/dev/null 2>&1; then
  verilator --binary --timing --Wno-fatal \
    --top-module spk286_at_hps_rom_loader_tb \
    --Mdir "$BUILD_DIR/verilator" \
    "$ROOT_DIR/rtl/spk286_integration/spk286_at_hps_rom_loader.sv" \
    "$ROOT_DIR/sim/spk286_integration/spk286_at_hps_rom_loader_tb.sv"
  "$BUILD_DIR/verilator/Vspk286_at_hps_rom_loader_tb"
fi

echo "AT_HPS_ROM_LOADER_TEST_PASS"
