#!/usr/bin/env bash
# Directed P17 machine mapping and ROM-write-sink data checks, then IRQ/IRET.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=${PCAT_BUILD_DIR:-$root/build/at-memory-entry}
mkdir -p "$build_dir"
nasm -DENTRY_MEMORY_PROBE=1 -f bin -o "$build_dir/entry.rom" \
  "$root/tests/firmware/pcat286_event_diag.asm"
sha256sum "$root/tests/firmware/pcat286_event_diag.asm" "$build_dir/entry.rom" \
  "$root/scripts/test_at_memory_entry.sh" > "$build_dir/firmware.sha256"
PCAT_BUILD_DIR="$build_dir/machine" AT_SYSTEM_ROM="$build_dir/entry.rom" \
  bash "$root/scripts/test_at_machine_boundary.sh"
sha256sum --check "$build_dir/firmware.sha256" > "$build_dir/firmware-verified.log"
echo AT_MEMORY_ENTRY_MAPPING_SINK_PASS
