#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-tandy-machine}"
mkdir -p "$build_dir"
cd "$root"

sources=(
  sim/spk286_integration/spk286_cpu_bus_driver.sv
  sim/spk286_integration/dpram_model.sv
  rtl/common/simple_fifo.v
  rtl/common/floppy.v rtl/common/ide.v
  rtl/spk286_integration/spk286_at_bus_bridge.sv
  rtl/spk286_integration/spk286_at_memory_decode.sv
  rtl/spk286_integration/spk286_at_arbiter.sv
  rtl/spk286_integration/spk286_at_pic.sv
  rtl/spk286_integration/spk286_at_dma.sv
  rtl/spk286_integration/spk286_at_refresh.sv
  rtl/spk286_integration/spk286_at_pit.sv
  rtl/spk286_integration/spk286_at_system_control.sv
  rtl/spk286_integration/spk286_at_8042.sv
  rtl/spk286_integration/spk286_at_ems.sv
  rtl/spk286_integration/spk286_at_rtc_cmos.sv
  rtl/spk286_integration/spk286_at_fdc.sv
  rtl/spk286_integration/spk286_at_xtide.sv
  rtl/spk286_integration/spk286_at_storage_video.sv
  sys/at_cdc_snapshot.sv
  rtl/spk286_integration/spk286_at_video_adapter.sv
  rtl/spk286_integration/at286ctl.sv
  rtl/KFPC-XT/HDL/ega_vram_bram_frontend.sv
  rtl/common/tandy_pcjr_joy.sv
  rtl/spk286_integration/spk286_at_gameport.sv
  rtl/spk286_integration/spk286_at_sound.sv
  rtl/spk286_integration/spk286_at_serial.sv
  rtl/spk286_integration/spk286_at_device_router.sv
  rtl/spk286_integration/spk286_at_cpu_profile.sv
  rtl/spk286_integration/spk286_at_machine.sv
  rtl/KFPC-XT/HDL/KF8253/HDL/*.sv
  rtl/KFPC-XT/HDL/KF8259/HDL/*.sv
  rtl/video/*.v rtl/video/*.sv
  rtl/sound/jt89/hdl/jt89_noise.v rtl/sound/jt89/hdl/jt89_tone.v
  rtl/sound/jt89/hdl/jt89_mixer.v rtl/sound/jt89/hdl/jt89_vol.v rtl/sound/jt89/hdl/jt89.v
  sim/spk286_integration/spk286_at_tandy_machine_tb.sv
)
includes=(-Irtl/KFPC-XT/HDL/KF8253/HDL -Irtl/KFPC-XT/HDL/KF8259/HDL)
defines=(-DSPK286_AT_SIM_MODEL -DENABLE_TANDY_AUDIO=1)
iverilog -g2012 "${includes[@]}" "${defines[@]}" -s spk286_at_tandy_machine_tb \
  -o "$build_dir/tandy_machine_iv" "${sources[@]}" >"$build_dir/iverilog-build.log" 2>&1
for idle in 0 32; do
  (cd "$root/rtl/video" && vvp "$build_dir/tandy_machine_iv" "+CPU_IDLE=$idle") \
    | tee "$build_dir/iverilog-run-$idle.log"
done

if [[ "${AT_TANDY_MACHINE_VERILATOR:-0}" == 1 ]]; then
  verilator --binary --timing -j 4 -Wno-fatal "${includes[@]}" "${defines[@]}" \
    --top-module spk286_at_tandy_machine_tb --Mdir "$build_dir/verilator-obj" \
    -o tandy_machine_vlt "${sources[@]}" >"$build_dir/verilator-build.log" 2>&1
  for idle in 0 32; do
    (cd "$root/rtl/video" && "$build_dir/verilator-obj/tandy_machine_vlt" "+CPU_IDLE=$idle") \
      | tee "$build_dir/verilator-run-$idle.log"
  done
fi
