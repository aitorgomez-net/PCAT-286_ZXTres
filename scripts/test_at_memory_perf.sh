#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-memory-perf}"
mkdir -p "$build_dir"
cd "$root"
nasm -f bin tests/firmware/at_memory_perf.asm -o "$build_dir/workload.rom"
# Match the actual Quartus CPU sources and package order, including PM5.
mapfile -t sources < <(
  sed -n 's/.*SYSTEMVERILOG_FILE "\(vendor\/spk286\/[^\"]*\.sv\)".*/\1/p' \
    rtl/spk286_integration/spk286_integration.qip
)
sources+=(
  rtl/spk286_integration/spk286_machine_cpu.sv
  rtl/spk286_integration/spk286_at_bus_bridge.sv
  rtl/spk286_integration/spk286_at_memory_decode.sv
  rtl/spk286_integration/spk286_at_mister_memory_port.sv
  rtl/spk286_integration/spk286_at_sdram_read_buffer.sv
  rtl/spk286_integration/spk286_at_mister_sdram_owner.sv
  rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv
  sim/spk286_integration/spk286_sdram_pin_model.sv
  sim/spk286_integration/spk286_at_memory_perf_tb.sv
)
verilator --binary --timing -j 4 -Wno-fatal \
  --top-module spk286_at_memory_perf_tb --Mdir "$build_dir/obj" \
  -o memory_perf "${sources[@]}" >"$build_dir/build.log" 2>&1
for native in 0 1; do
  "$build_dir/obj/memory_perf" "+ROM=$build_dir/workload.rom" "+NATIVE=$native" \
    | tee "$build_dir/native-$native.log"
done

# Speculative code reads can change with a faster memory path. Require exact
# demanded data reads, retirement, writes, CPU state and full backing-memory
# signature, plus a genuine cycle reduction.
python3 scripts/compare_at_memory_perf.py "$build_dir/native-0.log" "$build_dir/native-1.log"

# P03 is compared against the native-width baseline. It may legitimately
# alter the number of CPU-side fetch requests because prefetched bytes are
# delivered with different timing; architectural work and writes must remain
# identical, while the completed workload must be faster.
"$build_dir/obj/memory_perf" "+ROM=$build_dir/workload.rom" "+NATIVE=1" "+P03=1" \
  | tee "$build_dir/p03-native-1.log"
python3 scripts/compare_at_memory_perf.py "$build_dir/native-1.log" "$build_dir/p03-native-1.log" --physical-writes
