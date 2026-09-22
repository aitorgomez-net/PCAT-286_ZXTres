#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build=${PCAT_CODE_BUFFER_INTEGRATION_DIR:-$root/build/code-buffer-integration}
mkdir -p "$build"
cd "$root"
for test in test_at_mister_memory_port test_at_mister_sdram_owner \
            test_at_hps_rom_loader test_at_cdc test_at_machine_boundary \
            test_at_loadall_xms test_at_memory_perf test_at_code_buffer_warm_reset; do
  echo "CODE_BUFFER_INTEGRATION_START $test"
  if ! bash "scripts/$test.sh" > "$build/$test.log" 2>&1; then
    tail -60 "$build/$test.log"
    exit 1
  fi
  echo "CODE_BUFFER_INTEGRATION_PASS $test"
done
echo AT_CODE_BUFFER_INTEGRATION_PASS
