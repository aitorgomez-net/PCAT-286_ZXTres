#!/usr/bin/env bash
# Isolated 4 KiB code-buffer mapping check; no fitter, timing analysis or RBF.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output=${PCAT_BUILD_DIR:-$root/build/at-code-buffer-quartus}
rtl=${PCAT_CODE_BUFFER_RTL:-$root/rtl/spk286_integration/spk286_at_sdram_read_buffer.sv}
rtl=$(realpath "$rtl")
case "$rtl" in "$root"/*) ;; *) echo 'RTL must be inside the workspace' >&2; exit 1;; esac
relative=${rtl#"$root"/}
mkdir -p "$output"
cd "$root"
sha256sum "$rtl" scripts/check_at_code_buffer_quartus.sh \
  scripts/check_at_code_buffer_mapping.py > "$output/sources.sha256"
python3 - "$rtl" "$output/code_buffer_top.sv" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
ports = source.split(') (', 1)[1].split('\n);', 1)[0]
Path(sys.argv[2]).write_text('module code_buffer_top (\n'+ports+'\n);\n'
    "spk286_at_sdram_read_buffer #(.LINE_COUNT(512), .SYNC_TAGS(1'b1)) dut (.*);\n"
    'endmodule\n')
PY
docker image inspect raetro/quartus:mister --format '{{.Id}}' > "$output/quartus-image.txt"
docker run --rm -v "$root:/source:ro" -v "$output:/results" \
  -e "CODE_BUFFER_SOURCE=$relative" raetro/quartus:mister bash -c '
    set -euo pipefail
    mkdir -p /build
    cd /build
    cp "/source/$CODE_BUFFER_SOURCE" spk286_at_sdram_read_buffer.sv
    cp /results/code_buffer_top.sv .
    cat > code_buffer.qpf <<EOF
QUARTUS_VERSION = "17.0.2"
PROJECT_REVISION = "code_buffer"
EOF
    cat > code_buffer.qsf <<EOF
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEBA6U23I7
set_global_assignment -name TOP_LEVEL_ENTITY code_buffer_top
set_global_assignment -name SYSTEMVERILOG_FILE spk286_at_sdram_read_buffer.sv
set_global_assignment -name SYSTEMVERILOG_FILE code_buffer_top.sv
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
EOF
    quartus_map code_buffer > /results/code-buffer-map.log 2>&1
    cp output_files/code_buffer.map.rpt /results/
    cp output_files/code_buffer.map.summary /results/
    cp code_buffer.qsf /results/
    test ! -e output_files/code_buffer.rbf
  '
sha256sum --check "$output/sources.sha256" > "$output/sources-verified.log"
python3 "$root/scripts/check_at_code_buffer_mapping.py" \
  --report "$output/code_buffer.map.rpt" --output "$output/mapping.json"
echo 'CODE_BUFFER_QUARTUS_MAP_PASS (isolated module, no fitter/timing/RBF)'
