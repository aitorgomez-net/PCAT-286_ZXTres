#!/usr/bin/env python3
"""Clean GHDL's Verilog output for Verilator.

  fix_ghdl_verilog.py FILE

GHDL 4.1 can emit, within one module:

- the same net declared twice, plus a self-assignment
  ("assign x = x; // (signal)"); both are redundant and are removed;
- a second, different net with the name of a VHDL signal, for the output
  of a sub-instance that feeds that signal (for example "wire [29:0]
  cpu_addr" from "addr => cpu_addr(31 downto 2)", next to "wire [31:0]
  cpu_addr"), or with the name of a port. The second net is renamed to
  NAME__net where it is used as that instance output: in instance port
  connections, in concatenations, and on the right-hand side of the
  "// (signal)" assignment that forms the VHDL signal.

Changes the file in place and reports what it did.
"""
from pathlib import Path
import re
import sys

NAME = r'[A-Za-z_][A-Za-z0-9_$]*'
DECLARATION = re.compile(rf'^\s*(wire|reg)\s*(\[[^\]]+\])?\s*({NAME})\s*;\s*$')
PORT = re.compile(rf'^\s*\(?\s*(input|output|inout)\s*(\[[^\]]+\])?\s*({NAME})\s*[,)]')
SELF_ASSIGN = re.compile(rf'^\s*assign\s+({NAME})\s*=\s*\1\s*;.*$')


def fix_module(lines):
    declared = {}                      # name -> (kind, width)
    renamed = set()
    out = []
    removed = 0
    for line in lines:
        port = PORT.match(line)
        if port:
            declared[port.group(3)] = ('port', port.group(2) or '')
        match = DECLARATION.match(line)
        if match:
            name, key = match.group(3), (match.group(1), match.group(2) or '')
            if name in declared:
                if declared[name] == key:
                    removed += 1
                    continue
                renamed.add(name)
                line = line.replace(name, name + '__net', 1)
            else:
                declared[name] = key
        if SELF_ASSIGN.match(line):
            removed += 1
            continue
        out.append(line)
    if renamed:
        for index, line in enumerate(out):
            for name in renamed:
                line = re.sub(rf'(\.{NAME}\(\s*){name}(\s*\))', rf'\g<1>{name}__net\g<2>', line)
                line = re.sub(rf'([{{,]\s*){name}(\s*[,}}])', rf'\g<1>{name}__net\g<2>', line)
                if line.rstrip().endswith('// (signal)'):
                    line = re.sub(rf'(=\s*){name}(\s*;)', rf'\g<1>{name}__net\g<2>', line)
            out[index] = line
    return out, removed, renamed


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = Path(sys.argv[1])
    result, module, total_removed, all_renamed = [], [], 0, []
    for line in path.read_text().splitlines() + ['']:
        if line.startswith('module ') and module:
            fixed, removed, renamed = fix_module(module)
            result += fixed
            total_removed += removed
            all_renamed += sorted(renamed)
            module = []
        module.append(line)
    fixed, removed, renamed = fix_module(module)
    result += fixed
    total_removed += removed
    all_renamed += sorted(renamed)
    path.write_text('\n'.join(result).rstrip('\n') + '\n')
    print(f'{path.name}: removed {total_removed} redundant lines, '
          f'renamed instance nets: {", ".join(all_renamed) or "none"}')


if __name__ == '__main__':
    main()
