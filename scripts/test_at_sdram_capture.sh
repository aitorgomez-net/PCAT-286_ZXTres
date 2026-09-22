#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir="${PCAT_BUILD_DIR:-$root/build/at-sdram-capture}"
mkdir -p "$build_dir"
sources=(
  "$root/rtl/KFPC-XT/HDL/KFSDRAM/HDL/KFSDRAM.sv"
  "${AT_SDRAM_OWNER_SOURCE:-$root/rtl/spk286_integration/spk286_at_mister_sdram_owner.sv}"
  "$root/sim/spk286_integration/spk286_sdram_pin_model.sv"
  "$root/sim/spk286_integration/spk286_at_sdram_capture_tb.sv"
)
cd "$build_dir"
# Cover the actual XS/XSDS board wiring and dedicated DQM pins separately.
for wiring in 1 0; do
  iverilog -g2012 -s spk286_at_sdram_capture_tb \
    -Pspk286_at_sdram_capture_tb.DQM_FROM_ADDRESS=$wiring \
    -o "capture-$wiring" "${sources[@]}" >"build-$wiring.log" 2>&1
  args=()
  [[ "${AT_SDRAM_VCD:-0}" == 1 ]] && args+=(+vcd)
  vvp "capture-$wiring" "${args[@]}" | tee "nominal-$wiring.log"
  [[ ! -f at_sdram_capture.vcd ]] || mv at_sdram_capture.vcd "capture-$wiring.vcd"
  # Artificial +4ns forwarded-clock shift must expose the finite DQ window.
  # This is a sensitivity control, not a measured board delay.
  iverilog -g2012 -s spk286_at_sdram_capture_tb \
    -Pspk286_at_sdram_capture_tb.DQM_FROM_ADDRESS=$wiring \
    -Pspk286_at_sdram_capture_tb.SDRAM_CLOCK_SKEW_NS=4.0 \
    -o "skew-$wiring" "${sources[@]}" >"skew-build-$wiring.log" 2>&1
  if vvp "skew-$wiring" >"skew-$wiring.log" 2>&1; then
    echo "Clock sensitivity control unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'CAPTURE_TEST read 0ffff0 expected=5bea actual=zzzz' "skew-$wiring.log"
  echo "AT_SDRAM_CLOCK_SKEW_CONTROL_PASS dqm_from_address=$wiring"
done
echo AT_SDRAM_CAPTURE_TEST_PASS
