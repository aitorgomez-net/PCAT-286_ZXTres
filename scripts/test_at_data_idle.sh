#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=${PCAT_BUILD_DIR:-$root/build/at-data-idle}
if [[ -e "$build_dir" ]]; then
    echo "AT data IDLE validation requires a fresh PCAT_BUILD_DIR: $build_dir" >&2
    exit 1
fi
mkdir -p "$build_dir"
cd "$root"

# A frozen reference can use the same public behavior checks and assertions.
buffer_rtl=${PCAT_DATA_BUFFER_RTL:-$root/rtl/spk286_integration/spk286_at_sdram_data_buffer.sv}
buffer_rtl=$(realpath "$buffer_rtl")
bench=$root/sim/spk286_integration/spk286_at_data_idle_tb.sv
sources=("$buffer_rtl" "$bench")
sha256sum "${sources[@]}" "$root/scripts/test_at_data_idle.sh" \
    > "$build_dir/compiled-sources.sha256"

# The synchronous tag/data arrays and asynchronous control reset have the
# same intentional reset split as the existing data-buffer directed tests.
verilator --lint-only --timing --assert -Wall -Wno-SYNCASYNCNET \
    --top-module spk286_at_sdram_data_buffer "$buffer_rtl" \
    > "$build_dir/lint.log" 2>&1
verilator --binary --timing --assert -j 2 -Wno-fatal \
    --top-module spk286_at_data_idle_tb --Mdir "$build_dir/obj" -o idle_vlt \
    "${sources[@]}" > "$build_dir/verilator-build.log" 2>&1
timeout 30s "$build_dir/obj/idle_vlt" | tee "$build_dir/verilator-run.log"
grep -q '^AT_DATA_IDLE_PASS ' "$build_dir/verilator-run.log"
sha256sum --check "$build_dir/compiled-sources.sha256" \
    > "$build_dir/sources-verified.log"
echo AT_DATA_IDLE_TEST_PASS
