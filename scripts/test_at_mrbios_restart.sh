#!/usr/bin/env bash
# Exact MR BIOS 1.65 IRQ1 handler, production PIC/code buffer/SDRAM pins.
# The private ROM is supplied by the caller and is never modified.
set -euo pipefail
ulimit -c 0
root=$(cd "$(dirname "$0")/.." && pwd)
build="${PCAT_BUILD_DIR:-$root/build/at-mrbios-restart}"
rom="${AT_MRBIOS_ROM:-$root/build/mrbios_1.65_286.bin}"
rom=$(realpath "$rom")
expected=6f936ee53ba58663d1ccc7b80b1f5caba841f3f816c4dca15477ca540f9f252f
[[ $(sha256sum "$rom" | cut -d ' ' -f 1) == "$expected" ]] || {
  echo 'This fixture requires the investigated 64 KiB MR BIOS 1.65 ROM.' >&2
  exit 1
}
mkdir -p "$build"
build=$(realpath "$build")
cd "$root"
nasm -f bin tests/firmware/mrbios_irq_restart.asm -o "$build/irq-fixture.bin"
nasm -f bin -DMRBIOS_REP_IDLE=1 tests/firmware/mrbios_irq_restart.asm \
  -o "$build/irq-rep-fixture.bin"
PCAT_BUILD_DIR="$build" bash scripts/test_at_bios_first_fetch.sh \
  > "$build/build-first-fetch.log" 2>&1
cd "$root/rtl/video"
for variant in irq irq-rep; do
  extra=()
  if [[ $variant == irq-rep ]]; then extra+=(+MRBIOS_REQUIRE_REP); fi
  timeout 360s stdbuf -oL "$build/verilator-obj/first_fetch_vlt" "+ROM=$rom" \
    +FULL_BOOT "+MRBIOS_IRQ_FIXTURE=$build/$variant-fixture.bin" \
    +MRBIOS_RESTARTS=3 +TRACE_POST +MAX_CPU_CYCLES=15000000 "${extra[@]}" \
    > "$build/$variant.log" 2>&1
  grep MRBIOS_P03_RESTART_PASS "$build/$variant.log"
done
echo AT_MRBIOS_IRQ_RESTART_TEST_PASS
