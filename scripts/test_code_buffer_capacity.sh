#!/usr/bin/env bash
# Simulation-only code-buffer capacity and associativity experiment.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=${PCAT_BUILD_DIR:-$root/build/code-buffer-capacity}
mkdir -p "$build_dir"
cd "$root"

# Fresh one-line production reference, with the same CPU and project flags.
PCAT_BUILD_DIR="$build_dir/reference" PCAT_PROFILE=1 PCAT_CODE_BUFFER_LINES=1 \
  bash scripts/test_checkit_directed.sh > "$build_dir/reference.log" 2>&1

mapfile -t sources < <(
  sed -n 's/.*SYSTEMVERILOG_FILE \("vendor\/[^"]*\.sv"\).*/\1/p' \
    rtl/spk286_integration/spk286_integration.qip | tr -d '"'
)
sources+=(
  rtl/spk286_integration/spk286_machine_cpu.sv
  rtl/spk286_integration/spk286_at_bus_bridge.sv
  rtl/spk286_integration/spk286_at_memory_decode.sv
  rtl/spk286_integration/spk286_at_mister_memory_port.sv
  rtl/spk286_integration/spk286_at_posted_write_buffer.sv
  rtl/spk286_integration/spk286_at_sdram_read_buffer.sv
  sim/spk286_integration/spk286_at_multiline_code_buffer_model.sv
  rtl/spk286_integration/spk286_at_sdram_data_buffer.sv
  rtl/spk286_integration/spk286_at_mister_sdram_owner.sv
  rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv
  sim/spk286_integration/spk286_sdram_pin_model.sv
  sim/spk286_integration/spk286_checkit_workload_tb.sv
)
printf '%s\n' "${sources[@]}" > "$build_dir/sources.txt"
source scripts/at_performance_flags.sh
git rev-parse HEAD > "$build_dir/baseline.commit"
verilator --version > "$build_dir/simulator.txt"
sha256sum "${sources[@]}" rtl/spk286_integration/spk286_at_sdram_read_buffer.sv \
  sim/spk286_integration/spk286_checkit_profile.svh \
  sim/spk286_integration/spk286_checkit_ideal_owner.svh config.tcl \
  > "$build_dir/source.sha256"
verilator --binary --timing -j 4 -Wno-fatal \
  "${performance_flags[@]}" -DPCAT_CODE_BUFFER_EXPERIMENT \
  --top-module spk286_checkit_workload_tb \
  --Mdir "$build_dir/obj" -o code_buffer_capacity "${sources[@]}" \
  > "$build_dir/build.log" 2>&1

for lines in 1 2 4 8 16 32 64 128; do
  for ways in 1 2; do
    (( ways <= lines )) || continue
    for extra in 0 1; do
      variant="l${lines}-w${ways}-h${extra}"
      mkdir -p "$build_dir/$variant"
      for workload in dhrystone whetstone working_set dhrystone21; do
        "$build_dir/obj/code_buffer_capacity" \
          "+ROM=$build_dir/reference/checkit-$workload.rom" "+NAME=$workload" \
          +NATIVE=1 +P03=1 +PROFILE=1 +IDEAL_OWNER=0 \
          "+CODE_LINES=$lines" "+CODE_WAYS=$ways" "+CODE_HIT_EXTRA=$extra" \
          > "$build_dir/$variant/$workload.log"
      done
      echo "CODE_BUFFER_VARIANT_PASS $variant"
    done
  done
done

# Disabled-buffer controls must reproduce the physical production bypass.
for variant in '1 1 0' '128 2 1'; do
  read -r lines ways extra <<< "$variant"
  name="disabled-l${lines}-w${ways}-h${extra}"
  mkdir -p "$build_dir/$name"
  for workload in dhrystone whetstone working_set dhrystone21; do
    "$build_dir/obj/code_buffer_capacity" \
      "+ROM=$build_dir/reference/checkit-$workload.rom" "+NAME=$workload" \
      +NATIVE=1 +P03=0 +PROFILE=1 +IDEAL_OWNER=0 \
      "+CODE_LINES=$lines" "+CODE_WAYS=$ways" "+CODE_HIT_EXTRA=$extra" \
      > "$build_dir/$name/$workload.log"
  done
done
python3 scripts/report_code_buffer_capacity.py "$build_dir"
echo CODE_BUFFER_CAPACITY_PASS
