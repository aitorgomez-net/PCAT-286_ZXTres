#!/usr/bin/env bash
# Build the PCAT-286 ZXTRES+ target (DeMiSTify) with Vivado and convert it
# to a .ZX3 core.
#
#   zxtres/scripts/build_pcat.sh [pcat|skeleton]
#
# pcat (default) is the PC/AT machine (zxtres/rtl/pcat286_zxtres_guest.sv,
# generated from PCAT-286.sv). skeleton is the MiST-interface test guest
# around the SPK286 demo. Runs from Git Bash on Windows or from Linux. Needs
# python3 and Vivado (VIVADO, else vivado on PATH, else D:\AMD\2025.2), and
# nasm, gcc and make for the firmware and the demo ROM, on PATH or in WSL.
# Output: build/zxtres-pcat/vivado-<target>/PCAT286.ZX3, the .bit file and
# the reports.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
target=${1:-pcat}
case "$target" in pcat|skeleton) ;; *) echo "target must be pcat or skeleton" >&2; exit 2 ;; esac
part=xc7a100tfgg484-2
top=zxtres_pcat_top
out="$root/build/zxtres-pcat/vivado-$target"
rel="build/zxtres-pcat/vivado-$target"

if [[ -z "${VIVADO:-}" ]]; then
  for candidate in "$(command -v vivado 2>/dev/null || true)" \
                   /d/AMD/2025.2/Vivado/bin/vivado.bat \
                   /mnt/d/AMD/2025.2/Vivado/bin/vivado.bat; do
    [[ -n "$candidate" && -e "$candidate" ]] && { VIVADO="$candidate"; break; }
  done
fi
[[ -n "${VIVADO:-}" ]] || { echo "vivado not found; set VIVADO" >&2; exit 1; }

# Linux tools, or the ones in WSL from Git Bash. Arguments are relative to
# the repository root, which both sides see as the working directory.
linux() {
  if command -v nasm >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1; then "$@"
  elif command -v wsl.exe >/dev/null 2>&1; then MSYS_NO_PATHCONV=1 wsl.exe "$@"
  else echo "nasm/gcc not found and no WSL" >&2; return 1
  fi
}

cd "$root"
[[ -f DeMiSTify/controller/substitute_mcu.vhd && -f mist-modules/user_io.v ]] || {
  echo "submodules missing: git submodule update --init --recursive" >&2; exit 1; }
python3 zxtres/scripts/make_guest.py --check
linux bash zxtres/scripts/build_firmware.sh > build/zxtres-pcat-firmware.log 2>&1 \
  || { tail -20 build/zxtres-pcat-firmware.log >&2; exit 1; }

rm -rf "${out:?}"
mkdir -p "$out/src"

vhdl=(
  zxtres/demistify/demistify_config_pkg.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_pkg.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_shifter.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_alu.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_aligner.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_aligner_le.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_decode.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_fetchloadstore.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_hazard.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_debug.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_cpu.vhd
  DeMiSTify/controller/simple_uart.vhd
  DeMiSTify/controller/jtag_uart.vhd
  DeMiSTify/controller/io_ps2_com.vhd
  DeMiSTify/controller/interrupt_controller.vhd
  DeMiSTify/controller/timer_controller.vhd
  DeMiSTify/controller/spi_controller.vhd
  build/zxtres-pcat/firmware/controller_rom1_word.vhd
  build/zxtres-pcat/firmware/controller_rom2_word.vhd
  DeMiSTify/firmware/controller_rom.vhd
  DeMiSTify/controller/substitute_mcu.vhd
  DeMiSTify/templates/demistify/common/joystick_sega.vhd
)
sv=(
  sys/at_cdc_snapshot.sv
  mist-modules/user_io.v
  mist-modules/data_io.v
  zxtres/rtl/zxtres_osd.sv
  DeMiSTify/templates/demistify/common/joydecoder_neptuno.v
  zxtres/rtl/zxtres_ps2_rx.sv
  DeMiSTify/templates/zxtres/zx3w/sigma_delta_codec.v
  DeMiSTify/templates/zxtres/zx3w/i2s_sound.v
)
defines=()
includes=()
if [[ $target == pcat ]]; then
  # One block RAM per EGA plane, as in the Quartus build (rtl/video/ega_vram.v).
  # The machine blocks default every sound device to off (the Quartus build
  # too); a define in the guest file would reach only the files after it.
  defines=(PCAT_EGA_VRAM_TWO_PORT ENABLE_OPL2:1 ENABLE_CMS:1 ENABLE_TANDY_AUDIO:1 ENABLE_SB:1 ENABLE_MIDI:0
           SPK286_AT_BOOT_SPLASH)
  mapfile -t machine_vhdl < <(python3 zxtres/scripts/pcat_sources.py vhdl | tr -d '\r')
  mapfile -t machine_sv < <(python3 zxtres/scripts/pcat_sources.py sv | tr -d '\r')
  mapfile -t include_dirs < <(python3 zxtres/scripts/pcat_sources.py includes | tr -d '\r')
  vhdl+=("${machine_vhdl[@]}")
  sv+=(sys/at_cdc_fifo.sv "${machine_sv[@]}"
       zxtres/rtl/zxtres_dpram.sv zxtres/rtl/zxtres_ps2_key.sv zxtres/rtl/zxtres_cmos_store.sv zxtres/rtl/zxtres_ide_store.sv zxtres/rtl/zxtres_fdd_store.sv zxtres/rtl/zxtres_sd_arb.sv
       mist-modules/scandoubler/scandoubler_framing.v zxtres/rtl/zxtres_linedouble.sv
       zxtres/rtl/zxtres_sram_ctrl.sv zxtres/rtl/zxtres_scanconv.sv
       zxtres/rtl/zxtres_vidinfo.sv zxtres/rtl/pcat286_zxtres_guest.sv zxtres/rtl/zxtres_pcat_top.sv)
  # Every SystemVerilog file the sources may `include, by directory.
  for directory in "${include_dirs[@]}"; do
    for file in "$directory"/*.sv "$directory"/*.svh "$directory"/*.vh "$directory"/*.v; do
      [[ -f "$file" ]] && includes+=("$file")
    done
  done
else
  defines=(ZXTRES_SKELETON)
  linux nasm -f bin -l "$rel/demo.lst" -o "$rel/demo.bin" zxtres/demo/demo.asm
  python3 zxtres/scripts/make_mem.py rom "$out/demo.bin" "$out/demo_rom.mem"
  python3 zxtres/scripts/make_mem.py text "$out/demo_text.mem"
  python3 zxtres/scripts/make_mem.py font rtl/common/font0.hex "$out/font0.mem"
  sv+=(
    vendor/spk286/microcode/generated/spk286_microcode_pkg.sv
    vendor/spk286/microcode/generated/spk286_microcode_rom.sv
    vendor/spk286/microcode/generated/spk286_microcode_sync_rom.sv
    vendor/spk286/rtl/spk286_protected_pkg.sv
    vendor/spk286/rtl/spk286_tss_pkg.sv
  )
  for source in vendor/spk286/rtl/*.sv; do
    case "$source" in
      vendor/spk286/rtl/spk286_protected_pkg.sv|vendor/spk286/rtl/spk286_tss_pkg.sv) ;;
      *) sv+=("$source") ;;
    esac
  done
  sv+=(
    rtl/spk286_integration/spk286_machine_cpu.sv
    zxtres/rtl/zxtres_text_vga.sv
    zxtres/rtl/zxtres_demo_system.sv
    zxtres/rtl/zxtres_skeleton_guest.sv
    zxtres/rtl/zxtres_pcat_top.sv
  )
  includes=(
    rtl/spk286_timing/spk286_instruction_timing.sv
    rtl/spk286_timing/spk286_instruction_schedule.sv
    rtl/spk286_timing/spk286_target_handoff.sv
    rtl/spk286_timing/spk286_target_replay.sv
    vendor/spk286/rtl/spk286_encoding_preview.sv
    vendor/spk286/rtl/timed/spk286_profiled_events.sv
    vendor/spk286/rtl/timed/spk286_profiled_micro_executor.sv
    vendor/spk286/rtl/timed/spk286_profiled.sv
  )
fi

# Freeze the inputs in the run directory, under their repository paths.
for source in "${vhdl[@]}" "${sv[@]}" "${includes[@]}"; do
  mkdir -p "$out/src/$(dirname "$source")"
  cp "$source" "$out/src/$source"
done
# Memory images loaded with $readmemh. Keep the OSD font beside the Vivado
# script; build_pcat.tcl sets that directory as the working directory.
if [[ $target == pcat ]]; then
  cp rtl/video/splash_vga_palette.hex rtl/common/font0.hex "$out/"
  cp zxtres/splash/splash_vga_320x200.hex "$out/"     # the ZXTres splash picture
  cp zxtres/credits/msg.bin "$out/"                    # the F12 credits text
fi
python3 zxtres/scripts/make_mem.py osdfont rtl/common/font0.hex "$out/osd_font.mem"
printf 'src/%s\n' "${vhdl[@]}" > "$out/vhdl_sources.txt"
# Vivado reads all Verilog sources as one compilation unit, so a file that
# ends with `default_nettype none leaks it into the next; Quartus compiles
# them separately. Restore the default after each such file.
printf '`default_nettype wire\n' > "$out/src/zxtres_nettype_wire.sv"
for source in "${sv[@]}"; do
  echo "src/$source"
  if grep -q 'default_nettype none' "$source" && ! grep -q 'default_nettype wire' "$source"; then
    echo "src/zxtres_nettype_wire.sv"
  fi
done > "$out/sv_sources.txt"
printf '%s\n' src "${include_dirs[@]/#/src/}" > "$out/include_dirs.txt" 2>/dev/null || echo src > "$out/include_dirs.txt"
cp zxtres/constraints/zxtres_pcat.xdc zxtres/scripts/build_pcat.tcl "$out/"
git -C "$root" rev-parse HEAD > "$out/source-revision.txt"
git -C "$root" status --short > "$out/source-status.txt"

cd "$out"
"$VIVADO" -mode batch -log vivado.log -journal vivado.jou -source build_pcat.tcl \
  -tclargs "$part" "$top" "${defines[@]}" > console.log 2>&1 \
  || { grep -E '^(ERROR|CRITICAL WARNING)' vivado.log | head -30 >&2; exit 1; }

python3 "$root/zxtres/scripts/bit_to_zx3.py" zxtres_pcat.bit PCAT286.ZX3
cat result.txt
grep -E '^\| (Slice LUTs|Slice Registers|Block RAM Tile|DSPs)' utilization.rpt | head -4
echo "critical warnings: $(grep -c '^CRITICAL WARNING' vivado.log || true)"
