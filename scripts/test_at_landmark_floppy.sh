#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
export PCAT_BUILD_DIR="${PCAT_BUILD_DIR:-$root/build/at-landmark-floppy}"
export AT_LANDMARK_CASES="${AT_LANDMARK_CASES:-21 22}"
exec "$root/scripts/test_at_landmark_dma.sh"
