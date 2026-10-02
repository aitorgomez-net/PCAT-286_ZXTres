#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/i1-cpu-package}"
mkdir -p "$build_dir"
cd "$root"

python3 -m vendor.spk286.tools.microcode.compile_microcode --check

if grep -Eiq 'mcl86|rtl/8088' rtl/spk286_integration/spk286_integration.qip; then
  echo "SPK286 integration QIP contains an MCL86/8088 source" >&2
  exit 1
fi

sources=(
  vendor/spk286/microcode/generated/spk286_microcode_pkg.sv
  vendor/spk286/microcode/generated/spk286_microcode_rom.sv
  vendor/spk286/microcode/generated/spk286_microcode_sync_rom.sv
  vendor/spk286/rtl/spk286_protected_pkg.sv
  vendor/spk286/rtl/spk286_tss_pkg.sv
)

# Package declarations must precede the RTL glob. Keep this manifest aligned
# with the Quartus QIP so protected/TSS services do not depend on shell order.
for source in vendor/spk286/rtl/*.sv; do
  case "$source" in
    vendor/spk286/rtl/spk286_protected_pkg.sv|vendor/spk286/rtl/spk286_tss_pkg.sv)
      ;;
    *)
      sources+=("$source")
      ;;
  esac
done

sources+=(
  rtl/spk286_integration/spk286_machine_cpu.sv
  sim/spk286_integration/spk286_machine_cpu_elab_tb.sv
)

iverilog -g2012 -s spk286_machine_cpu_elab_tb \
  -o "$build_dir/i1_cpu_package_iv" "${sources[@]}"
vvp "$build_dir/i1_cpu_package_iv" | tee "$build_dir/iverilog.log"

verilator --lint-only --timing --top-module spk286_machine_cpu_elab_tb \
  -Wno-fatal "${sources[@]}" 2>&1 | tee "$build_dir/verilator.log"

echo I1_PACKAGE_TEST_PASS
