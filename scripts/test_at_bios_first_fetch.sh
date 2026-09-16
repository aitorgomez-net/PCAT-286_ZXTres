#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-bios-first-fetch}"
rom_path="${AT_SYSTEM_ROM:-$root/tests/firmware/pcat286_event_diag.rom}"
if [[ ! -f "$rom_path" ]]; then
  echo "Required AT_SYSTEM_ROM not found: $rom_path" >&2
  exit 1
fi
rom_path=$(realpath "$rom_path")
mkdir -p "$build_dir"
cd "$root"

# Use the current production CPU/package order (including PM5), rather than
# the pre-PM operand replacement and alphabetical package discovery.
mapfile -t sources < <(
  sed -n 's/.*SYSTEMVERILOG_FILE "\(vendor\/spk286\/[^\"]*\.sv\)".*/\1/p' \
    rtl/spk286_integration/spk286_integration.qip
)
sources+=(
  rtl/common/simple_fifo.v
  rtl/common/floppy.v
  rtl/common/ide.v
  sim/spk286_integration/dpram_model.sv
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
  rtl/spk286_integration/spk286_at_xtide.sv
  rtl/spk286_integration/spk286_at_storage_video.sv
  rtl/spk286_integration/spk286_at_video_adapter.sv
  rtl/KFPC-XT/HDL/ega_vram_bram_frontend.sv
  rtl/spk286_integration/spk286_at_device_router.sv
  rtl/spk286_integration/spk286_at_machine.sv
  rtl/spk286_integration/spk286_at_mister_memory_port.sv
  rtl/spk286_integration/spk286_at_sdram_read_buffer.sv
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
  sim/spk286_integration/spk286_sdram_pin_model.sv
  sim/spk286_integration/spk286_at_bios_first_fetch_tb.sv)
verilator -Irtl/KFPC-XT/HDL/KF8253/HDL --binary --timing --trace-fst --trace-depth 3 \
  -DSPK286_P05_PARALLEL_LIMIT_CHECK \
  --top-module spk286_at_bios_first_fetch_tb -Wno-fatal -j 4 \
  -Irtl/KFPC-XT/HDL/KF8259/HDL --Mdir "$build_dir/verilator-obj" -o first_fetch_vlt \
  "${sources[@]}" "${pic_sources[@]}" \
  >"$build_dir/verilator-build.log" 2>&1
cd "$root/rtl/video" # Resolve the production splash ROM without warnings.
for rom in "$rom_path" \
  "$root/SW/ROMs/pcxt_xtsergey.rom" \
  "$root/SW/ROMs/xtsergey_mod_at.rom" \
  "$root/SW/ROMs/test/Supersoft_Landmark_1.2.0_AT_5170_64K.BIN" \
  "$root/SW/ROMs/test/IBM_AT_5170_15NOV85_62X082x_64K.BIN"; do
  if [[ ! -f "$rom" ]]; then
    echo "AT_BIOS_OPTIONAL_ROM_UNAVAILABLE $rom"
    continue
  fi
  name=$(basename "$rom")
  timeout 120s "$build_dir/verilator-obj/first_fetch_vlt" "+ROM=$rom" \
    "+WAVE=$build_dir/$name.fst" | tee "$build_dir/$name.log"
done
echo AT_BIOS_FIRST_FETCH_TEST_PASS
