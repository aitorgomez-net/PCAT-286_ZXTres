#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-landmark-dma}"
rom_path="${AT_SYSTEM_ROM:-$root/SW/ROMs/test/Supersoft_Landmark_1.2.0_AT_5170_SKIP_PM_64K.BIN}"
if [[ ! -f "$rom_path" ]]; then
  echo "Required AT_SYSTEM_ROM not found: $rom_path" >&2
  exit 1
fi
rom_path=$(realpath "$rom_path")
mkdir -p "$build_dir"
cd "$root"

sources=(
  vendor/spk286/microcode/generated/spk286_microcode_pkg.sv
  vendor/spk286/microcode/generated/spk286_microcode_rom.sv
  vendor/spk286/rtl/spk286_protected_pkg.sv
  vendor/spk286/rtl/spk286_tss_pkg.sv
)
for source in vendor/spk286/rtl/*.sv; do
  case "$source" in
    vendor/spk286/rtl/spk286_protected_pkg.sv|\
    vendor/spk286/rtl/spk286_tss_pkg.sv)
      ;;
    *) sources+=("$source") ;;
  esac
done
sources+=(
  rtl/common/simple_ram.v
  rtl/common/simple_fifo.v
  rtl/common/floppy.v
  rtl/common/ide.v
  sim/spk286_integration/dpram_model.sv
  rtl/spk286_integration/spk286_machine_cpu.sv
  rtl/spk286_integration/spk286_at_bus_bridge.sv
  rtl/spk286_integration/spk286_at_memory_decode.sv
  rtl/spk286_integration/spk286_at_arbiter.sv
  rtl/spk286_integration/spk286_at_pic.sv
  "${AT_DMA_SOURCE:-rtl/spk286_integration/spk286_at_dma.sv}"
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
  rtl/spk286_integration/spk286_at_xtide.sv
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

sources+=(rtl/spk286_integration/spk286_at_hps_rom_loader.sv
  rtl/spk286_integration/spk286_at_boot_trace.sv
  rtl/spk286_integration/spk286_at_ram_trace.sv
  sim/spk286_integration/spk286_sdram_pin_model.sv
  sim/spk286_integration/spk286_at_bios_first_fetch_tb.sv)
verilator -DSPK286_P05_PARALLEL_LIMIT_CHECK -DSPK286_AT_NO_DEBUG \
  -Irtl/KFPC-XT/HDL/KF8253/HDL --binary --timing --trace-fst --trace-depth 3 \
  --top-module spk286_at_bios_first_fetch_tb -Wno-fatal -j 4 \
  -Irtl/KFPC-XT/HDL/KF8259/HDL --Mdir "$build_dir/verilator-obj" -o first_fetch_vlt \
  "${sources[@]}" "${pic_sources[@]}" \
  >"$build_dir/verilator-build.log" 2>&1
cd "$root/rtl/video" # Resolve the production splash ROM without warnings.
# These run the original DMA2/page routines independently, using a test-only
# reset-vector entry selection. They do not skip tests in the deployed BIOS.
for scenario in ${AT_LANDMARK_CASES:-1 2}; do
  timeout "${AT_LANDMARK_TIMEOUT:-120s}" stdbuf -oL "$build_dir/verilator-obj/first_fetch_vlt" "+ROM=$rom_path" \
    "+LANDMARK_CASE=$scenario" | tee "$build_dir/case-$scenario.log"
done
echo AT_LANDMARK_DMA_TEST_PASS
