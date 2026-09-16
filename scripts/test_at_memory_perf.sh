#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="$root/build/at-memory-perf"
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

# Require comparable work and a genuine cycle reduction, not just two passes.
awk '
  /^AT_MEMORY_PERF_PASS / {
    for (i=2; i<=NF; i++) {
      split($i, pair, "=")
      value[pair[1]] = pair[2] + 0
    }
    mode = value["native"]
    seen[mode]++
    cycles[mode] = value["cycles"]
    retired[mode] = value["retired"]
    reads[mode] = value["reads"]
    writes[mode] = value["writes"]
  }
  END {
    if (seen[0] != 1 || seen[1] != 1 || retired[0] != retired[1] ||
        retired[0] <= 0 || reads[0] != reads[1] || writes[0] != writes[1] ||
        cycles[1] <= 0 || cycles[1] >= cycles[0]) {
      print "AT_MEMORY_PERF_COMPARISON_FAIL"
      exit 1
    }
    printf "AT_MEMORY_PERF_COMPARISON_PASS speedup=%.3fx fewer_cycles=%.2f%% retired=%d\n",
      cycles[0]/cycles[1], 100*(1-cycles[1]/cycles[0]), retired[1]
  }
' "$build_dir/native-0.log" "$build_dir/native-1.log"

# P03 is compared against the native-width baseline. It may legitimately
# alter the number of CPU-side fetch requests because prefetched bytes are
# delivered with different timing; architectural work and writes must remain
# identical, while the completed workload must be faster.
"$build_dir/obj/memory_perf" "+ROM=$build_dir/workload.rom" "+NATIVE=1" "+P03=1" \
  | tee "$build_dir/p03-native-1.log"
awk '
  /^AT_MEMORY_PERF_PASS / {
    for (i=2; i<=NF; i++) {
      split($i, pair, "=")
      value[pair[1]] = pair[2] + 0
    }
    mode = value["p03"]
    seen[mode]++
    cycles[mode] = value["cycles"]
    retired[mode] = value["retired"]
    writes[mode] = value["writes"]
    sdram_writes[mode] = value["sdram_writes"]
  }
  END {
    if (seen[0] != 1 || seen[1] != 1 || retired[0] != retired[1] ||
        writes[0] != writes[1] || sdram_writes[0] != sdram_writes[1] ||
        retired[1] <= 0 || cycles[1] >= cycles[0]) {
      print "AT_MEMORY_PERF_P03_COMPARISON_FAIL"
      exit 1
    }
    printf "AT_MEMORY_PERF_P03_COMPARISON_PASS speedup=%.3fx fewer_cycles=%.2f%% retired=%d\n",
      cycles[0]/cycles[1], 100*(1-cycles[1]/cycles[0]), retired[1]
  }
' "$build_dir/native-1.log" "$build_dir/p03-native-1.log"
