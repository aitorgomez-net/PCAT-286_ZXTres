#!/usr/bin/env bash
# Simulation-only bottleneck attribution and physical-owner counterfactuals.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build_dir=${PCAT_BUILD_DIR:-$root/build/checkit-profile}
export PCAT_BUILD_DIR="$build_dir" PCAT_PROFILE=1
bash "$root/scripts/test_checkit_directed.sh"
for mode in 1 2 3 4 5 6; do
  mkdir -p "$build_dir/ideal-owner-$mode"
  for workload in dhrystone whetstone working_set dhrystone21; do
    "$build_dir/obj/checkit_workload" \
      "+ROM=$build_dir/checkit-$workload.rom" "+NAME=$workload" \
      +NATIVE=1 +P03=1 +PROFILE=1 "+IDEAL_OWNER=$mode" \
      > "$build_dir/ideal-owner-$mode/$workload-p03-1.log"
  done
done
python3 "$root/scripts/report_checkit_profile.py" "$build_dir"
