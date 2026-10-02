#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build=${PCAT_BUILD_DIR:-$root/build/at-ram-read-buffer}
mkdir -p "$build"
cd "$root"
rtl=rtl/spk286_integration/spk286_at_sdram_data_buffer.sv
bench=sim/spk286_integration/spk286_at_sdram_data_buffer_tb.sv
sources=("$rtl" "$bench" rtl/spk286_integration/spk286_at_mister_memory_port.sv rtl/spk286_integration/spk286_at_sdram_read_buffer.sv)
sha256sum "${sources[@]}" scripts/test_at_ram_read_buffer.sh > "$build/sources.sha256"
iverilog -g2012 -s spk286_at_sdram_data_buffer_tb -o "$build/ram_iv" "${sources[@]}" > "$build/iv-build.log" 2>&1
timeout 30s vvp "$build/ram_iv" | tee "$build/iv.log"
# Like P03, the RAM data array has synchronous enables while the small control
# reset is asynchronous. This intentional reset split is the sole RTL waiver.
verilator --lint-only --timing --assert -Wall -Wno-SYNCASYNCNET \
  --top-module spk286_at_sdram_data_buffer "$rtl" > "$build/lint.log" 2>&1
verilator --binary --timing --assert -j 4 -Wno-fatal \
  --top-module spk286_at_sdram_data_buffer_tb --Mdir "$build/obj" -o ram_vlt \
  "${sources[@]}" > "$build/vlt-build.log" 2>&1
"$build/obj/ram_vlt" | tee "$build/vlt.log"
# The complete memory-port/P03 chain uses the same Verilator simulator as the
# physical CPU workload. Icarus passes the isolated unit but stalls in a delta
# scheduling loop when these combinational handshake stages are cascaded.
verilator --binary --timing --assert -j 4 -Wno-fatal -GFULL_PIPELINE=1 \
  --top-module spk286_at_sdram_data_buffer_tb --Mdir "$build/pipeline-obj" -o pipeline_vlt \
  "${sources[@]}" > "$build/pipeline-vlt-build.log" 2>&1
timeout 30s "$build/pipeline-obj/pipeline_vlt" | tee "$build/pipeline-vlt.log"
# Production's enlarged instruction buffer uses synchronous tags. Keep the
# data buffer unchanged while exercising the same CPU/DMA/loader scoreboard.
verilator --binary --timing --assert -j 4 -Wno-fatal -GFULL_PIPELINE=1 -GCODE_BUFFER_LINES=512 \
  --top-module spk286_at_sdram_data_buffer_tb --Mdir "$build/code4k-pipeline-obj" -o code4k_pipeline_vlt \
  "${sources[@]}" > "$build/code4k-pipeline-vlt-build.log" 2>&1
timeout 30s "$build/code4k-pipeline-obj/code4k_pipeline_vlt" | tee "$build/code4k-pipeline-vlt.log"
sha256sum --check "$build/sources.sha256" > "$build/sources-verified.log"
echo RAM_READ_BUFFER_TEST_PASS
