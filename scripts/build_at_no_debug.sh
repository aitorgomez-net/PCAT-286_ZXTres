#!/usr/bin/env bash
# Run from WSL. Each invocation freezes current inputs in a new workspace;
# no old Quartus database or bitstream can be reused from the source checkout.
set -euo pipefail

prepare_only=0
if [[ ${1:-} == --prepare-only ]]; then
  prepare_only=1
  shift
fi
if [[ $# -gt 1 ]]; then
  echo 'Usage: build_at_no_debug.sh [--prepare-only] [NEW_RUN_DIRECTORY]' >&2
  exit 2
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${QUARTUS_IMAGE:-raetro/quartus:mister}
run_dir=$(realpath -m "${1:-$root/build/at-no-debug/$(date -u +%Y%m%dT%H%M%S)-$$}")
[[ ! -e "$run_dir" ]] || { echo "Run directory already exists: $run_dir" >&2; exit 2; }

python3 "$root/scripts/p05_snapshot.py" "$run_dir" --revision PCAT-286
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
  quartus_sta -t scripts/report_p05_at_timing.tcl PCAT-286 /run-output/timing \
  > "$run_dir/timing.log" 2>&1 || {
    cat "$run_dir/timing.log"
    exit 1
  }
echo "PCAT_AT_NEW_RBF $rbf"
echo "Timing reports: $run_dir/timing"
echo 'Artifact generation completed. Check timing reports and validate on hardware before acceptance.'
