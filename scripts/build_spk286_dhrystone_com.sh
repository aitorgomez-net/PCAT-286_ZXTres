#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out_dir="${PCAT_BUILD_DIR:-$root/build/dos}"
mkdir -p "$out_dir"
nasm -O9 -f bin \
  "$root/tests/dos/spk286_dhrystone21_com.asm" \
  -o "$out_dir/SPK286D.COM"
test "$(stat -c %s "$out_dir/SPK286D.COM")" -le 65535
sha256sum "$out_dir/SPK286D.COM"
