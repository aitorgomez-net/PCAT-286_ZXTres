#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/at-profile-elab"
mkdir -p "$BUILD_DIR"

if ! grep -q '`ifdef AT_PROFILE' "$ROOT_DIR/sys/sys_top.v" || \
   ! grep -q 'emu_at emu' "$ROOT_DIR/sys/sys_top.v"; then
  echo "AT_PROFILE selector is missing" >&2
  exit 1
fi

if ! grep -q 'assign hdmi_tx_clk = hdmi_clk_out;' "$ROOT_DIR/sys/sys_top.v"; then
  echo "AT_PROFILE HDMI clock must use the HDMI PLL" >&2
  exit 1
fi

if ! grep -q '\.clk_sys              (CLK_50M)' \
     "$ROOT_DIR/PCAT-286.sv"; then
  echo "AT_PROFILE HPS clock must remain on CLK_50M" >&2
  exit 1
fi

if ! grep -q '"P1,System & BIOS;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"V,v"' \
     "$ROOT_DIR/PCAT-286.sv"; then
  echo "AT_PROFILE OSD configuration must declare a page and version marker" >&2
  exit 1
fi

if ! grep -q '"P2OT,C/MS Audio,Enabled,Disabled;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P2oAB,OPL2,Adlib 388h,SB FM 388h/228h, Disabled;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P2oN,Tandy Sound,Disabled,Enabled;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P2o01,Speaker Volume,1,2,3,4;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P2o45,Audio Boost,No,2x,4x;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P2o67,Stereo Mix,none,25%,50%,100%;"' \
     "$ROOT_DIR/PCAT-286.sv"; then
  echo "AT_PROFILE audio OSD entries must match the source profile" >&2
  exit 1
fi

if ! grep -q '"P1O7,Boot Splash Screen,Yes,No;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P1FC0,ROM,PCAT BIOS:;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P1FC2,ROM,C800 BIOS:;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P1FC3,ROM,EGA BIOS:;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P1O\[71\],SPK286 Debug,Off,On;"' \
     "$ROOT_DIR/PCAT-286.sv"; then
  echo "AT_PROFILE OSD bits/file slots must match PCAT-286.sv" >&2
  exit 1
fi

if ! grep -q 'P3oO,MPU-401,Enabled,Disabled;' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q 'P3O6,USER I/O,MIDI,COM2;' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q 'h3P4,MT32-pi;' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q 'spk286_at_serial.sv' \
     "$ROOT_DIR/rtl/spk286_integration/spk286_integration.qip" || \
   ! grep -q '`ifndef SPK286_AT_SIM_MODEL' \
     "$ROOT_DIR/rtl/spk286_integration/spk286_at_serial.sv" || \
   ! grep -q 'rtl/uart/uart.qip' \
     "$ROOT_DIR/files.qip" || \
   ! grep -q 'mt32pi u_mt32pi' \
     "$ROOT_DIR/PCAT-286.sv"; then
  echo "AT_PROFILE MIDI/MT32-pi integration is incomplete" >&2
  exit 1
fi

if ! grep -q '"S0,IMGIMAVFD,Floppy A:;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"S1,IMGIMAVFD,Floppy B:;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"OJK,Write Protect,None,A:,B:,A: & B:;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '\.floppy_write_protect   (hps_status\[20:19\])' \
     "$ROOT_DIR/PCAT-286.sv"; then
  echo "AT_PROFILE floppy image slots/write-protect bits must match PCAT-286 AT" >&2
  exit 1
fi

mapfile -t INTEGRATION_SOURCES < <(
  sed -n 's/.*SYSTEMVERILOG_FILE "\([^"]*\.sv\)".*/\1/p' \
    "$ROOT_DIR/rtl/spk286_integration/spk286_integration.qip"
)

KF8259_DIR="$ROOT_DIR/rtl/KFPC-XT/HDL/KF8259/HDL"
KF8253_DIR="$ROOT_DIR/rtl/KFPC-XT/HDL/KF8253/HDL"
SOURCE_FILES=(
  "$ROOT_DIR/PCAT-286.sv"
  "$ROOT_DIR/rtl/common/simple_fifo.v"
  "$ROOT_DIR/rtl/common/floppy.v"
  "$ROOT_DIR/rtl/common/ide.v"
  "$ROOT_DIR/sim/spk286_integration/dpram_model.sv"
  "$ROOT_DIR/rtl/hps_ext.v"
  "$KF8253_DIR/KF8253.sv"
  "$KF8253_DIR/KF8253_Counter.sv"
  "$KF8253_DIR/KF8253_Control_Logic.sv"
  "$ROOT_DIR/sim/spk286_integration/hps_io_elab_stub.sv"
  "$ROOT_DIR/sim/spk286_integration/pll_system_elab_stub.sv"
  "$ROOT_DIR/rtl/common/jtframe_ram.v"
  "$ROOT_DIR/rtl/common/tandy_pcjr_joy.sv"
  "$ROOT_DIR/rtl/common/spk286_debug_min_overlay.sv"
  "$ROOT_DIR/sys/mt32pi.sv"
  "$ROOT_DIR/rtl/KFPC-XT/HDL/ega_vram_bram_frontend.sv"
  "$ROOT_DIR/rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv"
  "$KF8259_DIR/KF8259_Common_Package.svh"
  "$KF8259_DIR/KF8259_Priority_Resolver.sv"
  "$KF8259_DIR/KF8259_Interrupt_Request.sv"
  "$KF8259_DIR/KF8259_In_Service.sv"
  "$KF8259_DIR/KF8259_Control_Logic.sv"
  "$KF8259_DIR/KF8259_Bus_Control_Logic.sv"
  "$KF8259_DIR/KF8259.sv"
)
SOUND_FILES=(
  "$ROOT_DIR/rtl/sound/saa1099.sv"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl2.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_acc.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_csr.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_div.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_lfo.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_pm.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_eg_cnt.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_eg_comb.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_eg_ctrl.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_eg_final.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_eg_pure.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_eg_step.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_eg.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_exprom.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_logsin.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_mmr.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_op.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_pg_comb.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_pg_inc.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_pg_sum.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_pg_rhy.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_pg.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_reg.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_sh_rst.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_sh.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_single_acc.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_timers.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_noise.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_slot_cnt.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl_reg_ch.v"
  "$ROOT_DIR/rtl/sound/jtopl/hdl/jtopl.v"
  "$ROOT_DIR/rtl/sound/jt89/hdl/jt89_noise.v"
  "$ROOT_DIR/rtl/sound/jt89/hdl/jt89_tone.v"
  "$ROOT_DIR/rtl/sound/jt89/hdl/jt89_mixer.v"
  "$ROOT_DIR/rtl/sound/jt89/hdl/jt89_vol.v"
  "$ROOT_DIR/rtl/sound/jt89/hdl/jt89.v"
)
SOURCE_FILES+=("${SOUND_FILES[@]}")
for source in "${INTEGRATION_SOURCES[@]}"; do
  SOURCE_FILES+=("$ROOT_DIR/$source")
done

# Match the Quartus source closure for the real EGA raster.
for source in "$ROOT_DIR"/rtl/video/*.v "$ROOT_DIR"/rtl/video/*.sv; do
  SOURCE_FILES+=("$source")
done

iverilog -g2012 -I"$KF8253_DIR" -Wall -Wno-timescale \
    -DENABLE_OPL2=1 \
    -DENABLE_CMS=1 \
    -DENABLE_TANDY_AUDIO=1 \
    -DENABLE_MIDI=1 \
    -DENABLE_EMS=1 \
    -DENABLE_UMB=1 \
    -DSPK286_P05_PARALLEL_LIMIT_CHECK \
    -DSPK286_AT_NO_DEBUG \
    -DSPK286_AT_SIM_MODEL \
  -o "$BUILD_DIR/config.vvp" \
  -s spk286_at_config_tb \
  -I"$ROOT_DIR" \
  -I"$KF8259_DIR" \
  "${SOURCE_FILES[@]}" \
  "$ROOT_DIR/sim/spk286_integration/spk286_at_config_tb.sv" \
  >"$BUILD_DIR/compile.log" 2>&1 || {
    cat "$BUILD_DIR/compile.log"
    exit 1
  }

(
  cd "$ROOT_DIR/rtl/video"
  vvp "$BUILD_DIR/config.vvp"
) >"$BUILD_DIR/config.log" 2>&1 || {
  cat "$BUILD_DIR/config.log"
  exit 1
}
grep 'AT_CONFIG_.*_PASS' "$BUILD_DIR/config.log"
echo "AT_PROFILE_SELECTOR_PASS"
echo "AT_PROFILE_ELAB_PASS"
