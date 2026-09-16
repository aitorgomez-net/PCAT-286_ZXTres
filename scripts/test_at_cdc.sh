#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build="$root/build/at-cdc"
mkdir -p "$build"
for tb in at_cdc_snapshot at_osd_cdc at_video_calc_cdc; do
  iverilog -g2012 -Wall -Wno-timescale -s "${tb}_tb" -o "$build/$tb.vvp" \
    "$root/sys/at_cdc_snapshot.sv" "$root/sys/osd.v" "$root/sys/hps_io.sv" \
    "$root/sim/spk286_integration/${tb}_tb.sv" >"$build/$tb.compile.log" 2>&1
  vvp "$build/$tb.vvp" | tee "$build/$tb.log"
done
iverilog -g2012 -s at_cdc_legacy_tb -o "$build/legacy.vvp" \
  "$root/sys/osd.v" "$root/sys/hps_io.sv" \
  "$root/sim/spk286_integration/at_cdc_legacy_tb.sv" >"$build/legacy.compile.log" 2>&1
vvp "$build/legacy.vvp" | tee "$build/legacy.log"
docker run --rm -v "$root:/work" -w /work/build/at-cdc \
  ghdl/ghdl:ubuntu22-llvm-11 bash -lc '
    ghdl -a --std=93 ../../sys/at_cdc_snapshot.vhd ../../sys/ascal.vhd ../../sys/pll_hdmi_adj.vhd &&
    ghdl -a --std=08 ../../sys/at_cdc_snapshot.vhd ../../sys/ascal.vhd ../../sys/pll_hdmi_adj.vhd ../../sim/spk286_integration/at_cdc_vhdl_tb.vhd ../../sim/spk286_integration/at_scaler_cdc_tb.vhd &&
    ghdl -e --std=08 at_cdc_vhdl_tb &&
    ghdl -r --std=08 at_cdc_vhdl_tb --assert-level=error --ieee-asserts=disable --vcd=at_cdc_vhdl.vcd
  ' >"$build/vhdl.log" 2>&1 || { tail -50 "$build/vhdl.log"; exit 1; }
grep AT_CDC_VHDL_PASS "$build/vhdl.log"
python3 "$root/scripts/check_at_cdc_vcd.py" "$build/at_cdc_vhdl.vcd"
