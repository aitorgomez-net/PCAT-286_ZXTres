#!/usr/bin/env bash
# Board-level simulation of the PCAT-286 ZXTRES+ target booting a real BIOS
# (zxtres/sim/zxtres_pcat_bios_tb.sv). Run from WSL or Linux with ghdl,
# verilator, gcc, make and python3:
#
#   zxtres/sim/run_bios_sim.sh BIOS_ROM EGA_ROM [plusargs...]
#
# The ROMs go into the simulated SD card as PCAT286.ROM and EGA.ROM; they
# are not copied anywhere else. Plusargs pass to the testbench, e.g.
# +POST_MS=2000 +SETUP_KEYS=0076. Frames go to build/zxtres-pcat/bios-sim.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ $# -ge 2 ]] || { sed -n '2,12p' "$0"; exit 2; }
bios=$(realpath "$1"); ega=$(realpath "$2"); shift 2
out="$root/build/zxtres-pcat/bios-sim"
cd "$root"

bash zxtres/scripts/build_firmware.sh > build/zxtres-pcat-firmware.log 2>&1 \
  || { tail -20 build/zxtres-pcat-firmware.log >&2; exit 1; }
rm -rf "${out:?}"
mkdir -p "$out/files" "$out/ghdl" "$out/patched"
cp "$bios" "$out/files/PCAT286.ROM"
cp "$ega" "$out/files/EGA.ROM"
python3 zxtres/sim/make_fat16_image.py "$out/sd.img" "$out/files/PCAT286.ROM" "$out/files/EGA.ROM"
rm -f "$out/sd.img"                      # keep only the sparse form
cp rtl/video/splash_ega_320x200.hex rtl/common/font0.hex "$out/"   # $readmemh by name

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
  --Mdir "$out/obj" -o bios_sim \
  zxtres/sim/xilinx_clock_models.sv sys/at_cdc_snapshot.sv sys/at_cdc_fifo.sv \
  zxtres/rtl/zxtres_dpram.sv "$out"/ghdl/*.vg "${sv[@]}" \
  "$out/patched/user_io.v" "$out/patched/data_io.v" mist-modules/osd.v \
  DeMiSTify/templates/demistify/common/joydecoder_neptuno.v \
  zxtres/rtl/zxtres_ps2_rx.sv zxtres/rtl/zxtres_ps2_key.sv zxtres/rtl/pcat286_zxtres_guest.sv \
  zxtres/rtl/zxtres_pcat_top.sv sim/spk286_integration/spk286_sdram_pin_model.sv \
  zxtres/sim/sd_card_model.sv zxtres/sim/zxtres_pcat_bios_tb.sv \
  > "$out/verilator-build.log" 2>&1 \
  || { grep -E '%Error' "$out/verilator-build.log" | head -20 >&2; exit 1; }

(cd "$out" && ./obj/bios_sim "$@") | tee "$out/sim.log" | grep -v heartbeat
for frame in "$out"/*.ppm; do
  [[ -e "$frame" ]] && python3 zxtres/scripts/ppm_to_png.py "$frame" "${frame%.ppm}.png"
done
ls "$out"/*.png 2>/dev/null || true
