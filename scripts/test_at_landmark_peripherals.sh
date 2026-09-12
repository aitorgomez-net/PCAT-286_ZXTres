#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PCAT_BUILD_DIR="${PCAT_BUILD_DIR:-$root/build/at-landmark-peripherals}"
export AT_LANDMARK_CASES="${AT_LANDMARK_CASES:-4 5 6 7 8 9 10}"
"$root/scripts/test_at_landmark_dma.sh"
echo AT_LANDMARK_PERIPHERALS_TEST_PASS
