#!/usr/bin/env python3
"""Directed live speed qualification: rational clock, actual CPU/AT bridge.

No complete regression, Quartus or hardware qualification is implied.
All temporary files are owned by the fresh output directory under build.
"""
import argparse
import json
from pathlib import Path
import subprocess

from build_p06_profile_cpu import build
from check_p06_profile_components import select
from run_p06_pilot import generic_stats
from test_spk286_at_cpu_profile import sha, run, ROOT, RTL

CLOCK_TB = ROOT / 'sim/spk286_integration/spk286_at_cpu_profile_live_tb.sv'
CPU_TB = ROOT / 'sim/spk286_timing/spk286_profile_live_integration_tb.sv'
BRIDGE = ROOT / 'rtl/spk286_integration/spk286_at_bus_bridge.sv'


def compile_icarus(out, label, top, sources, define=None):
    binary = out / (label + '.vvp')
    run(['iverilog', '-g2012', '-s', top,
         '-I' + str(out / 'include'),
         '-I' + str(ROOT / 'vendor/spk286/rtl'),
         '-I' + str(ROOT / 'vendor/spk286/sim/unit'),
         *(['-D' + define] if define else []), '-o', binary, *sources],
        out / (label + '-build.log'), timeout=600)
    return binary


def execute(out, label, command, marker, reject=False):
    result = run(command, out / (label + '-run.log'), timeout=600, check=not reject)
    if reject:
        assert result.returncode != 0 and marker in result.stdout, label
        return {'returncode': result.returncode, 'rejected_by': marker}
    found = [line for line in result.stdout.splitlines() if line.startswith(marker)]
    assert len(found) == 1, label
    return {'pass': found[0], 'results': [line for line in result.stdout.splitlines()
                                       if line.startswith('LIVE_RESULT,')]}


def dual(out, label, top, paths, marker):
    binary = compile_icarus(out, label, top, paths)
    first = execute(out, label + '-icarus', ['vvp', binary], marker)
    print(first['pass'] + ' Icarus', flush=True)
    obj = out / (label + '-obj')
    run(['verilator', '--binary', '--timing', '--assert', '-CFLAGS', '-O0', '-j', '4',
         '--top-module', top, '--Mdir', obj, '-o', 'test',
         '-I' + str(out / 'include'),
         '-I' + str(ROOT / 'vendor/spk286/rtl'),
         '-I' + str(ROOT / 'vendor/spk286/sim/unit'), *paths],
        out / (label + '-verilator-build.log'), timeout=1200)
    second = execute(out, label + '-verilator', [obj / 'test'], marker)
    assert first == second, f'{label}: complete dual-simulator result stream differs'
    print(second['pass'] + ' Verilator', flush=True)
    return first


def cost(out, label, source):
    net, script = out / (label + '.json'), out / (label + '.ys')
    script.write_text(f'read_verilog -sv {source}\nsynth -top spk286_at_cpu_profile -flatten\nwrite_json {net}\n')
    run(['yosys', '-Q', '-s', script], out / (label + '.log'))
    return generic_stats(net)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cpu-only', action='store_true', help='Debug only; no acceptance receipt')
    args = parser.parse_args()
    out = args.output.resolve()
    assert out.is_relative_to((ROOT / 'build').resolve())
    out.mkdir(parents=True, exist_ok=False)
    header = ROOT / 'vendor/spk286/sim/unit/spk286_signals.svh'
    adapted = header.read_text()
    for original, replacement in [("ready = 1'b0, execute_enable", 'ready, execute_enable'),
                                  ("logic [15:0] data_in = 16'h0000;", 'logic [15:0] data_in;')]:
        assert adapted.count(original) == 1
        adapted = adapted.replace(original, replacement)
    (out / 'include').mkdir()
    (out / 'include/spk286_signals.svh').write_text(adapted)
    selected = build(out / 'generated')
    cpu_paths = select(selected) + [RTL, BRIDGE, CPU_TB]
    inputs = list(dict.fromkeys([*cpu_paths, CLOCK_TB, header, Path(__file__),
        ROOT / 'scripts/build_p06_profile_cpu.py',
        ROOT / 'rtl/spk286_integration/spk286_at_machine.sv',
        ROOT / 'rtl/spk286_integration/spk286_machine_cpu.sv', ROOT / 'PCAT-286.sv']))
    before = {p.relative_to(ROOT).as_posix(): sha(p) for p in inputs}
    top = 'spk286_profile_live_integration_tb'
    marker = 'PROFILE_LIVE_CPU_BRIDGE_PASS'
    if args.cpu_only:
        binary = compile_icarus(out, 'cpu', top, cpu_paths)
        print(execute(out, 'cpu-icarus', ['vvp', binary], marker)['pass'], flush=True)
        return
    clock = dual(out, 'clock', 'spk286_at_cpu_profile_live_tb', [RTL, CLOCK_TB], 'PROFILE_LIVE_CLOCK_PASS')
    four = compile_icarus(out, 'clock-four-state', 'spk286_at_cpu_profile_live_tb',
                         [RTL, CLOCK_TB], 'PROFILE_LIVE_FOUR_STATE')
    execute(out, 'clock-four-state', ['vvp', four], 'PROFILE_LIVE_FOUR_STATE_PASS')
    cpu = dual(out, 'cpu', top, cpu_paths, marker)
    assert len(cpu['results']) == 192
    matrix = [list(map(int, line.split(',')[1:5])) for line in cpu['results']]
    assert matrix == [[i*24+j*3+k+1, i, j, k] for i in range(8) for j in range(8) for k in range(3)]
    negatives = {}
    current = selected['spk286_profiled.sv']
    text = current.read_text()
    anchor = '.cancel(stream_restart),\n        .start(profile_target_preview_start)'
    assert text.count(anchor) == 1
    mutant = out / 'negative-replay.sv'
    mutant.write_text(text.replace(anchor, '.cancel(!historical_enable || stream_restart),\n        .start(profile_target_preview_start)'))
    binary = compile_icarus(out, 'negative-replay', top,
                           [mutant if p == current else p for p in cpu_paths])
    negatives['discard-preview-on-max'] = execute(out, 'negative-replay', ['vvp', binary],
        'replayed target instruction executes once with CS override', reject=True)
    bench = CPU_TB.read_text()
    anchor = 'wire profile_apply = profile_change_ready && bridge_idle && !memory_drain_pending;'
    assert bench.count(anchor) == 1
    mutant = out / 'negative-boundary.sv'
    mutant.write_text(bench.replace(anchor, 'wire profile_apply = profile_pending && bridge_idle && !memory_drain_pending;'))
    binary = compile_icarus(out, 'negative-boundary', top,
                           [mutant if p == CPU_TB else p for p in cpu_paths])
    negatives['unsafe-mid-instruction-apply'] = execute(out, 'negative-boundary', ['vvp', binary],
        'changed mode requires complete CPU context boundary', reject=True)
    old = out / 'reset-only-selector.sv'
    old.write_bytes(subprocess.check_output(['git', 'show', '0d8e6c7:rtl/spk286_integration/spk286_at_cpu_profile.sv'], cwd=ROOT))
    costs = {'reset_only': cost(out, 'reset-only-cost', old), 'live': cost(out, 'live-cost', RTL)}
    assert costs['live']['register_bits'] == costs['reset_only']['register_bits'] == 10
    machine = (ROOT / 'rtl/spk286_integration/spk286_at_machine.sv').read_text()
    assert '.apply(timing_profile_change_ready && bridge_idle &&\n               !(memory_drain_pending === 1\'b1))' in machine
    assert '.profile_change_pending (cpu_speed_pending)' in machine
    after = {p.relative_to(ROOT).as_posix(): sha(p) for p in inputs}
    assert before == after, 'source changed during directed qualification'
    receipt = {'status': 'PASS', 'scope': 'Directed live speed, rational clock and actual CPU/bridge; full regression deferred; physical fit and MiSTer separate',
        'sources_sha256': before, 'clock': clock, 'cpu_bridge': cpu, 'negative': negatives,
        'isolated_selector_cost': costs,
        'coverage': {'profile_pairs': 64, 'phase_offsets': 100, 'cpu_bridge_cases': 192,
                     'backend_latencies': [0, 7, 20], 'replayed_target_cases': 49,
                     'bus_wait_hold_cases': 64, 'hlt_irq_nmi_drain_cases': 64}}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('P06_LIVE_SPEED_DIRECTED_PASS', flush=True)


if __name__ == '__main__':
    main()
