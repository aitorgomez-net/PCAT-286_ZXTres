#!/usr/bin/env bash
# Exercise the production posted-write queue, draining, cancellation and bypass.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build="${PCAT_BUILD_DIR:-$root/build/at-posted-write-buffer}"
mkdir -p "$build"
cd "$root"
top=spk286_at_posted_write_buffer_tb
sources=(rtl/spk286_integration/spk286_at_posted_write_buffer.sv
         sim/spk286_integration/spk286_at_posted_write_buffer_tb.sv)
iverilog -g2012 -s "$top" -o "$build/test.vvp" "${sources[@]}" > "$build/iverilog-build.log" 2>&1
vvp "$build/test.vvp" | tee "$build/iverilog-run.log"
verilator --binary --timing --assert -Wno-fatal -j 2 --top-module "$top" \
  --Mdir "$build/obj" -o posted_test "${sources[@]}" > "$build/verilator-build.log" 2>&1
"$build/obj/posted_test" | tee "$build/verilator-run.log"
echo AT_POSTED_WRITE_BUFFER_TEST_PASS
