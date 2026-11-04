#!/usr/bin/env bash
# Simulate zxtres_vidinfo with the real user_io on a CGA-like raster: the
# controller's read of the video information (command 0x1f) must give the
# line and frame period, the sync widths and the picture size.
#
#   zxtres/sim/run_vidinfo_test.sh
#
# Run from WSL or Linux with verilator.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcat/vidinfo-sim"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"
sed "s/1'b[zZ]/1'b1/g" mist-modules/user_io.v > "$out/user_io.v"
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_vidinfo_tb \
  --Mdir "$out/obj" -o sim \
  zxtres/rtl/zxtres_vidinfo.sv "$out/user_io.v" \
  zxtres/sim/zxtres_vidinfo_tb.sv > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
"$out/obj/sim"
