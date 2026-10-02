"""Check physical memory inference of the production 4 KiB code buffer."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--report', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    a = p.parse_args()
    text = a.report.read_text(encoding='latin1')
    registers = int(re.search(r'Total registers\s*;\s*(\d+)', text)[1])
    bits = int(re.search(r'Total block memory bits\s*;\s*([\d,]+)', text)[1].replace(',', ''))
    expected_bits = 32768 + 6656
    assert bits == expected_bits, (bits, expected_bits)
    assert registers < 1500, 'Tags still appear to use thousands of registers'
    ram_rows = [line for line in text.splitlines()
                if '|ALTSYNCRAM' in line and '; M10K block ;' in line]
    assert len(ram_rows) == 2, ram_rows
    dimensions = []
    for row in ram_rows:
        fields = [field.strip() for field in row.split(';')]
        assert fields[3] == 'Simple Dual Port', fields
        dimensions.append(tuple(int(value) for value in fields[4:9]))
    assert sorted(dimensions) == [(512, 13, 512, 13, 6656),
                                  (2048, 16, 2048, 16, 32768)], dimensions
    result = {'report_sha256': hashlib.sha256(a.report.read_bytes()).hexdigest(),
              'code_payload_bytes': 4096, 'tag_bits': 6656,
              'total_registers': registers, 'block_memory_bits': bits,
              'tag_and_data_ram_verified': True,
              'ram_dimensions': dimensions,
              'scope': 'Isolated Quartus mapping; no whole-design fit/timing claim'}
    a.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
