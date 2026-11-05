#!/usr/bin/env bash
# A real PS/2 mouse on the ZXTRES mouse port against the guest's serial mouse
# converter (zxtres/sim/zxtres_mouse_tb.sv). Needs Icarus Verilog.
#
#   zxtres/sim/run_mouse_test.sh
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcat/mouse-sim"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"
iverilog -g2012 -s zxtres_mouse_tb -o "$out/mouse_sim" \
  rtl/common/MSMouseWrapper.v zxtres/sim/zxtres_mouse_tb.sv
vvp "$out/mouse_sim" | tee "$out/run.log"
grep -q ZXTRES_MOUSE_PASS "$out/run.log"
