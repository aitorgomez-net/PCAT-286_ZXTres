#!/usr/bin/env bash
# Board-level simulation of the PCAT-286 ZXTRES+ target booting a real BIOS
# (zxtres/sim/zxtres_pcat_bios_tb.sv). Run from WSL or Linux with ghdl,
# verilator, gcc, make and python3:
#
#   zxtres/sim/run_bios_sim.sh BIOS_ROM EGA_ROM [plusargs...]
#
# The ROMs go into the simulated SD card as PCAT286/PCAT286.ROM and
# PCAT286/EGA.ROM; they are not copied anywhere else. Plusargs pass to the
# testbench, e.g. +POST_MS=2000 +SETUP_KEYS=0076. Frames go to
# build/zxtres-pcat/bios-sim. The card also holds an empty PCAT286/PCAT286.CMS;
# the CMOS store's quiet period is 10 ms instead of 1 s. With
# ZXTRES_SIM_VHD=file that file is DISKS/BOOT.VHD, and PCAT286/PCAT286.CFG
# mounts it as the first hard disk (sim/make_boot_vhd.py writes a bootable
# one). ZXTRES_SIM_CMS=file is the CMOS file instead of the empty one (sim/
# make_cmos_file.py builds it from a +DUMP_CMOS run of the BIOS setup).
# ZXTRES_SIM_CFG=file is PCAT286/PCAT286.CFG instead (sim/make_cfg_file.py).
# ZXTRES_SIM_EXTRA="file ..." puts more files on the card's root, or in a
# folder as FOLDER/NAME.EXT=file (disk images for the OSD).
# ZXTRES_SIM_HOME= (empty) puts the PCAT286 folder's files in the root.
# ZXTRES_SIM_OUT=dir replaces the output directory, so two runs can go side by side.
# ZXTRES_SIM_KEEP_FIRMWARE=1 uses the firmware already built; a Vivado build
# rebuilds it in the same directory, so the two must not run together.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ $# -ge 2 ]] || { sed -n '2,23p' "$0"; exit 2; }
bios=$(realpath "$1"); ega=$(realpath "$2"); shift 2
out="${ZXTRES_SIM_OUT:-$root/build/zxtres-pcat/bios-sim}"
cd "$root"

if [[ -z "${ZXTRES_SIM_KEEP_FIRMWARE:-}" ]]; then
  bash zxtres/scripts/build_firmware.sh > build/zxtres-pcat-firmware.log 2>&1 \
    || { tail -20 build/zxtres-pcat-firmware.log >&2; exit 1; }
fi
rm -rf "${out:?}"
mkdir -p "$out/files" "$out/ghdl" "$out/patched"
home=${ZXTRES_SIM_HOME-PCAT286}
home=${home:+$home/}
cp "$bios" "$out/files/PCAT286.ROM"
cp "$ega" "$out/files/EGA.ROM"
if [[ -n "${ZXTRES_SIM_CMS:-}" ]]; then
  cp "$ZXTRES_SIM_CMS" "$out/files/PCAT286.CMS"
else
  head -c 512 /dev/zero > "$out/files/PCAT286.CMS"   # a new, empty CMOS file
fi
card=("${home}PCAT286.ROM=$out/files/PCAT286.ROM" "${home}EGA.ROM=$out/files/EGA.ROM"
      "${home}PCAT286.CMS=$out/files/PCAT286.CMS")
if [[ -n "${ZXTRES_SIM_CFG:-}" ]]; then
  cp "$ZXTRES_SIM_CFG" "$out/files/PCAT286.CFG"      # saved OSD settings
elif [[ -n "${ZXTRES_SIM_VHD:-}" ]]; then
  python3 zxtres/sim/make_cfg_file.py "$out/files/PCAT286.CFG" --disk0 DISKS/BOOT.VHD
fi
[[ -e "$out/files/PCAT286.CFG" ]] && card+=("${home}PCAT286.CFG=$out/files/PCAT286.CFG")
if [[ -n "${ZXTRES_SIM_VHD:-}" ]]; then
  cp "$ZXTRES_SIM_VHD" "$out/files/BOOT.VHD"
  card+=("DISKS/BOOT.VHD=$out/files/BOOT.VHD")
fi
for file in ${ZXTRES_SIM_EXTRA:-}; do             # more files: FILE or FOLDER/NAME.EXT=FILE
  card+=("$file")
done
python3 zxtres/sim/make_fat16_image.py "$out/sd.img" "${card[@]}"
rm -f "$out/sd.img"                      # keep only the sparse form
cp rtl/video/splash_vga_palette.hex rtl/common/font0.hex "$out/"   # $readmemh by name
cp zxtres/splash/splash_vga_320x200.hex zxtres/credits/msg.bin "$out/"
python3 zxtres/scripts/make_mem.py osdfont rtl/common/font0.hex "$out/osd_font.mem"

ghdl_flags=(--std=08 -frelaxed -fsynopsys --workdir="$out/ghdl")
mapfile -t controller < <(sed -n '/^vhdl=(/,/^)/p' zxtres/sim/run_board_sim.sh | sed '1d;$d' | sed 's/^ *//')
mapfile -t uart < <(python3 zxtres/scripts/pcat_sources.py vhdl)
for source in "${controller[@]}" "${uart[@]}"; do
  ghdl -a "${ghdl_flags[@]}" "$source" 2>&1 | grep -v ":warning:" | grep -v "^\s" || true
done
for unit in substitute_mcu joystick_sega uart_16750; do
  ghdl synth "${ghdl_flags[@]}" --out=verilog "$unit" > "$out/ghdl/$unit.vg" 2> "$out/ghdl/$unit.log"
  python3 zxtres/sim/fix_ghdl_verilog.py "$out/ghdl/$unit.vg"
done
for source in mist-modules/user_io.v mist-modules/data_io.v; do
  sed "s/1'b[zZ]/1'b1/g" "$source" > "$out/patched/$(basename "$source")"
done

mapfile -t sv < <(python3 zxtres/scripts/pcat_sources.py sv)
mapfile -t includes < <(python3 zxtres/scripts/pcat_sources.py includes)
verilator --binary --timing -O2 +1364-2005ext+vg --x-initial fast -Wno-fatal -Wno-lint -Wno-style \
  -j "$(nproc)" -I"$root" "${includes[@]/#/-I}" --top-module zxtres_pcat_bios_tb \
  +define+ZXTRES_CMOS_QUIET_CYCLES=500_000 +define+SPK286_AT_BOOT_SPLASH \
  +define+ENABLE_OPL2=1 +define+ENABLE_CMS=1 +define+ENABLE_TANDY_AUDIO=1 +define+ENABLE_SB=1 +define+ENABLE_MIDI=0 \
  --Mdir "$out/obj" -o bios_sim \
  zxtres/sim/xilinx_clock_models.sv sys/at_cdc_snapshot.sv sys/at_cdc_fifo.sv \
  zxtres/rtl/zxtres_dpram.sv "$out"/ghdl/*.vg "${sv[@]}" \
  \
  mist-modules/scandoubler/scandoubler_framing.v \
  \
  zxtres/rtl/zxtres_linedouble.sv \
  zxtres/rtl/zxtres_sram_ctrl.sv zxtres/rtl/zxtres_scanconv.sv zxtres/sim/zxtres_sram_model.sv \
  "$out/patched/user_io.v" "$out/patched/data_io.v" zxtres/rtl/zxtres_osd.sv \
  DeMiSTify/templates/demistify/common/joydecoder_neptuno.v \
  DeMiSTify/templates/zxtres/zx3w/sigma_delta_codec.v DeMiSTify/templates/zxtres/zx3w/i2s_sound.v   zxtres/rtl/zxtres_ps2_rx.sv zxtres/rtl/zxtres_ps2_key.sv zxtres/rtl/zxtres_cmos_store.sv zxtres/rtl/zxtres_ide_store.sv zxtres/rtl/zxtres_fdd_store.sv zxtres/rtl/zxtres_sd_arb.sv \
  zxtres/rtl/zxtres_vidinfo.sv zxtres/rtl/pcat286_zxtres_guest.sv \
  zxtres/rtl/zxtres_pcat_top.sv sim/spk286_integration/spk286_sdram_pin_model.sv \
  zxtres/sim/sd_card_model.sv zxtres/sim/zxtres_pcat_bios_tb.sv \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }

(cd "$out" && ./obj/bios_sim "$@") | tee "$out/sim.log" | grep -v heartbeat
for frame in "$out"/*.ppm; do
  [[ -e "$frame" ]] && python3 zxtres/scripts/ppm_to_png.py "$frame" "${frame%.ppm}.png"
done
ls "$out"/*.png 2>/dev/null || true
