#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build="${AT_SCALER_TEST_OUTPUT:-$root/build/at-scaler-avalon}"
mkdir -p "$build"
docker run --rm -v "$root:/work:ro" -v "$build:/results" -w /results \
  ghdl/ghdl:ubuntu22-llvm-11 bash -lc '
    set -e
    ghdl -a --std=93 /work/sys/at_cdc_snapshot.vhd /work/sys/ascal.vhd
    ghdl -a --std=08 /work/sys/at_cdc_snapshot.vhd /work/sys/ascal.vhd /work/sim/spk286_integration/at_scaler_avalon_tb.vhd
    ghdl -e --std=08 at_scaler_avalon_tb
    ghdl -r --std=08 at_scaler_avalon_tb --assert-level=error --ieee-asserts=disable --vcd=progressive.vcd
    ghdl -r --std=08 at_scaler_avalon_tb -gPHASE_NS=3 -gINTERLACED=true --assert-level=error --ieee-asserts=disable --vcd=interlaced.vcd
    ghdl -r --std=08 at_scaler_avalon_tb -gLOCAL_CONFIG=true --assert-level=error --ieee-asserts=disable --vcd=local.vcd
    ghdl -r --std=08 at_scaler_avalon_tb -gLOCAL_CONFIG=true -gPHASE_NS=3 -gINTERLACED=true --assert-level=error --ieee-asserts=disable --vcd=local-interlaced.vcd
    ghdl -r --std=08 at_scaler_avalon_tb -gLOCAL_CONFIG=true -gFILTER_TEST=true --assert-level=error --ieee-asserts=disable --vcd=filter.vcd
    ghdl -r --std=08 at_scaler_avalon_tb -gLOCAL_CONFIG=true -gFILTER_TEST=true -gPHASE_NS=3 -gINTERLACED=true --assert-level=error --ieee-asserts=disable --vcd=filter-interlaced.vcd
  ' >"$build/ghdl.log" 2>&1 || { tail -40 "$build/ghdl.log"; exit 1; }
grep AT_SCALER_AVALON_PASS "$build/ghdl.log"
for mode in progressive interlaced local local-interlaced filter filter-interlaced; do
  python3 "$root/scripts/check_at_scaler_vcd.py" "$build/$mode.vcd" | tee "$build/$mode.log"
done
for mode in filter filter-interlaced; do
  python3 "$root/scripts/check_at_scaler_filter_vcd.py" "$build/$mode.vcd" | tee "$build/$mode-filter.log"
done
