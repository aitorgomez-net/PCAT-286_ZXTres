#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build="${PCAT_BUILD_DIR:-$root/build/at-phoenix-pm87}"
rom="${AT_PHOENIX_ROM:-$root/SW/ROMs/test/Phoenix_AT_Clone_A286_v1.01_64K.ROM}"
expected=306ac7c3a0ee713385de53f5dd0625ee040f3ea6606b09e9d5fce3c6a00b273e

[[ -f "$rom" ]] || { echo "Phoenix ROM unavailable: $rom" >&2; exit 1; }
[[ $(sha256sum "$rom" | cut -d ' ' -f 1) == "$expected" ]] || {
  echo 'Unexpected Phoenix ROM: fixture entry addresses are version-specific' >&2
  exit 1
}

mkdir -p "$build"
cd "$root"
nasm -f bin -DPHOENIX_ROM="\"$rom\"" \
  tests/firmware/phoenix_pm87_fixture.asm -o "$build/fixture.rom"
PCAT_BUILD_DIR="$build" AT_SYSTEM_ROM="$build/fixture.rom" \
  bash scripts/test_at_bios_first_fetch.sh > "$build/build-first-fetch.log" 2>&1

cd "$root/rtl/video"
timeout "${AT_PHOENIX_TIMEOUT:-180}s" stdbuf -oL \
  "$build/verilator-obj/first_fetch_vlt" \
  "+ROM=$build/fixture.rom" +PHOENIX_PM87 +FULL_BOOT \
  +MAX_CPU_CYCLES=5000000 | tee "$build/pm87.log"
grep -q PHOENIX_PM87_PASS "$build/pm87.log"
