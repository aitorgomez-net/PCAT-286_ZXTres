#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-pit-irq0}"
mkdir -p "$build_dir"
cd "$root"

sources=(
  rtl/spk286_integration/spk286_at_pit.sv
  rtl/KFPC-XT/HDL/KF8253/HDL/*.sv
  sim/spk286_integration/spk286_at_pit_irq0_tb.sv
)
includes=(-Irtl/KFPC-XT/HDL/KF8253/HDL)
iverilog -g2012 "${includes[@]}" -s spk286_at_pit_irq0_tb \
  -o "$build_dir/pit_irq0_iv" "${sources[@]}"
(cd "$root/rtl/video" && vvp "$build_dir/pit_irq0_iv")
echo AT_PIT_IRQ0_TEST_PASS
