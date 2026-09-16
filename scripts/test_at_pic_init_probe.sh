#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-pic-init-probe}"
mkdir -p "$build_dir"
cd "$root"

sources=(
  sim/spk286_integration/spk286_at_pic_init_probe_tb.sv
  rtl/spk286_integration/spk286_at_pic.sv
  rtl/KFPC-XT/HDL/KF8259/HDL/*.sv
)
includes=(-Irtl/KFPC-XT/HDL/KF8259/HDL)

# Verilator is used deliberately: the Icarus simulation of the imported
# KF8259 INTA handshake can remain in a delta-cycle loop, while the RTL
# itself is exercised correctly by Verilator.
verilator --binary --timing -Wno-fatal "${includes[@]}" \
  --top-module spk286_at_pic_init_probe_tb \
  --Mdir "$build_dir/verilator-obj" -o pic_init_vlt \
  "${sources[@]}" >"$build_dir/verilator-build.log" 2>&1

(cd "$root/rtl/video" && "$build_dir/verilator-obj/pic_init_vlt") \
  | tee "$build_dir/verilator-run.log"
echo AT_PIC_INIT_PROBE_TEST_PASS
