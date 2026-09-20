#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build="${PCAT_BUILD_DIR:-$root/build/at-phoenix-fdc-post}"
rom="${AT_PHOENIX_ROM:-$root/SW/ROMs/test/Phoenix_AT_Clone_A286_v1.01_64K.ROM}"
expected=306ac7c3a0ee713385de53f5dd0625ee040f3ea6606b09e9d5fce3c6a00b273e
[[ -f "$rom" ]] || { echo "Phoenix ROM unavailable: $rom" >&2; exit 1; }
[[ $(sha256sum "$rom" | cut -d ' ' -f 1) == "$expected" ]] || {
  echo 'Unexpected Phoenix ROM: fixture entry addresses are version-specific' >&2; exit 1;
}
mkdir -p "$build"
cd "$root"
nasm -f bin -DPHOENIX_ROM="\"$rom\"" tests/firmware/phoenix_fdc_post_fixture.asm -o "$build/fixture.rom"
PCAT_BUILD_DIR="$build" AT_SYSTEM_ROM="$build/fixture.rom" bash scripts/test_at_bios_first_fetch.sh > "$build/build-first-fetch.log" 2>&1
args=(+PHOENIX_FDC +FULL_BOOT +MAX_CPU_CYCLES=600000000)
if [[ ${AT_PHOENIX_REAL_TIME:-0} != 1 ]]; then
  # Both device timebases are accelerated tenfold, never the result bytes or
  # BIOS logic. This is functional integration evidence, NOT hardware timing.
  args+=(+PHOENIX_FDC_FAST)
fi
cd "$root/rtl/video"
timeout "${AT_PHOENIX_TIMEOUT:-600}s" stdbuf -oL "$build/verilator-obj/first_fetch_vlt" \
  "+ROM=$build/fixture.rom" "${args[@]}" | tee "$build/post.log"
grep -q PHOENIX_POST_FDC_PASS "$build/post.log"
