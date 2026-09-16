#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/at-sdram-read-buffer"
mkdir -p "$BUILD_DIR"

iverilog -g2012 -Wall -Wno-timescale \
  -s spk286_at_sdram_read_buffer_tb \
  -o "$BUILD_DIR/read_buffer_iv" \
  "$ROOT_DIR/rtl/spk286_integration/spk286_at_sdram_read_buffer.sv" \
  "$ROOT_DIR/sim/spk286_integration/spk286_at_sdram_read_buffer_tb.sv"
vvp "$BUILD_DIR/read_buffer_iv"

if command -v verilator >/dev/null 2>&1; then
  verilator --binary --timing --Wno-fatal \
    --top-module spk286_at_sdram_read_buffer_tb \
    --Mdir "$BUILD_DIR/verilator" \
    "$ROOT_DIR/rtl/spk286_integration/spk286_at_sdram_read_buffer.sv" \
    "$ROOT_DIR/sim/spk286_integration/spk286_at_sdram_read_buffer_tb.sv"
  "$BUILD_DIR/verilator/Vspk286_at_sdram_read_buffer_tb"
fi

echo "AT_SDRAM_READ_BUFFER_TEST_PASS"
