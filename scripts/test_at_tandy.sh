#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-tandy}"
mkdir -p "$build_dir"
cd "$root"

sources=(
  rtl/sound/jt89/hdl/jt89_noise.v
  rtl/sound/jt89/hdl/jt89_tone.v
  rtl/sound/jt89/hdl/jt89_mixer.v
  rtl/sound/jt89/hdl/jt89_vol.v
  rtl/sound/jt89/hdl/jt89.v
  rtl/spk286_integration/spk286_at_sound.sv
  sim/spk286_integration/spk286_at_tandy_tb.sv
)

iverilog -g2012 -DENABLE_TANDY_AUDIO=1 -s spk286_at_tandy_tb \
  -o "$build_dir/tandy_iv" "${sources[@]}" \
  >"$build_dir/iverilog-build.log" 2>&1
vvp "$build_dir/tandy_iv" | tee "$build_dir/iverilog-run.log"

verilator --binary --timing -DENABLE_TANDY_AUDIO=1 --top-module spk286_at_tandy_tb \
  -Wno-fatal --Mdir "$build_dir/verilator-obj" -o tandy_vlt \
  "${sources[@]}" >"$build_dir/verilator-build.log" 2>&1
"$build_dir/verilator-obj/tandy_vlt" | tee "$build_dir/verilator-run.log"

# The machine decoder must admit 1E0h instead of sinking it as unmapped I/O.
PCAT_BUILD_DIR="$build_dir/machine" bash "$root/scripts/test_at_tandy_machine.sh"
