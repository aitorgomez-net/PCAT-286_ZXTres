#!/usr/bin/env bash
# Front-end check ONLY. No mapping synthesis, fitter, assembler or RBF.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output="${AT_CDC_CHECK_OUTPUT:-$root/build/at-cdc}"
mkdir -p "$output"
docker run --rm -v "$root:/source:ro" -v "$output:/results" \
  raetro/quartus:mister bash -c '
    set -euo pipefail
    mkdir -p /build
    for dir in rtl sys vendor SW scripts; do cp -a "/source/$dir" "/build/$dir"; done
    for ext in sv v vh qpf qsf qip sdc tcl mif mem hex; do
      for file in /source/*.$ext; do
        if [[ -f "$file" ]]; then cp "$file" /build/; fi
      done
    done
    cd /build
    sha256sum PCAT-286.qsf PCAT-286.sv SYSTEM.sdc sys/sys_top.sdc sys/sys_top.v \
      sys/sys.qip sys/shadowmask.sv sys/at_frame_counter.sv sys/at_scanlines_status.sv \
      sys/at_scaler_config.sv sys/math.sv \
      sys/at_hdmi_vsync.sv sys/at_video_output_config.sv sys/at_hdmi_output.sv \
      rtl/spk286_integration/spk286_integration.qip \
      rtl/spk286_integration/spk286_at_video_adapter.sv \
      rtl/spk286_integration/at_video_options_cdc.sv \
      sys/hps_io.sv sys/osd.v sys/ascal.vhd sys/pll_hdmi_adj.vhd \
      sys/at_cdc_snapshot.sv sys/at_cdc_snapshot.vhd > /results/frontend-inputs.sha256
    quartus_sh -t scripts/check_p05_at_project.tcl PCAT-286 > /results/project-final.log 2>&1
    quartus_map --analysis_and_elaboration PCAT-286 -c PCAT-286 > /results/quartus-final-elaboration.log 2>&1
    test ! -e output_files/PCAT-286.rbf
  '
grep 'Analysis & Elaboration was successful' "$output/quartus-final-elaboration.log"
echo 'AT_CDC_QUARTUS_FRONTEND_PASS (no synthesis/fitter/RBF)'
