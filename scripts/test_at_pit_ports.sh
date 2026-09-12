#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build="${PCAT_BUILD_DIR:-$root/build/at-pit-ports}"
mkdir -p "$build"
cd "$root"
for test in rtc_reset rtc_cmos pit_clock pit_ports; do
  src=(rtl/spk286_integration/spk286_at_rtc_cmos.sv
       rtl/spk286_integration/spk286_at_pit_clock.sv
       rtl/spk286_integration/spk286_at_system_control.sv
       "${AT_PIT_SOURCE:-rtl/spk286_integration/spk286_at_pit.sv}"
       rtl/KFPC-XT/HDL/KF8253/HDL/KF8253.sv
       rtl/KFPC-XT/HDL/KF8253/HDL/KF8253_Counter.sv
       rtl/KFPC-XT/HDL/KF8253/HDL/KF8253_Control_Logic.sv
       "sim/spk286_integration/spk286_at_${test}_tb.sv")
  top="spk286_at_${test}_tb"
  iverilog -g2012 -Irtl/KFPC-XT/HDL/KF8253/HDL -s "$top" -o "$build/${test}_iv" "${src[@]}" >"$build/$test-iverilog-build.log" 2>&1
  vvp "$build/${test}_iv" | tee "$build/$test-iverilog.log"
  verilator --binary --timing -Wno-fatal -j 4 -Irtl/KFPC-XT/HDL/KF8253/HDL \
    --top-module "$top" --Mdir "$build/$test-obj" -o run "${src[@]}" >"$build/$test-verilator-build.log" 2>&1
  "$build/$test-obj/run" | tee "$build/$test-verilator.log"
done
echo AT_PIT_PORTS_TEST_PASS
