#!/usr/bin/env bash
# Simulate zxtres_osd on a 640x400 and a 640x200 picture with three menu
# pages and four box positions, and save the frames as
# build/zxtres-pcat/osd-sim/osd_<lines>_p<page>[_pos<n>].png.
#
#   zxtres/sim/run_osd_test.sh
#
# Run from WSL or Linux with verilator and python3.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcat/osd-sim"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"
python3 zxtres/scripts/make_mem.py osdfont rtl/common/font0.hex "$out/osd_font.mem"
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_osd_tb \
  --Mdir "$out/obj" -o osd_sim zxtres/rtl/zxtres_osd.sv zxtres/sim/zxtres_osd_tb.sv \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
for lines in 400 200; do
  for page in 0 1 2; do
    (cd "$out" && ./obj/osd_sim +LINES=$lines +PAGE=$page)
  done
  for pos in 1 2 3 4; do
    (cd "$out" && ./obj/osd_sim +LINES=$lines +PAGE=0 +POS=$pos)
  done
done
for frame in "$out"/*.ppm; do
  python3 zxtres/scripts/ppm_to_png.py "$frame" "${frame%.ppm}.png"
done
ls "$out"/*.png
