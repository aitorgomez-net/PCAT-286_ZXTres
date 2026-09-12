#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
export PCAT_BUILD_DIR="${PCAT_BUILD_DIR:-$root/build/at-landmark-keyboard}"
export AT_SYSTEM_ROM="${AT_SYSTEM_ROM:-$root/SW/ROMs/test/Supersoft_Landmark_1.2.0_AT_5170_SKIP_PM_V2_64K.BIN}"
export AT_LANDMARK_CASES="${AT_LANDMARK_CASES:-19 20}"
"$root/scripts/test_at_landmark_dma.sh"
echo AT_LANDMARK_KEYBOARD_TEST_PASS
