#!/usr/bin/env bash
# Isolated RAM inference check only: no fitter, timing analysis or RBF.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
output=${PCAT_BUILD_DIR:-$root/build/at-ram-buffer-quartus}
mkdir -p "$output"
cd "$root"
sha256sum rtl/spk286_integration/spk286_at_sdram_data_buffer.sv \
  scripts/check_at_ram_read_buffer_quartus.sh > "$output/sources.sha256"
docker image inspect raetro/quartus:mister --format '{{.Id}}' > "$output/quartus-image.txt"
docker run --rm -v "$root:/source:ro" -v "$output:/results" \
  raetro/quartus:mister bash -c '
    set -euo pipefail
    mkdir -p /build
    cd /build
    cp /source/rtl/spk286_integration/spk286_at_sdram_data_buffer.sv .
    cat > ram_buffer.qpf <<EOF
QUARTUS_VERSION = "17.0.2"
PROJECT_REVISION = "ram_buffer"
EOF
    cat > ram_buffer.qsf <<EOF
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEBA6U23I7
set_global_assignment -name TOP_LEVEL_ENTITY spk286_at_sdram_data_buffer
set_global_assignment -name SYSTEMVERILOG_FILE spk286_at_sdram_data_buffer.sv
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
EOF
    quartus_map ram_buffer > /results/ram-buffer-map.log 2>&1
    cp output_files/ram_buffer.map.rpt /results/
    cp output_files/ram_buffer.map.summary /results/
    test ! -e output_files/ram_buffer.rbf
  '
grep 'Analysis & Synthesis was successful' "$output/ram-buffer-map.log"
# 512 entries * (16 data + 15 tag) bits. Validity is a separate resettable vector.
grep -E '15,872|15872' "$output/ram_buffer.map.rpt"
sha256sum --check "$output/sources.sha256" > "$output/sources-verified.log"
echo 'RAM_READ_BUFFER_QUARTUS_MAP_PASS (isolated module, no fitter/timing/RBF)'
