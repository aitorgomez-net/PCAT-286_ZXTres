#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${PCAT_BUILD_DIR:-$root/build/write-admission-physical}
mkdir -p "$out"
cd "$root"
sources=(rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv
  rtl/spk286_integration/spk286_at_mister_sdram_owner.sv
  sim/spk286_integration/spk286_sdram_pin_model.sv
  sim/spk286_integration/spk286_at_sdram_write_admission_tb.sv)
sha256sum "${sources[@]}" scripts/test_at_sdram_write_admission.sh > "$out/sources.sha256"
verilator --binary --timing --assert -j 2 -Wno-fatal \
  --top-module spk286_at_sdram_write_admission_tb --Mdir "$out/obj" \
  -o write_admission "${sources[@]}" > "$out/build.log" 2>&1
timeout 30s "$out/obj/write_admission" | tee "$out/run.log"
grep -q '^AT_SDRAM_WRITE_ADMISSION_PASS' "$out/run.log"
sha256sum --check "$out/sources.sha256" > "$out/sources-verified.log"
