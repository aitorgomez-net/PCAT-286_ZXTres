#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/a3-interrupts}"
kf_dir="$root/rtl/KFPC-XT/HDL/KF8259/HDL"
mkdir -p "$build_dir"
cd "$root"

kf_sources=(
  "$kf_dir/KF8259.sv"
  "$kf_dir/KF8259_Bus_Control_Logic.sv"
  "$kf_dir/KF8259_Control_Logic.sv"
  "$kf_dir/KF8259_In_Service.sv"
  "$kf_dir/KF8259_Interrupt_Request.sv"
  "$kf_dir/KF8259_Priority_Resolver.sv"
)
pic_sources=(
  rtl/spk286_integration/spk286_at_pic.sv
  "${kf_sources[@]}"
  sim/spk286_integration/spk286_at_pic_tb.sv
)
pic_model_sources=(
  sim/spk286_integration/spk286_at_pic_model.sv
  sim/spk286_integration/spk286_at_pic_tb.sv
)
nmi_sources=(
  rtl/spk286_integration/spk286_at_nmi_gate.sv
  sim/spk286_integration/spk286_at_nmi_gate_tb.sv
)

# Keep a production-wrapper compile check in Icarus even though its runtime
# is covered below by Verilator.  The imported KF8259 cascade contains a
# historical combinational ACK path that can livelock Icarus delta scheduling.
iverilog -g2012 -I"$kf_dir" -t null -s spk286_at_pic \
  -o "$build_dir/pic-production-iverilog" \
  "${pic_sources[@]:0:${#pic_sources[@]}-1}" \
  >"$build_dir/pic-production-iverilog-build.log" 2>&1

iverilog -g2012 -DA3_PIC_MODEL -s spk286_at_pic_tb \
  -o "$build_dir/pic_iv" "${pic_model_sources[@]}" \
  >"$build_dir/pic-iverilog-build.log" 2>&1
vvp "$build_dir/pic_iv" | tee "$build_dir/pic-iverilog-run.log"

iverilog -g2012 -s spk286_at_nmi_gate_tb \
  -o "$build_dir/nmi_iv" "${nmi_sources[@]}" \
  >"$build_dir/nmi-iverilog-build.log" 2>&1
vvp "$build_dir/nmi_iv" | tee "$build_dir/nmi-iverilog-run.log"

rm -rf "$build_dir/pic-verilator-obj" "$build_dir/nmi-verilator-obj"
verilator --binary --timing --top-module spk286_at_pic_tb \
  -Wno-fatal --Mdir "$build_dir/pic-verilator-obj" -o pic_vlt \
  -I"$kf_dir" "${pic_sources[@]}" \
  >"$build_dir/pic-verilator-build.log" 2>&1
"$build_dir/pic-verilator-obj/pic_vlt" | tee "$build_dir/pic-verilator-run.log"

verilator --binary --timing --top-module spk286_at_nmi_gate_tb \
  -Wno-fatal --Mdir "$build_dir/nmi-verilator-obj" -o nmi_vlt \
  "${nmi_sources[@]}" \
  >"$build_dir/nmi-verilator-build.log" 2>&1
"$build_dir/nmi-verilator-obj/nmi_vlt" | tee "$build_dir/nmi-verilator-run.log"

echo A3_INTERRUPT_TEST_PASS
