#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build="${PCAT_BUILD_DIR:-$root/build/at-loadall-cpu}"
mkdir -p "$build"
cd "$root/vendor/spk286"
export SPK286_BUILD_DIR="$build/units"
python3 -m tools.microcode.compile_microcode --check
python3 -m unittest tests.test_microcode_loadall tests.test_microcode_salc \
  > "$build/python.log" 2>&1
bash scripts/lint.sh > "$build/lint.log" 2>&1
for unit in spk286_decoder spk286_loadall_service spk286_loadall_integration \
            spk286_loadall_protected spk286_registers spk286_segments \
            spk286_protected_foundation spk286_scalar_direct; do
  bash scripts/test_units.sh both "$unit" > "$build/$unit.log" 2>&1
  echo "AT_LOADALL_CPU_PASS $unit (Icarus and Verilator)"
done
yosys -Q -p 'read_verilog -sv rtl/spk286_loadall_service.sv; hierarchy -check -top spk286_loadall_service; synth -top spk286_loadall_service; check -assert; stat' \
  > "$build/synth.log" 2>&1
echo AT_LOADALL_CPU_TEST_PASS
