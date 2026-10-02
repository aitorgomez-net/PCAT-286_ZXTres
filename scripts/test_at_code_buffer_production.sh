#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build=${PCAT_CODE_BUFFER_BUILD_DIR:-$root/build/code-buffer-production}
rtl="$root/rtl/spk286_integration/spk286_at_sdram_read_buffer.sv"
bench="$root/sim/spk286_integration/spk286_at_multiline_code_buffer_tb.sv"
top=spk286_at_multiline_code_buffer_tb
mkdir -p "$build"
sha256sum "$rtl" "$bench" "${BASH_SOURCE[0]}" > "$build/sources.sha256"
# One-line compatibility, the previous capacity and 4 KiB production capacity.
for lines in 1 64 512; do
  for enabled in 1 0; do
    name="l$lines-e$enabled"
    iverilog -g2012 -Wall -Wno-timescale -DPCAT_PRODUCTION_CODE_BUFFER \
      -s "$top" -P "$top.ENABLE=$enabled" -P "$top.LINE_COUNT=$lines" \
      -o "$build/iv-$name" "$rtl" "$bench" > "$build/compile-iv-$name.log" 2>&1
    vvp "$build/iv-$name" | tee "$build/iv-$name.log"
    verilator --binary --timing -j 4 -DPCAT_PRODUCTION_CODE_BUFFER \
      --top-module "$top" -G"ENABLE=1'b$enabled" -GLINE_COUNT="$lines" \
      --Mdir "$build/verilator-$name" "$rtl" "$bench" > "$build/compile-vlt-$name.log" 2>&1
    "$build/verilator-$name/V$top" | tee "$build/vlt-$name.log"
  done
done
sha256sum --check "$build/sources.sha256"
echo AT_CODE_BUFFER_PRODUCTION_PASS
