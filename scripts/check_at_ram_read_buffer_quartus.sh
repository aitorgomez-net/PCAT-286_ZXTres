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
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, json, re, sys
out=Path(sys.argv[1])
report=out/'ram_buffer.map.rpt'
text=report.read_text(encoding='latin1')
bits=int(re.search(r'Total block memory bits\s*;\s*([\d,]+)',text)[1].replace(',',''))
registers=int(re.search(r'Total registers\s*;\s*(\d+)',text)[1])
ram_rows=[line for line in text.splitlines() if '|ALTSYNCRAM' in line and '; M10K block ;' in line]
assert bits==16384 and len(ram_rows)==2, (bits,ram_rows)
assert registers<1800, 'Data/tag arrays appear to have become registers'
for row in ram_rows:
    fields=[field.strip() for field in row.split(';')]
    assert fields[3]=='Simple Dual Port',fields
    assert tuple(map(int,fields[4:9]))==(256,32,256,32,8192),fields
result={'total_registers':registers,'block_memory_bits':bits,'data_payload_bytes':1024,
        'sets':256,'ways':2,'ram_rows':ram_rows,
        'report_sha256':hashlib.sha256(report.read_bytes()).hexdigest(),
        'scope':'Isolated mapping; no Fitter/timing/whole-design occupancy claim'}
(out/'mapping.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
PY
sha256sum --check "$output/sources.sha256" > "$output/sources-verified.log"
echo 'RAM_READ_BUFFER_QUARTUS_MAP_PASS (isolated module, no fitter/timing/RBF)'
