#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build=${PCAT_BUILD_DIR:-$root/build/at-ram-read-buffer-perf}
cd "$root"
mkdir -p "$build"
# Build and check the production options and the P03 off/on controls.
PCAT_BUILD_DIR="$build" PCAT_PROFILE=1 bash scripts/test_checkit_directed.sh > "$build/directed-run.txt" 2>&1
for workload in dhrystone whetstone working_set dhrystone21; do
  "$build/obj/checkit_workload" "+ROM=$build/checkit-$workload.rom" "+NAME=$workload" \
    +NATIVE=1 +P03=1 +PROFILE=1 +DATA_BUFFER=0 > "$build/$workload-data-off.log"
done
python3 scripts/report_at_ram_read_buffer.py "$build"
