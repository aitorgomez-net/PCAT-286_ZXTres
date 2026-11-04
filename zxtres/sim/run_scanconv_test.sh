#!/usr/bin/env bash
# Simulate zxtres_scanconv with the SRAM controller and an SRAM model: a
# 640x350 picture must come out as 720x480 at 27 MHz (480p), as the two
# fields of a 15.7 kHz 480i raster or as a 240p one, intact and centred, and
# a 200-line one must not be converted.
#
#   zxtres/sim/run_scanconv_test.sh
#
# Run from WSL or Linux with verilator and python3. Frames go to
# build/zxtres-pcat/scanconv-sim.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcat/scanconv-sim"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_scanconv_tb \
  --Mdir "$out/obj" -o sim \
  zxtres/rtl/zxtres_sram_ctrl.sv zxtres/rtl/zxtres_scanconv.sv \
  zxtres/sim/zxtres_sram_model.sv zxtres/sim/zxtres_scanconv_tb.sv > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
for args in "350 640 0" "350 720 0" "200 640 0" "350 640 2" "350 720 2" "350 640 3" "200 640 2"             "350 640 2 9 5" "350 640 3 15 7"; do
  set -- $args
  (cd "$out" && ./obj/sim +LINES=$1 +WIDTH=$2 +MODE=$3 +CRTH=${4:-0} +CRTV=${5:-0})
  python3 zxtres/scripts/ppm_to_png.py "$out/scanconv_$1_$2_m$3.ppm" "$out/scanconv_$1_$2_m$3.png"
done
