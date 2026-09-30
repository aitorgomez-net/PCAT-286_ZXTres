#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-ega-decode}"
mkdir -p "$build_dir"
cd "$root"
sources=(
  rtl/spk286_integration/spk286_at_video_adapter.sv
  rtl/KFPC-XT/HDL/ega_vram_bram_frontend.sv sys/at_cdc_snapshot.sv
  rtl/video/UM6845R.v rtl/video/video_scandoubler.v
  rtl/video/ega_dot_clock.v rtl/video/ega_gfx_ctrl.v rtl/video/ega_sequencer.v
  rtl/video/ega_attrib_ctrl.v rtl/video/ega_pixel.v rtl/video/ega_text.v
  rtl/video/ega_switch_sense.v rtl/video/ega_vgaport.v rtl/video/ega_vram.v rtl/video/ega_top.v
  sim/spk286_integration/spk286_at_ega_decode_tb.sv
)
verilator --binary --timing -j 4 -Wno-fatal -DPCAT_EGA_ONLY \
  --top-module spk286_at_ega_decode_tb --Mdir "$build_dir/verilator-obj" \
  -o ega_decode_vlt "${sources[@]}" >"$build_dir/verilator-build.log" 2>&1
"$build_dir/verilator-obj/ega_decode_vlt" | tee "$build_dir/verilator-run.log"
