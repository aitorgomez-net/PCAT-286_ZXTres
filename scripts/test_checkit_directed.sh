#!/usr/bin/env bash
set -euo pipefail

root="${PCAT_SOURCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
build_dir="${PCAT_BUILD_DIR:-$root/build/checkit-directed}"
mkdir -p "$build_dir"
cd "$root"

nasm -f bin tests/firmware/checkit_dhrystone.asm -o "$build_dir/checkit-dhrystone.rom"
nasm -f bin tests/firmware/checkit_whetstone.asm -o "$build_dir/checkit-whetstone.rom"
nasm -f bin tests/firmware/checkit_working_set.asm -o "$build_dir/checkit-working_set.rom"
nasm -f bin tests/firmware/checkit_dhrystone21.asm -o "$build_dir/checkit-dhrystone21.rom"

mapfile -t sources < <(
  sed -n 's/.*SYSTEMVERILOG_FILE \("vendor\/[^"]*\.sv"\).*/\1/p' \
    rtl/spk286_integration/spk286_integration.qip | tr -d '"'
)
sources+=(
  rtl/spk286_integration/spk286_machine_cpu.sv
  rtl/spk286_integration/spk286_at_bus_bridge.sv
  rtl/spk286_integration/spk286_at_memory_decode.sv
  rtl/spk286_integration/spk286_at_mister_memory_port.sv
  rtl/spk286_integration/spk286_at_sdram_read_buffer.sv
  rtl/spk286_integration/spk286_at_sdram_data_buffer.sv
  rtl/spk286_integration/spk286_at_posted_write_buffer.sv
  rtl/spk286_integration/spk286_at_mister_sdram_owner.sv
  rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv
  sim/spk286_integration/spk286_sdram_pin_model.sv
  sim/spk286_integration/spk286_checkit_workload_tb.sv
)

# Read implementation-performance switches from the same project configuration
# that Quartus consumes. Previously P01/P02 were hard-coded here even when the
# shipped bitstream omitted them. Optional overrides are explicit A/B controls.
source "$root/scripts/at_performance_flags.sh"
buffer_parameters=()
if [[ -n ${PCAT_CODE_BUFFER_LINES:-} ]]; then
  buffer_parameters=(-GCODE_BUFFER_LINES="$PCAT_CODE_BUFFER_LINES")
fi
sha256sum "${sources[@]}" config.tcl \
  sim/spk286_integration/spk286_checkit_profile.svh \
  sim/spk286_integration/spk286_checkit_ideal_owner.svh \
  scripts/test_checkit_directed.sh scripts/at_performance_flags.sh \
  tests/firmware/checkit_*.asm > "$build_dir/compiled-sources.sha256"
verilator --binary --timing --assert -j 4 -Wno-fatal \
  "${performance_flags[@]}" "${buffer_parameters[@]}" \
  --top-module spk286_checkit_workload_tb \
  --Mdir "$build_dir/obj" -o checkit_workload "${sources[@]}" \
  >"$build_dir/build.log" 2>&1

for workload in dhrystone whetstone working_set dhrystone21; do
  for p03 in 0 1; do
    "$build_dir/obj/checkit_workload" \
      "+ROM=$build_dir/checkit-$workload.rom" \
      "+NAME=$workload" "+NATIVE=1" "+P03=$p03" \
      "+PROFILE=${PCAT_PROFILE:-0}" \
      | tee "$build_dir/$workload-p03-$p03.log"
  done
done
sha256sum --check "$build_dir/compiled-sources.sha256" > "$build_dir/sources-verified.log"

awk '
  /^CHECKIT_DIRECTED_PASS / {
    delete value
    workload = ""
    for (i = 2; i <= NF; i++) {
      split($i, pair, "=")
      if (pair[1] == "workload")
        workload = pair[2]
      else
        value[pair[1]] = pair[2] + 0
    }
    key = workload ":" value["p03"]
    seen[key]++
    cycles[key] = value["cycles"]
    retired[key] = value["retired"]
    writes[key] = value["writes"]
    hits[key] = value["hits"]
    misses[key] = value["misses"]
    fills[key] = value["fills"]
    physical[key] = value["physical_reads"]
  }
  END {
    workload_count = split("dhrystone whetstone working_set dhrystone21", workload_names, " ")
    for (n = 1; n <= workload_count; n++) {
      w = workload_names[n]
      b = w ":0"; p = w ":1"
      if (seen[b] != 1 || seen[p] != 1 || retired[b] != retired[p] ||
          writes[b] != writes[p] || cycles[b] <= 0 || cycles[p] <= 0) {
        print "CHECKIT_DIRECTED_COMPARISON_FAIL workload=" w
        exit 1
      }
      printf "CHECKIT_DIRECTED_COMPARISON_PASS workload=%s speedup=%.3fx fewer_cycles=%.2f%% retired=%d hits=%d misses=%d fills=%d physical_reads=%d\n",
        w, cycles[b]/cycles[p], 100*(1-cycles[p]/cycles[b]), retired[p],
        hits[p], misses[p], fills[p], physical[p]
    }
  }
' "$build_dir"/*.log
