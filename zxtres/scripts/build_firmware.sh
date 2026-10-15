#!/usr/bin/env bash
# Build the DeMiSTify controller firmware for PCAT-286 on the ZXTRES+.
# Run from WSL or Linux (gcc and make). The first run builds the
# EightThirtyTwo toolchain (vbcc is bundled in the submodule).
#
#   zxtres/scripts/build_firmware.sh
#
# Output: build/zxtres-pcat/firmware/controller_rom{1,2}_word.vhd and
# controller.map, from zxtres/firmware/config.h and overrides.c.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/build/zxtres-pcat/firmware"
demistify="$root/DeMiSTify"

[[ -f "$demistify/EightThirtyTwo/Makefile" ]] || {
  echo "DeMiSTify submodules missing: git submodule update --init --recursive" >&2; exit 1; }
if [[ ! -x "$demistify/EightThirtyTwo/vbcc/bin/vbcc832" || ! -f "$demistify/EightThirtyTwo/lib832/lib832.a" ]]; then
  make -C "$demistify" -f bootstrap.mk > "$root/build/zxtres-pcat-toolchain.log" 2>&1 \
    || { tail -20 "$root/build/zxtres-pcat-toolchain.log" >&2; exit 1; }
fi

rm -rf "${out:?}"
mkdir -p "$out"
cp "$root/zxtres/firmware/config.h" "$root/zxtres/firmware/overrides.c" "$out/"
make -C "$out" -f "$demistify/firmware/Makefile" DEMISTIFYPATH="$demistify" \
  ROMSIZE1=8192 ROMSIZE2=8192 controller_rom_word.vhd
ls -l "$out"/controller.bin "$out"/controller_rom1_word.vhd "$out"/controller_rom2_word.vhd
