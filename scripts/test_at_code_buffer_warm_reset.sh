#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build=${PCAT_CODE_BUFFER_RESET_DIR:-$root/build/code-buffer-warm-reset}
mkdir -p "$build"
cd "$root"
nasm -f bin tests/firmware/code_buffer_reset_stress.asm -o "$build/stress.rom"
PCAT_BUILD_DIR="$build" AT_SYSTEM_ROM="$build/stress.rom" \
  bash scripts/test_at_bios_first_fetch.sh > "$build/first-fetch.log" 2>&1
cd "$root/rtl/video"
# Production P01/P02/P05/P06, 50 MHz, with the physical SDRAM path, real PIC,
# PIT, IRQ0/IRET and AT refresh. Reset at IDLE/COMMAND/WAIT/COMPLETE boundaries.
for state in 0 4 5 6; do
  timeout 120s "$build/verilator-obj/first_fetch_vlt" "+ROM=$build/stress.rom" \
    +CODE_BUFFER_RESET_STRESS "+FORCE_WARM_RESET_STATE=$state" +MAX_CPU_CYCLES=100000 \
    > "$build/state-$state.log" 2>&1
  grep CODE_BUFFER_RESET_STRESS "$build/state-$state.log"
  grep "FORCE_WARM_RESET_PASS state=$state " "$build/state-$state.log"
done
echo AT_CODE_BUFFER_WARM_RESET_PASS
