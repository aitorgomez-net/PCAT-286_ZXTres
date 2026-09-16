#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 3 && $# != 4 ]]; then
  echo 'Usage: run_p05_audit.sh SNAPSHOT_WORK REVISION OUTPUT [--current-sdc]' >&2
  exit 2
fi
overlay=${4:-}
[[ -z "$overlay" || "$overlay" == --current-sdc ]] || exit 2
root=$(cd "$(dirname "$0")/.." && pwd)
source_work=$(realpath "$1")
revision=$2
output=$(realpath -m "$3")
[[ -f "$source_work/$revision.qsf" && -d "$source_work/db" ]]
[[ ! -e "$output" ]] || { echo "Output already exists: $output" >&2; exit 2; }
mkdir -p "$output"
docker image inspect raetro/quartus:mister --format '{{.Id}}' > "$output/container-image.txt"
if [[ -n "$overlay" ]]; then
  sha256sum "$root/$revision.qsf" "$root/files.qip" "$root/SYSTEM.sdc" "$root/sys/sys_top.sdc" > "$output/overlay-sdc.sha256"
fi
docker run --rm \
  -v "$source_work:/reference:ro" \
  -v "$root/scripts:/scripts:ro" \
  -v "$root:/candidate:ro" \
  -v "$output:/audit" \
  -e "P05_REVISION=$revision" \
  -e "P05_SDC_OVERLAY=$overlay" \
  raetro/quartus:mister bash -c '
    set -euo pipefail
    mkdir -p /build
    cp -a /reference/db /build/db
    cp /reference/*.qpf /reference/*.qsf /reference/*.qip /reference/*.sdc /reference/*.tcl /build/
    if [[ -n "$P05_SDC_OVERLAY" ]]; then
      cp "/candidate/$P05_REVISION.qsf" /candidate/files.qip /candidate/SYSTEM.sdc /build/
      cp -a /reference/sys /build/sys
      cp /candidate/sys/sys_top.sdc /build/sys/sys_top.sdc
      export P05_REFERENCE_FIT=1
      echo "CONSTRAINT-ONLY REANALYSIS: reference fit, not candidate RTL."
    fi
    for dir in rtl vendor SW; do ln -s /reference/$dir /build/$dir; done
    if [[ -z "$P05_SDC_OVERLAY" ]]; then ln -s /reference/sys /build/sys; fi
    cd /build
    quartus_sta -t /scripts/report_p05_at_timing.tcl "$P05_REVISION" /audit/reports
  ' > "$output/audit.log" 2>&1
echo "P05_AUDIT_PASS $output"
