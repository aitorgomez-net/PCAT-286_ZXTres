#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/a5-at-devices}"
mkdir -p "$build_dir"
cd "$root"

sources=(
  rtl/spk286_integration/spk286_at_8042.sv
  rtl/spk286_integration/spk286_at_rtc_cmos.sv
  rtl/spk286_integration/spk286_at_storage_video.sv
  rtl/spk286_integration/spk286_at_video_adapter.sv
  rtl/KFPC-XT/HDL/ega_vram_bram_frontend.sv
  rtl/spk286_integration/spk286_at_device_router.sv
  rtl/spk286_integration/spk286_at_arbiter.sv
  rtl/spk286_integration/spk286_at_dma.sv
  sim/spk286_integration/spk286_at_devices_tb.sv
)
for source in rtl/video/*.v rtl/video/*.sv; do
  sources+=("$source")
done

iverilog -g2012 -s spk286_at_devices_tb \
  -o "$build_dir/a5_iv" "${sources[@]}" \
  >"$build_dir/iverilog-build.log" 2>&1
vvp "$build_dir/a5_iv" | tee "$build_dir/iverilog-run.log"

rm -rf "$build_dir/verilator-obj"
verilator --binary --timing --top-module spk286_at_devices_tb \
  -Wno-fatal --Mdir "$build_dir/verilator-obj" -o a5_vlt \
  "${sources[@]}" >"$build_dir/verilator-build.log" 2>&1
"$build_dir/verilator-obj/a5_vlt" | tee "$build_dir/verilator-run.log"

echo A5_AT_DEVICES_TEST_PASS
