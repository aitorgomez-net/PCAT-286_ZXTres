#!/usr/bin/env bash
# Unit test of zxtres/rtl/zxtres_fdd_store.sv against the machine's floppy
# controller (zxtres/sim/zxtres_fdd_store_tb.sv). Needs verilator. Prints
# ZXTRES_FDD_STORE_PASS on success.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcat/fdd-store-test"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"

verilator --lint-only -Wall -Wno-DECLFILENAME --top-module zxtres_fdd_store zxtres/rtl/zxtres_fdd_store.sv
verilator --binary --timing -O2 -Wno-fatal --top-module zxtres_fdd_store_tb \
  --Mdir "$out/obj" -o fdd_store_test \
  rtl/common/simple_fifo.v rtl/common/floppy.v \
  zxtres/rtl/zxtres_fdd_store.sv zxtres/sim/zxtres_fdd_store_tb.sv \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
"$out/obj/fdd_store_test" | tee "$out/run.log"
grep -q ZXTRES_FDD_STORE_PASS "$out/run.log"
