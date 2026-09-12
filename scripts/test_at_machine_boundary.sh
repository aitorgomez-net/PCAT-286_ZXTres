#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-machine-boundary}"
rom_path="${AT_SYSTEM_ROM:-$root/tests/firmware/pcat286_event_diag.rom}"
mkdir -p "$build_dir"
cd "$root"

sources=(
  vendor/spk286/microcode/generated/spk286_microcode_pkg.sv
  vendor/spk286/microcode/generated/spk286_microcode_rom.sv
)
for source in vendor/spk286/rtl/*.sv; do
  [[ "$source" == "vendor/spk286/rtl/spk286_operand.sv" ]] || sources+=("$source")
done
sources+=(
  rtl/common/simple_ram.v
  rtl/common/simple_fifo.v
  rtl/common/floppy.v
  rtl/spk286_integration/spk286_operand_timing.sv
  rtl/spk286_integration/spk286_machine_cpu.sv
  rtl/spk286_integration/spk286_at_bus_bridge.sv
  rtl/spk286_integration/spk286_at_memory_decode.sv
  rtl/spk286_integration/spk286_at_arbiter.sv
  rtl/spk286_integration/spk286_at_pic.sv
  rtl/spk286_integration/spk286_at_dma.sv
  rtl/spk286_integration/spk286_at_refresh.sv
  rtl/spk286_integration/spk286_at_pit.sv
  rtl/spk286_integration/spk286_at_pit_clock.sv
  rtl/spk286_integration/spk286_at_system_control.sv
  rtl/KFPC-XT/HDL/KF8253/HDL/KF8253.sv
  rtl/KFPC-XT/HDL/KF8253/HDL/KF8253_Counter.sv
  rtl/KFPC-XT/HDL/KF8253/HDL/KF8253_Control_Logic.sv
  rtl/spk286_integration/spk286_at_8042.sv
  rtl/spk286_integration/spk286_at_rtc_cmos.sv
  rtl/spk286_integration/spk286_at_fdc.sv
  rtl/spk286_integration/spk286_at_storage_video.sv
  rtl/spk286_integration/spk286_at_video_adapter.sv
  rtl/KFPC-XT/HDL/ega_vram_bram_frontend.sv
  rtl/spk286_integration/spk286_at_device_router.sv
  rtl/spk286_integration/spk286_at_machine.sv
  rtl/spk286_integration/spk286_at_mister_memory_port.sv
  rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv
  rtl/spk286_integration/spk286_at_mister_sdram_owner.sv
)
for source in rtl/video/*.v rtl/video/*.sv; do
  sources+=("$source")
done
pic_sources=()
for source in rtl/KFPC-XT/HDL/KF8259/HDL/*.sv; do
  pic_sources+=("$source")
done

iverilog -g2012 -Irtl/KFPC-XT/HDL/KF8253/HDL -t null -Irtl/KFPC-XT/HDL/KF8259/HDL \
  -s spk286_at_machine "${sources[@]}" "${pic_sources[@]}" \
  >"$build_dir/iverilog-build.log" 2>&1
echo AT_MACHINE_ICARUS_ELAB_PASS

verilator -Irtl/KFPC-XT/HDL/KF8253/HDL --lint-only --timing --top-module spk286_at_machine \
  -Wno-fatal -Irtl/KFPC-XT/HDL/KF8259/HDL \
  "${sources[@]}" "${pic_sources[@]}" \
  >"$build_dir/verilator-production-lint.log" 2>&1
echo AT_MACHINE_PRODUCTION_LINT_PASS

rm -rf "$build_dir/verilator-obj"
verilator -Irtl/KFPC-XT/HDL/KF8253/HDL --binary --timing -DAT_MACHINE_PIC_MODEL \
  --top-module spk286_at_machine_tb \
  -Wno-fatal -Irtl/KFPC-XT/HDL/KF8259/HDL \
  --Mdir "$build_dir/verilator-obj" -o at_machine_vlt \
  "${sources[@]}" sim/spk286_integration/spk286_at_machine_pic_model.sv \
  sim/spk286_integration/spk286_at_machine_tb.sv \
  >"$build_dir/verilator-build.log" 2>&1
(cd "$root/rtl/video" && timeout 120s "$build_dir/verilator-obj/at_machine_vlt" "+ROM=$rom_path" \
  "+MAX_CYCLES=${AT_SYSTEM_MAX_CYCLES:-2000000}") \
  | tee "$build_dir/verilator-run.log"

echo AT_MACHINE_BOUNDARY_TEST_PASS
