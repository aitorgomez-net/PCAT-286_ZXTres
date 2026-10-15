#!/usr/bin/env python3
"""List the PC/AT machine sources from the MiSTer Quartus manifest.

  pcat_sources.py sv|vhdl|includes

Reads files.qip and every QIP it includes, so the ZXTRES build follows the
MiSTer core's own file list. MiSTer-only files are left out: the HPS
extension bus, the Quartus PLL IP and the files of the Quartus project
that the ZXTRES guest replaces. Paths are relative to the repository root,
one per line.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
EXCLUDE = {
    'rtl/hps_ext.v',            # MiSTer HPS extension bus
    'rtl/common/bram.vhd',      # Altera altsyncram wrapper, not instantiated
}
EXCLUDE_PREFIXES = ('rtl/pll',)  # Quartus PLL IP (the guest has an MMCM)

ASSIGN = re.compile(r'set_global_assignment\s+-name\s+(\w+)\s+(.+)$')
JOIN = re.compile(r'\[file join \$::quartus\(qip_path\)\s+"?([^"\]]+)"?\s*\]')


def parse(qip, found):
    base = qip.parent
    for line in qip.read_text(errors='replace').splitlines():
        line = line.split('#', 1)[0].strip()
        match = ASSIGN.match(line)
        if not match:
            continue
        kind, value = match.group(1), match.group(2).strip()
        join = JOIN.search(value)
        if join:
            path = (base / join.group(1).strip()).resolve()
        else:
            path = (ROOT / value.strip('"')).resolve()
        if kind == 'QIP_FILE':
            parse(path, found)
        elif kind in ('VERILOG_FILE', 'SYSTEMVERILOG_FILE', 'VHDL_FILE'):
            relative = path.relative_to(ROOT).as_posix()
            if relative in EXCLUDE or relative.startswith(EXCLUDE_PREFIXES):
                continue
            entry = ('vhdl' if kind == 'VHDL_FILE' else 'sv', relative)
            if entry not in found:
                found.append(entry)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ('sv', 'vhdl', 'includes'):
        sys.exit(__doc__)
    found = []
    parse(ROOT / 'files.qip', found)
    if sys.argv[1] == 'includes':
        # Directories of every SystemVerilog source, for `include lookups.
        directories = sorted({str(Path(p).parent.as_posix()) for k, p in found if k == 'sv'})
        print('\n'.join(['.'] + directories))
    else:
        print('\n'.join(p for k, p in found if k == sys.argv[1]))


if __name__ == '__main__':
    main()
