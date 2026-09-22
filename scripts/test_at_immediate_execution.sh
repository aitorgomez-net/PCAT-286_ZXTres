#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0

root=$(cd "$(dirname "$0")/.." && pwd)
build="${PCAT_BUILD_DIR:-$root/build/at-immediate-execution}"
mkdir -p "$build"
cd "$root/vendor/spk286"
export SPK286_BUILD_DIR="$build/units"
export SPK286_BUILD_JOBS="${SPK286_BUILD_JOBS:-4}"
python3 -m tools.microcode.compile_microcode --check
python3 -m unittest discover -s tests -p 'test_microcode*.py' > "$build/compiler.log" 2>&1
python3 -m tools.microcode.audit_microcode --output "$build/microcode-audit"
bash scripts/lint.sh > "$build/lint.log" 2>&1
for unit in spk286_immediate_execution spk286_immediate_throughput \
            spk286_microcode_execution spk286_alu_lifecycle spk286_register_execution \
            spk286_loadall_protected; do
    bash scripts/test_units.sh both "$unit" > "$build/$unit.log" 2>&1
    echo "AT_IMMEDIATE_EXECUTION_PASS $unit (Icarus and Verilator)"
done
echo AT_IMMEDIATE_EXECUTION_TEST_PASS
