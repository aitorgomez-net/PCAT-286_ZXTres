#!/usr/bin/env python3
"""Source-bound dual-simulator checks and generic encoding-preview cost.

Compile only the small preview boundary. Freeze the two default-mode functional
decoders from the specified commit as independent comparison controls. Generic
Yosys cells are not Cyclone V ALMs or a Quartus timing/fit result.
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


def decoder_bench():
    decoder = {'supported': 1, 'invalid_opcode': 1, 'destination': 3,
               'source_index': 3, 'entry': 'WIDTH'}
    control = {'push_enabled': 1, 'push_return_ip': 1, 'branch_taken': 1,
               'decrement_count': 1, 'form_supported': 1, 'dispatch_entry': 'WIDTH',
               'adjust_kind': 3, 'muldiv_kind': 2, 'segment_index': 2,
               'string_byte': 1, 'string_compare': 1, 'dispatch_valid': 1}
    text = '''`timescale 1ns/1ps
module spk286_syntax_equivalence_tb;
    localparam integer WIDTH = spk286_microcode_pkg::MC_ADDR_WIDTH;
    logic [7:0] opcode;
    logic extended_opcode, condition_taken, zero;
    logic [2:0] group_extension;
    logic [15:0] count;
    integer checks = 0;
'''
    for family, ports in (('decoder', decoder), ('control_decode', control)):
        inputs = ['opcode', 'extended_opcode']
        if family == 'control_decode':
            inputs += ['condition_taken', 'zero', 'group_extension', 'count']
        for tag in ('gold', 'normal', 'syntax'):
            for port, width in ports.items():
                text += f'    wire [{width}-1:0] {family}_{tag}_{port};\n'
            module = f'spk286_{family}' + ('_baseline' if tag == 'gold' else '')
            parameter = " #(.SYNTAX_ONLY(1'b1))" if tag == 'syntax' else ''
            bindings = [f'.{port}({port})' for port in inputs]
            bindings += [f'.{port}({family}_{tag}_{port})' for port in ports]
            text += f'    {module}{parameter} {family}_{tag} (' + ', '.join(bindings) + ');\n'
        port = 'entry' if family == 'decoder' else 'dispatch_entry'
        text += f'    wire [6:0] {family}_expected_shape = spk286_microcode_pkg::micro_instruction_syntax({family}_gold_{port});\n'
        text += f"    wire [WIDTH-1:0] {family}_expected_entry = {{{{(WIDTH-7){{1'b0}}}}, {family}_expected_shape}};\n"
    text += '''    initial begin
        for (integer op = 0; op < 512; op = op + 1) begin
            opcode = 8'(op); extended_opcode = op >= 256;
            for (integer group_id = 0; group_id < 8; group_id = group_id + 1) begin
                group_extension = 3'(group_id);
                for (integer flags_id = 0; flags_id < 4; flags_id = flags_id + 1) begin
                    condition_taken = flags_id[0]; zero = flags_id[1];
                    for (integer count_id = 0; count_id < 3; count_id = count_id + 1) begin
                        count = count_id == 0 ? 16'd0 : count_id == 1 ? 16'd1 : 16'hFFFF;
                        #1;
'''
    for family, ports in (('decoder', decoder), ('control_decode', control)):
        for port in ports:
            text += (f'                        if ({family}_normal_{port} !== {family}_gold_{port}) '
                     f'$fatal(1, "default functional {family}.{port} differs op%h group%0d", opcode, group_id);\n')
            if port not in ('entry', 'dispatch_entry'):
                text += (f'                        if ({family}_syntax_{port} !== {family}_gold_{port}) '
                         f'$fatal(1, "syntax functional {family}.{port} differs");\n')
        port = 'entry' if family == 'decoder' else 'dispatch_entry'
        condition = "1'b1" if family == 'decoder' else 'control_decode_gold_dispatch_valid'
        text += (f'                        if ({condition} && {family}_syntax_{port} !== '
                 f'{family}_expected_entry) '
                 f'$fatal(1, "syntax leaf {family}.{port} differs");\n')
    text += '''                        checks = checks + 1;
                    end
                end
            end
        end
        $display("SYNTAX DEFAULT EQUIVALENCE PASS checks=%0d", checks);
        $finish;
    end
endmodule
'''
    return text


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
    parser.add_argument('--baseline', default='b155891c215a1a4048e7b531ba4bfcfd8582f0d4')
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
    for name in ('decoder', 'control_decode'):
        path = f'vendor/spk286/rtl/spk286_{name}.sv'
        data = subprocess.check_output(['git', 'show', f'{args.baseline}:{path}'], cwd=ROOT)
        baseline = frozen / f'spk286_{name}_baseline.sv'
        baseline.write_bytes(data.replace(f'module spk286_{name} '.encode(),
                                         f'module spk286_{name}_baseline '.encode(), 1))
        manifest['baseline:' + path] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    rtl = [frozen / name for name in SOURCES[:6]]
    bench = frozen / SOURCES[6]
    run(['verilator', '--lint-only', '--Wall', '--top-module', 'spk286_encoding_preview', *rtl],
        output / 'preview-lint.log')
    equivalence = output / 'spk286_syntax_equivalence_tb.sv'
    equivalence.write_text(decoder_bench())
    tests = [('preview', 'spk286_encoding_preview_tb', [*rtl, bench], 'ENCODING PREVIEW PASS'),
             ('equivalence', 'spk286_syntax_equivalence_tb',
              [*rtl[:3], frozen / 'spk286_decoder_baseline.sv',
               frozen / 'spk286_control_decode_baseline.sv', equivalence],
              'SYNTAX DEFAULT EQUIVALENCE PASS')]
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
    receipt = {'schema_version': 1, 'status': 'PASS', 'baseline': args.baseline,
               'source_manifest': manifest, 'results': results, 'generic_synthesis': costs,
               'limits': ['Syntactic qualification does not certify semantic validity or execute bytes.',
                          'MAX-disabled0 is a constant disabled wrapper, not dynamically selected whole-core fit cost.',
                          'Generic Yosys cells are not Cyclone V ALMs.']}
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'status': 'PASS', 'results': results, 'generic_synthesis': costs}, indent=2))


if __name__ == '__main__':
    main()
