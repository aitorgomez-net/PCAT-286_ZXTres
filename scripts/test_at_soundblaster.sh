#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-soundblaster}"
mkdir -p "$build_dir"
cd "$root"

sources=(
  rtl/sound/sb_dsp.sv
  rtl/sound/sb_dma_glue.sv
  rtl/sound/sb_mixer.sv
  rtl/sound/sb_volume.sv
  rtl/sound/soundblaster.sv
  rtl/spk286_integration/spk286_at_sound.sv
  rtl/spk286_integration/spk286_at_dma.sv
  sim/spk286_integration/spk286_at_soundblaster_tb.sv
)

iverilog -g2012 -DENABLE_SB=1 -s spk286_at_soundblaster_tb \
  -o "$build_dir/sb_iv" "${sources[@]}" \
  >"$build_dir/iverilog-build.log" 2>&1
vvp "$build_dir/sb_iv" | tee "$build_dir/iverilog-run.log"

verilator --binary --timing -DENABLE_SB=1 --top-module spk286_at_soundblaster_tb \
  -Wno-fatal --Mdir "$build_dir/verilator-obj" -o sb_vlt \
  "${sources[@]}" >"$build_dir/verilator-build.log" 2>&1
"$build_dir/verilator-obj/sb_vlt" | tee "$build_dir/verilator-run.log"

# Detection must also work from CPU bus pins through the machine decoder.
PCAT_BUILD_DIR="$build_dir/machine" bash "$root/scripts/test_at_soundblaster_machine.sh"
