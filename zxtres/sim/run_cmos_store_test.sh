#!/usr/bin/env bash
# Unit test of zxtres/rtl/zxtres_cmos_store.sv against the PC/AT RTC/CMOS
# (zxtres/sim/zxtres_cmos_store_tb.sv). Needs verilator. Prints
# ZXTRES_CMOS_STORE_PASS on success.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcat/cmos-store-test"
cd "$root"
rm -rf "${out:?}"
mkdir -p "$out"

verilator --lint-only -Wall --top-module zxtres_cmos_store zxtres/rtl/zxtres_cmos_store.sv
verilator --binary --timing -O2 -Wno-fatal --top-module zxtres_cmos_store_tb \
  --Mdir "$out/obj" -o cmos_store_test \
  rtl/spk286_integration/spk286_at_rtc_cmos.sv zxtres/rtl/zxtres_cmos_store.sv \
  zxtres/sim/zxtres_cmos_store_tb.sv > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }
"$out/obj/cmos_store_test" | tee "$out/run.log"
grep -q ZXTRES_CMOS_STORE_PASS "$out/run.log"
