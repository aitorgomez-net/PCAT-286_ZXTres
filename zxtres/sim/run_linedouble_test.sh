#!/usr/bin/env bash
# Simulate zxtres_linedouble on a 200-line picture (must be doubled to 31 kHz)
# and on a 350-line one (must pass through).
#
#   zxtres/sim/run_linedouble_test.sh
#
# Run from WSL or Linux with verilator.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcat/linedouble-sim"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_linedouble_tb \
  --Mdir "$out/obj" -o sim \
  \
  mist-modules/scandoubler/scandoubler_framing.v \
  zxtres/rtl/zxtres_linedouble.sv \
  zxtres/sim/zxtres_linedouble_tb.sv > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
"$out/obj/sim" +LINES=200 +PERIOD=4
"$out/obj/sim" +LINES=350 +PERIOD=4
# Scandoubler off: the 200-line picture is not doubled, and leaves with +HSync, +VSync (idle low).
"$out/obj/sim" +LINES=200 +PERIOD=4 +OFF=1

# The VGA 13h TV 60Hz raster of the core itself through the doubler.
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_linedouble_13h_tb \
  --Mdir "$out/obj13" -o sim13 \
  \
  mist-modules/scandoubler/scandoubler_framing.v \
  rtl/video/vga_mode13_timing.v \
  zxtres/rtl/zxtres_linedouble.sv \
  zxtres/sim/zxtres_linedouble_13h_tb.sv > "$out/verilator-build13.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build13.log" | head -20 >&2; exit 1; }
"$out/obj13/sim13"
