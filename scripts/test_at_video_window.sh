#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-video-window}"
mkdir -p "$build_dir"
cd "$root"

sources=(
  rtl/spk286_integration/spk286_at_video_adapter.sv
  rtl/KFPC-XT/HDL/ega_vram_bram_frontend.sv
  sys/at_cdc_snapshot.sv
  rtl/video/UM6845R.v rtl/video/ega_*.v rtl/video/vga_*.v
  rtl/video/video_scandoubler.v
  sim/spk286_integration/spk286_at_video_window_tb.sv
)
verilator --binary --timing -j 4 -Wno-fatal \
  --top-module spk286_at_video_window_tb --Mdir "$build_dir/verilator-obj" \
  -o video_window_vlt "${sources[@]}" >"$build_dir/verilator-build.log" 2>&1
(cd "$root/rtl/video" && "$build_dir/verilator-obj/video_window_vlt") \
  | tee "$build_dir/verilator-run.log"
