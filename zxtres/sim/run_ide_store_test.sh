#!/usr/bin/env bash
# Unit test of zxtres/rtl/zxtres_ide_store.sv against the machine's IDE device
# (zxtres/sim/zxtres_ide_store_tb.sv). Needs verilator. Prints
# ZXTRES_IDE_STORE_PASS on success.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcat/ide-store-test"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"

verilator --lint-only -Wall -Wno-DECLFILENAME --top-module zxtres_ide_store zxtres/rtl/zxtres_ide_store.sv
verilator --lint-only -Wall -Wno-DECLFILENAME --top-module zxtres_sd_arb zxtres/rtl/zxtres_sd_arb.sv
verilator --binary --timing -O2 -Wno-fatal --top-module zxtres_ide_store_tb \
  --Mdir "$out/obj" -o ide_store_test \
  zxtres/rtl/zxtres_dpram.sv rtl/common/ide.v zxtres/rtl/zxtres_ide_store.sv \
  zxtres/sim/zxtres_ide_store_tb.sv > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
"$out/obj/ide_store_test" | tee "$out/run.log"
grep -q ZXTRES_IDE_STORE_PASS "$out/run.log"
