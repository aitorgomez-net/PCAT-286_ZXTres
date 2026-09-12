#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/a4-dma-refresh-pit}"
mkdir -p "$build_dir"
cd "$root"

sources=(
  rtl/spk286_integration/spk286_at_dma.sv
  rtl/spk286_integration/spk286_at_refresh.sv
  rtl/spk286_integration/spk286_at_pit.sv
  rtl/spk286_integration/spk286_at_pit_clock.sv
  rtl/spk286_integration/spk286_at_system_control.sv
  rtl/KFPC-XT/HDL/KF8253/HDL/KF8253.sv
  rtl/KFPC-XT/HDL/KF8253/HDL/KF8253_Counter.sv
  rtl/KFPC-XT/HDL/KF8253/HDL/KF8253_Control_Logic.sv
  rtl/spk286_integration/spk286_at_arbiter.sv
  sim/spk286_integration/spk286_at_dma_refresh_pit_tb.sv
)

iverilog -g2012 -Irtl/KFPC-XT/HDL/KF8253/HDL -s spk286_at_dma_refresh_pit_tb \
  -o "$build_dir/a4_iv" "${sources[@]}" \
  >"$build_dir/iverilog-build.log" 2>&1
vvp "$build_dir/a4_iv" | tee "$build_dir/iverilog-run.log"

rm -rf "$build_dir/verilator-obj"
verilator -Irtl/KFPC-XT/HDL/KF8253/HDL --binary --timing --top-module spk286_at_dma_refresh_pit_tb \
  -Wno-fatal --Mdir "$build_dir/verilator-obj" -o a4_vlt \
  "${sources[@]}" >"$build_dir/verilator-build.log" 2>&1
"$build_dir/verilator-obj/a4_vlt" | tee "$build_dir/verilator-run.log"

echo A4_DMA_REFRESH_PIT_TEST_PASS
