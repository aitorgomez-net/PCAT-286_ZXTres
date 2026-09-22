#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0

root=$(cd "$(dirname "$0")/.." && pwd)
build="${PCAT_BUILD_DIR:-$root/build/at-loadall-xms}"
mkdir -p "$build"
cd "$root"
nasm -f bin tests/firmware/loadall_xms_fixture.asm -o "$build/fixture.rom"
PCAT_BUILD_DIR="$build" AT_SYSTEM_ROM="$build/fixture.rom" \
  bash scripts/test_at_bios_first_fetch.sh > "$build/first-fetch.log" 2>&1
cd "$root/rtl/video"
timeout 180s "$build/verilator-obj/first_fetch_vlt" \
  "+ROM=$build/fixture.rom" +LOADALL_XMS +FULL_BOOT \
  +MAX_CPU_CYCLES=1000000 | tee "$build/loadall-xms.log"
grep -q AT_LOADALL_XMS_PASS "$build/loadall-xms.log"
