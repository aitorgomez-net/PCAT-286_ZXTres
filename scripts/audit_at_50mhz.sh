#!/usr/bin/env bash
# Preserve the existing fit and extract paths without changing its artifacts.
# This does not perform synthesis/fitting or declare timing closure.
# Usage: audit_at_50mhz.sh NEW_RUN [REFERENCE_RUN [SYSTEM_SDC_OVERLAY]]
# The optional reference reuses its frozen work/ and manifest. An optional SDC
# is frozen separately and reanalysed on that fit; it is not a new RTL fit.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
run=$(realpath -m "${1:-$root/build/timing-50mhz-$(date -u +%Y%m%dT%H%M%S)}")
[[ $# -le 3 && ! -e "$run" ]]
cd "$root"
if [[ $# -ge 2 ]]; then
  reference=$(realpath "$2")
  [[ -f "$reference/manifest.json" && -d "$reference/work/db" ]]
  mkdir -p "$run"
  cp "$reference/manifest.json" "$run/manifest.json"
  source_work="$reference/work"
else
  python3 scripts/p05_snapshot.py "$run" --revision PCAT-286 --with-fit
  source_work="$run/work"
fi
printf '%s\n' "$source_work" > "$run/reference-work.txt"
mkdir -p "$run/tools"
cp "$root/scripts/report_at_50mhz_timing.tcl" \
  "$root/scripts/audit_at_50mhz.sh" \
  "$root/scripts/summarize_at_50mhz_timing.py" "$run/tools/"
sha256sum "$run"/tools/* > "$run/audit-tools.sha256"
overlay=0
if [[ $# == 3 ]]; then
  [[ -f "$3" ]]
  mkdir -p "$run/overlay"
  cp "$3" "$run/overlay/SYSTEM.sdc"
  sha256sum "$run/overlay/SYSTEM.sdc" > "$run/overlay-sdc.sha256"
  overlay=1
fi
sha256sum output_files/PCAT-286.rbf output_files/PCAT-286.sta.rpt \
  output_files/PCAT-286.flow.rpt > "$run/original-artifacts.sha256"
docker image inspect raetro/quartus:mister --format '{{.Id}}' > "$run/container-image.txt"
docker run --rm -v "$source_work:/reference:ro" -v "$run:/results" \
  -v "$run/tools:/scripts:ro" -e "AT_AUDIT_SDC_OVERLAY=$overlay" \
  raetro/quartus:mister bash -c '
    set -euo pipefail
    mkdir -p /build
    cp -a /reference/db /build/db
    cp /reference/*.qpf /reference/*.qsf /reference/*.qip /reference/*.sdc /reference/*.tcl /build/
    if [[ "$AT_AUDIT_SDC_OVERLAY" == 1 ]]; then
      cp /results/overlay/SYSTEM.sdc /build/SYSTEM.sdc
      echo "CONSTRAINT-ONLY REANALYSIS: reference fit, frozen SYSTEM.sdc overlay."
    fi
    for dir in rtl vendor SW sys; do ln -s /reference/$dir /build/$dir; done
    cd /build
    quartus_sta -t /scripts/report_at_50mhz_timing.tcl PCAT-286 /results/reports
  ' > "$run/audit.log" 2>&1
sha256sum --check "$run/original-artifacts.sha256" > "$run/original-artifacts-verified.log"
sha256sum --check "$run/audit-tools.sha256" > "$run/audit-tools-verified.log"
if [[ $overlay == 1 ]]; then
  sha256sum --check "$run/overlay-sdc.sha256" > "$run/overlay-verified.log"
fi
echo "AT_50MHZ_AUDIT_EXTRACTED $run (existing fit, no synthesis/fitter/RBF)"
