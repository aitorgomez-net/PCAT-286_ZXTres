#!/usr/bin/env bash
# Build the PCAT-286 ZXTRES+ target (DeMiSTify) with Vivado and convert it
# to a .ZX3 core. At this stage the guest is zxtres_skeleton_guest: the MiST
# interface, the OSD and the SPK286 demo, without the PC/AT machine.
#
#   zxtres/scripts/build_pcat.sh
#
# Runs from Git Bash on Windows or from Linux. Needs python3 and Vivado
# (VIVADO, else vivado on PATH, else D:\AMD\2025.2). It needs nasm, gcc and
# make for the firmware and the demo ROM, either on PATH or in WSL.
# Output: build/zxtres-pcat/vivado/PCAT286.ZX3, the .bit file and reports.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
part=xc7a100tfgg484-2
top=zxtres_pcat_top
out="$root/build/zxtres-pcat/vivado"
rel="build/zxtres-pcat/vivado"

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
linux bash zxtres/scripts/build_firmware.sh > build/zxtres-pcat-firmware.log 2>&1 \
  || { tail -20 build/zxtres-pcat-firmware.log >&2; exit 1; }

rm -rf "${out:?}"
mkdir -p "$out/src"
linux nasm -f bin -l "$rel/demo.lst" -o "$rel/demo.bin" zxtres/demo/demo.asm
python3 zxtres/scripts/make_mem.py rom "$out/demo.bin" "$out/demo_rom.mem"
python3 zxtres/scripts/make_mem.py text "$out/demo_text.mem"
python3 zxtres/scripts/make_mem.py font rtl/common/font0.hex "$out/font0.mem"

vhdl=(
  zxtres/demistify/demistify_config_pkg.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_pkg.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_alu.vhd
  DeMiSTify/EightThirtyTwo/RTL/eightthirtytwo_shifter.vhd
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
  sys/at_cdc_snapshot.sv
  mist-modules/user_io.v
  mist-modules/data_io.v
  mist-modules/osd.v
  DeMiSTify/templates/demistify/common/joydecoder_neptuno.v
  zxtres/rtl/zxtres_ps2_rx.sv
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
# Freeze the inputs in the run directory.
for source in "${vhdl[@]}" "${sv[@]}" "${includes[@]}"; do
  mkdir -p "$out/src/$(dirname "$source")"
  cp "$source" "$out/src/$source"
done
printf 'src/%s\n' "${vhdl[@]}" > "$out/vhdl_sources.txt"
printf 'src/%s\n' "${sv[@]}" > "$out/sv_sources.txt"
cp zxtres/constraints/zxtres_pcat.xdc zxtres/scripts/build_pcat.tcl "$out/"
git -C "$root" rev-parse HEAD > "$out/source-revision.txt"
git -C "$root" status --short > "$out/source-status.txt"

cd "$out"
"$VIVADO" -mode batch -log vivado.log -journal vivado.jou -source build_pcat.tcl \
  -tclargs "$part" "$top" > console.log 2>&1 \
  || { grep -E '^(ERROR|CRITICAL WARNING)' vivado.log | head -30 >&2; exit 1; }

python3 "$root/zxtres/scripts/bit_to_zx3.py" zxtres_pcat.bit PCAT286.ZX3
cat result.txt
grep -E '^\| (Slice LUTs|Slice Registers|Block RAM Tile|DSPs)' utilization.rpt | head -4
echo "critical warnings: $(grep -c '^CRITICAL WARNING' vivado.log || true)"
