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

if ! grep -q '"P1O7,Boot Splash Screen,Yes,No;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P1FC0,ROM,PCAT BIOS:;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P1FC2,ROM,EC00 BIOS:;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P1FC3,ROM,EGA BIOS:;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P1O\[71\],SPK286 Debug,Off,On;"' \
     "$ROOT_DIR/PCAT-286.sv" || \
   ! grep -q '"P1O\[73:72\],Debug Page,CPU,Registers,Bus,Trace;"' \
     "$ROOT_DIR/PCAT-286.sv"; then
  echo "AT_PROFILE OSD bits/file slots must match PCAT-286.sv" >&2
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
  "$ROOT_DIR/rtl/common/spk286_debug_overlay.sv"
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
for source in "${INTEGRATION_SOURCES[@]}"; do
  SOURCE_FILES+=("$ROOT_DIR/$source")
done

# Match the Quartus source closure for the real EGA raster.
for source in "$ROOT_DIR"/rtl/video/*.v "$ROOT_DIR"/rtl/video/*.sv; do
  SOURCE_FILES+=("$source")
done

iverilog -g2012 -I"$KF8253_DIR" -Wall -Wno-timescale \
    -DSPK286_P05_PARALLEL_LIMIT_CHECK \
    -DSPK286_AT_NO_DEBUG \
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
