#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build="${PCAT_BUILD_DIR:-$root/build/at-floppy-write-protect}"
exec python3 "$root/scripts/test_at_floppy_write_protect.py" --output "$build"
