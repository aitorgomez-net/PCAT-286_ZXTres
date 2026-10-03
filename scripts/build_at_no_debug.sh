#!/usr/bin/env bash
# Run from WSL. Each invocation freezes current inputs in a new workspace;
# no old Quartus database or bitstream can be reused from the source checkout.
set -euo pipefail

prepare_only=0
frozen_run=0
if [[ ${1:-} == --prepare-only ]]; then
  prepare_only=1
  shift
fi
if [[ ${1:-} == --frozen-run ]]; then
  frozen_run=1
  shift
  [[ $# == 1 ]] || { echo '--frozen-run requires one pre-frozen new run directory' >&2; exit 2; }
fi
if [[ $# -gt 1 ]]; then
  echo 'Usage: build_at_no_debug.sh [--prepare-only | --frozen-run] [NEW_RUN_DIRECTORY]' >&2
  exit 2
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${QUARTUS_IMAGE:-raetro/quartus:mister}
timing_script=scripts/report_p05_at_timing.tcl
if [[ ${AT_DETAILED_TIMING:-0} == 1 ]]; then
  timing_script=scripts/report_at_50mhz_timing.tcl
elif [[ ${AT_DETAILED_TIMING:-0} != 0 ]]; then
  echo 'AT_DETAILED_TIMING must be 0 or 1' >&2
  exit 2
fi
run_dir=$(realpath -m "${1:-$root/build/at-no-debug/$(date -u +%Y%m%dT%H%M%S)-$$}")
if [[ $frozen_run == 0 ]]; then
  [[ ! -e "$run_dir" ]] || { echo "Run directory already exists: $run_dir" >&2; exit 2; }
  python3 "$root/scripts/p05_snapshot.py" "$run_dir" --revision PCAT-286
else
  # Allows a snapshot created by native Python when Git on a mounted NTFS
  # checkout is slow. Never accept an existing database or compilation.
  [[ -f "$run_dir/manifest.json" && ! -e "$run_dir/compile-started.txt" ]]
  python3 - "$run_dir" <<'PY'
from pathlib import Path
import hashlib, json, sys
r = Path(sys.argv[1])
m = json.loads((r/'manifest.json').read_text())
assert m['revision'] == 'PCAT-286' and not m['fit_sha256']
for n, h in m['source_sha256'].items():
    p = Path(n.replace('\\', '/'))
    assert not p.is_absolute() and '..' not in p.parts
    assert hashlib.sha256((r/'work'/p).read_bytes()).hexdigest() == h, n
print('FROZEN_NEW_RUN_INPUTS_PASS', len(m['source_sha256']))
PY
fi
work="$run_dir/work"
output_dir=$(sed -n 's/.*-name PROJECT_OUTPUT_DIRECTORY \([^ ]*\).*/\1/p' "$work/PCAT-286.qsf" | tr -d '\r"')
[[ "$output_dir" == output_files ]]
out="$work/$output_dir"
rbf="$out/PCAT-286.rbf"
[[ ! -e "$work/db" && ! -e "$work/incremental_db" && ! -e "$out" ]]
bash "$work/scripts/test_at_profile_elab.sh" | tee "$run_dir/profile-check.log"
docker image inspect "$image" --format '{{.Id}}' > "$run_dir/container-image.txt"
docker run --rm -v "$work:/build" -w /build "$image" \
  quartus_sh -t scripts/check_p05_at_project.tcl PCAT-286 \
  > "$run_dir/project-check.log" 2>&1 || {
    cat "$run_dir/project-check.log"
    exit 1
  }

echo "AT_NO_DEBUG_PREPARED $work"
if [[ $prepare_only == 1 ]]; then
  echo 'Preparation only: synthesis, fitting and RBF generation have not run.'
  exit 0
fi

# Start with an empty database/output directory and check that a NEW artifact
# exists. A successful flow with an unchanged old RBF is never called success.
date -u +%Y-%m-%dT%H:%M:%SZ > "$run_dir/compile-started.txt"
docker run --rm -v "$work:/build" -w /build "$image" \
  quartus_sh --flow compile PCAT-286.qsf \
  2>&1 | tee "$run_dir/compile.log"
[[ -s "$rbf" && "$rbf" -nt "$run_dir/compile-started.txt" ]] || {
  echo "No newly generated RBF: $rbf" >&2
  exit 1
}
sha256sum "$rbf" "$out/PCAT-286.sof" > "$run_dir/bitstreams.sha256"
stat -c '%n | %s bytes | %y' "$rbf" | tee "$run_dir/rbf-info.txt"
docker run --rm -v "$work:/build" -v "$run_dir:/run-output" -w /build "$image" \
  quartus_sta -t "$timing_script" PCAT-286 /run-output/timing \
  > "$run_dir/timing.log" 2>&1 || {
    cat "$run_dir/timing.log"
    exit 1
  }
echo "PCAT_AT_NEW_RBF $rbf"
echo "Timing reports: $run_dir/timing"
echo 'Artifact generation completed. Check timing reports and validate on hardware before acceptance.'
