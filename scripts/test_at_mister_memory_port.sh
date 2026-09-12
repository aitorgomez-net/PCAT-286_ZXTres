#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/at-mister-memory-port"
mkdir -p "$BUILD_DIR"

iverilog -g2012 -Wall -Wno-timescale \
  -s spk286_at_mister_memory_port_tb \
  -o "$BUILD_DIR/memory_port_iv" \
  "$ROOT_DIR/rtl/spk286_integration/spk286_at_mister_memory_port.sv" \
  "$ROOT_DIR/sim/spk286_integration/spk286_at_mister_memory_port_tb.sv"
vvp "$BUILD_DIR/memory_port_iv"

if command -v verilator >/dev/null 2>&1; then
  verilator --binary --timing --Wno-fatal \
    --top-module spk286_at_mister_memory_port_tb \
    --Mdir "$BUILD_DIR/verilator" \
    "$ROOT_DIR/rtl/spk286_integration/spk286_at_mister_memory_port.sv" \
    "$ROOT_DIR/sim/spk286_integration/spk286_at_mister_memory_port_tb.sv"
  "$BUILD_DIR/verilator/Vspk286_at_mister_memory_port_tb"
fi

echo "AT_MISTER_MEMORY_PORT_TEST_PASS"
