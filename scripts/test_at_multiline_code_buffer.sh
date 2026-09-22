#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_MULTILINE_BUILD_DIR:-$ROOT_DIR/build/at-multiline-code-buffer}"
MODEL="$ROOT_DIR/sim/spk286_integration/spk286_at_multiline_code_buffer_model.sv"
BENCH="$ROOT_DIR/sim/spk286_integration/spk286_at_multiline_code_buffer_tb.sv"
TOP=spk286_at_multiline_code_buffer_tb
mkdir -p "$BUILD_DIR"
command -v iverilog >/dev/null
command -v verilator >/dev/null
sha256sum "$MODEL" "$BENCH" "${BASH_SOURCE[0]}" >"$BUILD_DIR/sources.sha256"
for enabled in 1 0; do
  iverilog -g2012 -Wall -Wno-timescale -s "$TOP" -P "$TOP.ENABLE=$enabled" \
    -o "$BUILD_DIR/iv-$enabled" "$MODEL" "$BENCH" \
    >"$BUILD_DIR/compile-iverilog-$enabled.log" 2>&1
  verilator --binary --timing -j "${SPK286_BUILD_JOBS:-4}" \
    --top-module "$TOP" -G"ENABLE=1'b$enabled" --Mdir "$BUILD_DIR/verilator-$enabled" \
    "$MODEL" "$BENCH" >"$BUILD_DIR/compile-verilator-$enabled.log" 2>&1
  for lines in 1 2 4 8 16 32 64 128; do
    for ways in 1 2; do
      (( ways <= lines )) || continue
      for extra in 0 1; do
        args=("+CODE_LINES=$lines" "+CODE_WAYS=$ways" "+CODE_HIT_EXTRA=$extra")
        suffix="$enabled-$lines-$ways-$extra"
        vvp "$BUILD_DIR/iv-$enabled" "${args[@]}" >"$BUILD_DIR/iverilog-$suffix.log" 2>&1
        cat "$BUILD_DIR/iverilog-$suffix.log"
        "$BUILD_DIR/verilator-$enabled/V$TOP" "${args[@]}" >"$BUILD_DIR/verilator-$suffix.log" 2>&1
        cat "$BUILD_DIR/verilator-$suffix.log"
      done
    done
  done
done
sha256sum --check "$BUILD_DIR/sources.sha256"
echo AT_MULTILINE_CODE_BUFFER_TEST_PASS
