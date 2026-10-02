#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=${PCAT_BUILD_DIR:-$root/build/perf01-bridge-cancel/candidate}
mkdir -p "$build_dir"
cd "$root"
source scripts/at_performance_flags.sh
bridge_rtl=${PCAT_BRIDGE_RTL:-$root/rtl/spk286_integration/spk286_at_bus_bridge.sv}
sources=("$bridge_rtl"
  rtl/spk286_integration/spk286_at_mister_memory_port.sv
  rtl/spk286_integration/spk286_at_sdram_read_buffer.sv
  rtl/spk286_integration/spk286_at_sdram_data_buffer.sv
  sim/spk286_integration/spk286_at_bridge_cancel_pipeline_tb.sv)
sha256sum "${sources[@]}" scripts/test_at_bridge_cancel_pipeline.sh > "$build_dir/compiled-sources.sha256"
# The cascaded buffer handshake has a known Icarus delta scheduling loop;
# use Verilator, as for the existing complete RAM-buffer pipeline test.
verilator --binary --timing --assert -j 2 -Wno-fatal "${performance_flags[@]}" \
  --top-module spk286_at_bridge_cancel_pipeline_tb --Mdir "$build_dir/obj" \
  -o cancel_pipeline "${sources[@]}" > "$build_dir/verilator-build.log" 2>&1
timeout 30s "$build_dir/obj/cancel_pipeline" | tee "$build_dir/verilator-run.log"
grep -q '^AT_BRIDGE_CANCEL_PIPELINE_PASS' "$build_dir/verilator-run.log"
sha256sum --check "$build_dir/compiled-sources.sha256" > "$build_dir/sources-verified.log"
echo AT_BRIDGE_CANCEL_PIPELINE_TEST_PASS

# Production's 4 KiB code buffer has synchronous tags. Repeat the same
# cancellation/data/uniqueness scoreboard at that geometry.
verilator --binary --timing --assert -j 2 -Wno-fatal "${performance_flags[@]}" \
  -GCODE_BUFFER_LINES=512 --top-module spk286_at_bridge_cancel_pipeline_tb \
  --Mdir "$build_dir/production-obj" -o cancel_pipeline "${sources[@]}" \
  > "$build_dir/production-build.log" 2>&1
timeout 30s "$build_dir/production-obj/cancel_pipeline" | tee "$build_dir/production-run.log"
grep -q '^AT_BRIDGE_CANCEL_PIPELINE_PASS' "$build_dir/production-run.log"
sha256sum --check "$build_dir/compiled-sources.sha256" > "$build_dir/sources-verified.log"
echo AT_BRIDGE_CANCEL_PRODUCTION_TEST_PASS
