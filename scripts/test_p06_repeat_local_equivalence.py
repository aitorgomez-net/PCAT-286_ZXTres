#!/usr/bin/env python3
"""Prove every opcode-local strobe and audit the exact generated source delta."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from build_p06_profile_cpu import CONNECTION, build
from p06_repeat_local import generate, rep_decoder_fragments, REP_ZERO_ATOMS

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prove(out, label, source, reject=False):
    rtl = out / (label + '.sv')
    rtl.write_text(source, newline='\n')
    script = out / (label + '.ys')
    script.write_text(f'read_verilog -formal -sv {rtl}\nprep -top miter -flatten\nopt\n'
                      'sat -verify -prove-asserts -set-assumes -timeout 60\n', newline='\n')
    result = subprocess.run(['yosys', '-Q', '-s', script], cwd=ROOT,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    log = result.stdout.decode()
    (out / (label + '.log')).write_bytes(result.stdout)
    if reject:
        assert result.returncode and 'proof did fail' in log and 'time out' not in log
    else:
        assert result.returncode == 0 and 'SAT proof finished - no model found: SUCCESS!' in log


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    out = parser.parse_args().output.resolve()
    assert out.is_relative_to((ROOT / 'build').resolve())
    out.mkdir(parents=True, exist_ok=False)
    selected = build(out / 'generated')
    raw_path = ROOT / 'vendor/spk286/rtl/spk286_micro_executor.sv'
    pkg_path = ROOT / 'vendor/spk286/microcode/generated/spk286_microcode_pkg.sv'
    source = raw_path.read_text()
    clone, contract = generate(source, pkg_path.read_text())
    # Independently undo the declared edits. Every remaining source byte must
    # match production, including every state update and subservice enable.
    recovered = clone.replace('module spk286_profiled_micro_executor #(', 'module spk286_micro_executor #(', 1)
    recovered = recovered.replace('\n    input  logic implementation_operation_valid,', '', 1)
    alias = '\n    logic implementation_allowed;\n    assign implementation_allowed = implementation_operation_valid && !reset && !cancel && !start &&\n                     !task_switch_skip && !task_return_skip && !task_event_switch_skip;'
    assert recovered.count(alias) == 1
    recovered = recovered.replace(alias, '', 1)
    for change in contract['changes']:
        assert recovered.count(change['replacement_statement']) == 1
        recovered = recovered.replace(change['replacement_statement'], change['original_statement'], 1)
    assert recovered == source
    assert clone.count('.enable(operation_valid)') == source.count('.enable(operation_valid)') == 3
    assert source.count('assign register_complete = allowed') == clone.count('assign register_complete = implementation_allowed') == 1
    words = contract['repeat_words']
    constants = '\n'.join(line.replace('spk286_microcode_pkg::', '') for line in pkg_path.read_text().splitlines() if 'localparam' in line)
    actual = CONNECTION[CONNECTION.index('    assign profile_repeat_more'):CONNECTION.index('    assign operation_valid')]
    actual = actual.replace('spk286_microcode_pkg::', '')
    permission = '''module miter (
    input historical_enable, cpu_boundary, profile_deadline_ready,
    input profile_raw_operation_valid, string_compare,
    input [7:0] micro_word, input [1:0] repeat_kind,
    input [127:0] register_state, input [15:0] debug_flags
);
    wire profile_repeat_more, profile_repeat_empty, profile_repeat_continue, profile_repeat_permit;
''' + constants + '\n' + actual + f'''
    always @* if (micro_word != 8'd{words[0]} && micro_word != 8'd{words[1]})
        assert(profile_repeat_permit);
endmodule
'''
    prove(out, 'actual-permission', permission)
    decoder = '''module miter(input [7:0] operation);
    logic immediate_operation, immediate_alu, immediate_byte, immediate_rm, immediate_word, immediate_signed;
    logic register_decode, register_alu, register_byte, register_destination_rm, unary_register, unary_direct;
''' + constants + '\n' + rep_decoder_fragments(source).replace('spk286_microcode_pkg::', '') + '''
    always @* if(operation==MC_BRANCH_REPEAT_EMPTY || operation==MC_BRANCH_REPEAT_CONTINUE)
        assert(!immediate_operation && !register_decode && !unary_direct);
endmodule
'''
    prove(out, 'actual-procedural-decoder', decoder)
    unsafe_decoder = decoder.replace("default: immediate_operation = 1'b0;", "default: immediate_operation = 1'b1;")
    assert unsafe_decoder != decoder
    prove(out, 'unsafe-procedural-default', unsafe_decoder, reject=True)
    atoms = {}

    def emit(tree):
        kind = tree[0]
        if kind == 'permission':
            return 'legacy_allowed' if tree[1] == 'allowed' else 'raw_allowed'
        if kind == 'compare':
            return f"(operation {tree[1]} 8'd{tree[2]})"
        if kind == 'constant':
            return "1'b1" if tree[1] else "1'b0"
        if kind in ('context', 'rep_zero'):
            if tree[1] not in atoms:
                atoms[tree[1]] = len(atoms)
            atom = f'context_bits[{atoms[tree[1]]}]'
            if kind == 'rep_zero':
                assert tree[1] in REP_ZERO_ATOMS
                return f"({atom} && operation != 8'd{words[0]} && operation != 8'd{words[1]})"
            return atom
        if kind == 'not':
            return '!(' + emit(tree[1]) + ')'
        token = ' && ' if kind == 'and' else ' || '
        return '(' + token.join(emit(child) for child in tree[1]) + ')'

    assertions = '\n'.join(f"        assert({emit(change['original_model'])} == {emit(change['replacement_model'])}); // {change['signal']}"
                           for change in contract['changes'])
    model = f'''module miter (
    input [7:0] operation, input raw_allowed, permission,
    input [{len(atoms)-1}:0] context_bits
);
    wire legacy_allowed = raw_allowed && permission;
    always @* begin
        assume(operation == 8'd{words[0]} || operation == 8'd{words[1]} || permission);
{assertions}
    end
endmodule
'''
    prove(out, 'all-opcode-local-strobes', model)
    mutant = model.replace(assertions.splitlines()[0], '        assert(legacy_allowed == raw_allowed);', 1)
    prove(out, 'unsafe-global-bypass', mutant, reject=True)
    (out / 'context-atoms.json').write_text(json.dumps(atoms, indent=2) + '\n', newline='\n')
    inputs = [Path(__file__), ROOT/'scripts/p06_repeat_local.py', ROOT/'scripts/build_p06_profile_cpu.py', raw_path, pkg_path]
    receipt = {'status': 'REPEAT_LOCAL_STROBES_EQUIVALENCE_PASS', 'changed_strobes': len(contract['changes']),
               'scope': 'Actual permit formula proves raw/legacy equality outside two REP words; actual procedural decoder separately proves three guard predicates zero in REP words; every changed strobe equal for all other arbitrary context/state; source delta audited byte for byte',
               'negative_control': 'Unsafe global bypass and incorrect procedural default rejected with counterexamples',
               'unchanged': 'All state update expressions, REP strobes and three subservice enables',
               'sources_sha256': {p.relative_to(ROOT).as_posix(): sha(p) for p in inputs},
               'generated_sha256': {name: sha(path) for name,path in selected.items()},
               'context_atom_count': len(atoms), 'no_lifecycle_assumptions': True,
               'procedural_rep_zero': contract['procedural_rep_zero'],
               'contract_sha256': sha(out/'generated/repeat-local-contract.json'),
               'artifacts_sha256': {p.name: sha(p) for p in out.iterdir() if p.is_file()}}
    (out/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n', newline='\n')
    print('REPEAT_LOCAL_STROBES_EQUIVALENCE_PASS', len(contract['changes']), len(atoms), flush=True)


if __name__ == '__main__':
    main()
