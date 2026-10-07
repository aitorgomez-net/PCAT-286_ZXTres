#!/usr/bin/env python3
"""Source-bound dual-simulator checks and generic encoding-preview cost.

Compile the current preview boundary and its independent encoding testbench.
Generic Yosys cells are not Cyclone V ALMs or a Quartus timing/fit result.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'vendor/spk286'
SOURCES = [
    'vendor/spk286/microcode/generated/spk286_microcode_pkg.sv',
    'vendor/spk286/rtl/spk286_decoder.sv',
    'vendor/spk286/rtl/spk286_control_decode.sv',
    'vendor/spk286/rtl/spk286_modrm.sv',
    'vendor/spk286/rtl/spk286_instruction_context.sv',
    'vendor/spk286/rtl/spk286_encoding_preview.sv',
    'vendor/spk286/sim/unit/spk286_encoding_preview_tb.sv',
    'rtl/spk286_timing/spk286_target_replay.sv',
    'vendor/spk286/tools/microcode/compile_microcode.py',
    'vendor/spk286/microcode/generated/spk286_microcode_validation.json',
    'vendor/spk286/tests/test_instruction_syntax.py',
    'scripts/test_spk286_encoding_preview.py',
]


def run(command, log, cwd=ROOT):
    result = subprocess.run(list(map(str, command)), cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f'command failed ({result.returncode}): {command}; see {log}')
    return result.stdout


COST_WRAPPER = '''`timescale 1ns/1ps
module spk286_preview_cost #(parameter bit HISTORICAL = 1'b1) (
    input logic clk, reset, cancel, start, enable, byte_valid, abort_fetch, consume,
    input logic [7:0] byte_data,
    output logic byte_ready, complete, valid_length, invalid_opcode, unsupported,
    output logic overlength, fetch_fault, replay_valid,
    output logic [3:0] length, replay_count,
    output logic [7:0] replay_data
);
    generate if (HISTORICAL) begin : historical
        spk286_encoding_preview preview (.clk(clk), .reset(reset), .cancel(cancel),
            .start(start), .enable(enable), .byte_valid(byte_valid), .byte_data(byte_data),
            .abort_fetch(abort_fetch), .byte_ready(byte_ready), .complete(complete),
            .valid_length(valid_length), .invalid_opcode(invalid_opcode), .unsupported(unsupported),
            .overlength(overlength), .fetch_fault(fetch_fault), .length(length));
        spk286_target_replay replay (.clk(clk), .reset(reset), .cancel(cancel), .start(start),
            .capture(byte_ready && byte_valid), .capture_data(byte_data), .consume(consume),
            .valid(replay_valid), .data(replay_data), .count(replay_count));
    end else begin : max_disabled
        assign {byte_ready, complete, valid_length, invalid_opcode, unsupported,
                overlength, fetch_fault, replay_valid, length, replay_count, replay_data} = '0;
    end endgenerate
endmodule
'''


def cost(inputs, output, label, top, parameter=None):
    script = 'read_verilog -sv ' + ' '.join(map(str, inputs)) + '; '
    if parameter is not None:
        script += f'chparam -set HISTORICAL {parameter} {top}; '
    script += f'synth -flatten -top {top}; check -assert; stat; write_json {output / (label + ".json")}'
    run(['yosys', '-Q', '-p', script], output / (label + '.log'))
    module = json.loads((output / (label + '.json')).read_text())['modules'][top]
    cells = module['cells']
    registers = sum(len(value['connections']['Q']) for value in cells.values()
                    if 'DFF' in value['type'].upper())
    return {'generic_cells': len(cells), 'register_bits': registers,
            'cell_types': {kind: sum(value['type'] == kind for value in cells.values())
                           for kind in sorted({value['type'] for value in cells.values()})}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    frozen = output / 'sources'
    frozen.mkdir(exist_ok=True)
    manifest = {}
    for name in SOURCES:
        data = (ROOT / name).read_bytes()
        target = frozen / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        manifest[name] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    rtl = [frozen / name for name in SOURCES[:6]]
    bench = frozen / SOURCES[6]
    run(['verilator', '--lint-only', '--Wall', '--top-module', 'spk286_encoding_preview', *rtl],
        output / 'preview-lint.log')
    tests = [('preview', 'spk286_encoding_preview_tb', [*rtl, bench], 'ENCODING PREVIEW PASS')]
    results = []
    for label, top, inputs, marker in tests:
        run(['iverilog', '-g2012', '-s', top, '-o', output / (label + '.vvp'), *inputs],
            output / (label + '-iverilog-build.log'))
        run(['verilator', '--binary', '--timing', '--assert', '--top-module', top,
             '--Mdir', output / (label + '-obj'), '-o', label, *inputs],
            output / (label + '-verilator-build.log'))
        for simulator, command in [('iverilog', ['vvp', output / (label + '.vvp')]),
                                   ('verilator', [output / (label + '-obj') / label])]:
            stdout = run(command, output / (label + '-' + simulator + '-run.log'))
            lines = [line for line in stdout.splitlines() if marker in line]
            if len(lines) != 1:
                raise AssertionError(f'expected exactly one PASS marker for {label}/{simulator}')
            results.append({'label': label, 'simulator': simulator, 'pass': lines[0]})
    wrapper = output / 'spk286_preview_cost.sv'
    wrapper.write_text(COST_WRAPPER)
    costs = {'preview': cost(rtl, output, 'cost-preview', 'spk286_encoding_preview')}
    combined = [*rtl, frozen / SOURCES[7], wrapper]
    costs['preview_and_replay'] = cost(combined, output, 'cost-historical', 'spk286_preview_cost')
    costs['max_disabled'] = cost(combined, output, 'cost-max-disabled', 'spk286_preview_cost', 0)
    for name, record in manifest.items():
        if not name.startswith('baseline:') and hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != record['sha256']:
            raise AssertionError(f'source changed during proof: {name}')
    receipt = {'schema_version': 1, 'status': 'PASS',
               'source_manifest': manifest, 'results': results, 'generic_synthesis': costs,
               'limits': ['Syntactic qualification does not certify semantic validity or execute bytes.',
                          'MAX-disabled0 is a constant disabled wrapper, not dynamically selected whole-core fit cost.',
                          'Generic Yosys cells are not Cyclone V ALMs.']}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'status': 'PASS', 'results': results, 'generic_synthesis': costs}, indent=2))


if __name__ == '__main__':
    main()
