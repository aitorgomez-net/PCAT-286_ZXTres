#!/usr/bin/env python3
"""Prove the actual descriptor-selector cone after nested REP localization."""
import argparse
import hashlib
import json
from pathlib import Path
import re

from p06_repeat_local import generate, repeat_excluded_permission_guard
from test_p06_repeat_local_equivalence import prove

ROOT = Path(__file__).resolve().parents[1]
ADDITIONAL = {
    'begin_return_cursor', 'call_gate_cs_validation_operation',
    'operand_request', 'operation_done',
}
SELECTOR_CONE = (
    'jmp_gate_cs_validation_operation', 'cs_validation_operation',
    'call_gate_validation_operation', 'call_gate_cs_validation_operation',
    'iret_cs_validation_operation', 'iret_ss_validation_operation',
    'call_ss_validation_operation', 'descriptor_selector_value',
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def statements(source):
    return {m[1]: m[0] for m in re.finditer(
        r'^    assign (\w+)\s*=\s*(.*?);', source, re.M | re.S)}


def rename(statement, names, prefix, constants):
    statement = re.sub(r'spk286_microcode_pkg::(MC_\w+)',
                       lambda match: f"8'd{constants[match[1]]}", statement)
    for name in sorted(names, key=len, reverse=True):
        statement = re.sub(r'\b' + name + r'\b', prefix + name, statement)
    return statement


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    out = parser.parse_args().output.resolve()
    assert out.is_relative_to((ROOT / 'build').resolve())
    out.mkdir(parents=True, exist_ok=False)
    raw_path = ROOT / 'vendor/spk286/rtl/spk286_micro_executor.sv'
    package_path = ROOT / 'vendor/spk286/microcode/generated/spk286_microcode_pkg.sv'
    candidate, contract = generate(raw_path.read_text(), package_path.read_text())
    legacy = candidate
    changed = {change['signal']: change for change in contract['changes']}
    assert len(changed) == 137
    assert ADDITIONAL <= changed.keys()
    # Restore exactly the four nested branches omitted by the prior leading-
    # conjunction generator. Every other source byte and localized predicate
    # is the same in both formal sides.
    for name in sorted(ADDITIONAL):
        change = changed[name]
        assert legacy.count(change['replacement_statement']) == 1
        legacy = legacy.replace(change['replacement_statement'], change['original_statement'], 1)
    old = statements(legacy)
    new = statements(candidate)
    constants = contract['constants']
    words = contract['repeat_words']
    permission = f'''
    wire allowed = raw_allowed && permission;
    wire implementation_allowed = raw_allowed;
    always @* assume(operation == 8'd{words[0]} || operation == 8'd{words[1]} || permission);
'''
    header = '''module miter (
    input [7:0] operation,
    input raw_allowed, permission,
    input [15:0] protected_msw,
    input call_gate_candidate_valid_q, event_gate_candidate_valid_q,
    input task_gate_target_active_q,
    input [15:0] task_gate_target_selector_q, tmp1_q, iret_outer_ss_q,
    input [15:0] call_stack_ss_q, tmp0_q
);
'''
    declarations = '\n'.join(
        f'    wire {"[15:0] " if name == "descriptor_selector_value" else ""}{prefix}{name};'
        for prefix in ('legacy_', 'candidate_') for name in SELECTOR_CONE)
    bodies = '\n'.join(rename(side[name], SELECTOR_CONE, prefix, constants)
                       for side, prefix in ((old, 'legacy_'), (new, 'candidate_'))
                       for name in SELECTOR_CONE)
    assertions = '\n'.join(f'        assert(legacy_{name} == candidate_{name});'
                           for name in SELECTOR_CONE)
    selector = header + permission + declarations + '\n' + bodies + '\n    always @* begin\n' + assertions + '\n    end\nendmodule\n'
    prove(out, 'actual-descriptor-selector-cone', selector)
    mutant_fragment = rename(new['call_gate_cs_validation_operation'], SELECTOR_CONE, 'candidate_', constants)
    mutant_fragment = mutant_fragment.replace(
        f"operation == 8'd{constants['MC_VALIDATE_CALL_CS']}", "1'b1")
    mutant = selector.replace(rename(new['call_gate_cs_validation_operation'], SELECTOR_CONE, 'candidate_', constants), mutant_fragment)
    assert mutant != selector
    prove(out, 'unsafe-descriptor-opcode-bypass', mutant, reject=True)
    cursor = '''module miter (
    input [7:0] operation,
    input raw_allowed, permission,
    input [15:0] protected_msw, architectural_flags,
    input check_pop2, segment_pop_opcode, pop_operation,
    input stack_cursor_valid_q, stack_write_sp
);
''' + permission + '''
    wire legacy_begin_return_cursor, candidate_begin_return_cursor;
    wire legacy_stack_arch_write, candidate_stack_arch_write;
''' + '\n'.join(rename(side[name], ('begin_return_cursor', 'stack_arch_write'), prefix, constants)
                for side, prefix in ((old, 'legacy_'), (new, 'candidate_'))
                for name in ('begin_return_cursor', 'stack_arch_write')) + '''
    always @* begin
        assert(legacy_begin_return_cursor == candidate_begin_return_cursor);
        assert(legacy_stack_arch_write == candidate_stack_arch_write);
    end
endmodule
'''
    prove(out, 'actual-return-cursor-cone', cursor)
    mutant_fragment = rename(new['begin_return_cursor'], ('begin_return_cursor', 'stack_arch_write'), 'candidate_', constants)
    mutant_fragment = mutant_fragment.replace(
        f"operation == 8'd{constants['MC_TASK_RETURN']}", "1'b1")
    mutant = cursor.replace(rename(new['begin_return_cursor'], ('begin_return_cursor', 'stack_arch_write'), 'candidate_', constants), mutant_fragment)
    assert mutant != cursor
    prove(out, 'unsafe-return-cursor-opcode-bypass', mutant, reject=True)
    # Synthetic parsing controls exercise signs, ternaries, OR branches and
    # arbitrary state predicates independently of production spellings.
    controls = {
        'allowed && state': False,
        '!allowed && operation == spk286_microcode_pkg::MC_VALIDATE_CALL_CS': False,
        'allowed ? (operation == spk286_microcode_pkg::MC_VALIDATE_CALL_CS) : state': False,
        'allowed && operation == spk286_microcode_pkg::MC_BRANCH_REPEAT_EMPTY': False,
        'state || (allowed && operation == spk286_microcode_pkg::MC_VALIDATE_CALL_CS)': True,
        'state && (allowed && operation == spk286_microcode_pkg::MC_TASK_RETURN)': True,
        '!(allowed && operation == spk286_microcode_pkg::MC_TASK_RETURN)': False,
    }
    for expression, accepted in controls.items():
        assert (repeat_excluded_permission_guard(expression, {}, constants, words) is not None) == accepted
    inputs = [Path(__file__), ROOT / 'scripts/p06_repeat_local.py',
              ROOT / 'scripts/test_p06_repeat_local_equivalence.py', raw_path, package_path]
    receipt = {
        'status': 'REPEAT_NESTED_BRANCH_EQUIVALENCE_PASS',
        'additional_assignments': sorted(ADDITIONAL),
        'total_localized_assignments': len(changed),
        'scope': 'Actual selector qualifier assignments and complete 16-bit selector mux equal for every opcode and arbitrary state/data; actual return cursor and SP write gating equal; no lifecycle assumptions',
        'permission_contract': 'Raw/legacy permission equal except the two REP branch words, as independently proved by test_p06_repeat_local_equivalence.py',
        'negative_controls': ['Descriptor opcode bypass rejected', 'Return cursor opcode bypass rejected'],
        'parser_controls': len(controls),
        'candidate_executor_body_sha256': hashlib.sha256(candidate.encode()).hexdigest(),
        'sources_sha256': {p.relative_to(ROOT).as_posix(): sha(p) for p in inputs},
        'artifacts_sha256': {p.name: sha(p) for p in out.iterdir() if p.is_file()},
    }
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n', newline='\n')
    print('REPEAT_NESTED_BRANCH_EQUIVALENCE_PASS', len(changed), len(controls), flush=True)


if __name__ == '__main__':
    main()
