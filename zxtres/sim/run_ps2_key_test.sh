#!/usr/bin/env bash
# Simulate zxtres_ps2_key: set-2 bytes to events, Win+F12 kept from the core
# (zxtres/sim/zxtres_ps2_key_tb.sv). Run from WSL or Linux with verilator.
#
#   zxtres/sim/run_ps2_key_test.sh
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcat/ps2-key-sim"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"
verilator --binary --timing -O1 -Wno-fatal -Wno-lint -Wno-style --top-module zxtres_ps2_key_tb \
  --Mdir "$out/obj" -o ps2_key_sim zxtres/rtl/zxtres_ps2_key.sv zxtres/sim/zxtres_ps2_key_tb.sv \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
"$out/obj/ps2_key_sim"
