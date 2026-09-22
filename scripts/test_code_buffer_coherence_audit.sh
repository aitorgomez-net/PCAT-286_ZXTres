#!/usr/bin/env bash
set -euo pipefail

# Positive regression: the three failures reproduced in the historical audit
# must now be fixed in production, with a successful exit in both simulators.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${CODE_BUFFER_AUDIT_BUILD_DIR:-$ROOT_DIR/build/code-buffer-coherence-fixed}"
mkdir -p "$BUILD_DIR"
export ROOT_DIR BUILD_DIR
ulimit -c 0

python3 - <<'PY'
import hashlib
import json
import os
import subprocess
from pathlib import Path

root = Path(os.environ['ROOT_DIR'])
build = Path(os.environ['BUILD_DIR']).resolve()
rtl = 'rtl/spk286_integration/spk286_at_sdram_read_buffer.sv'
tb = 'sim/spk286_integration/spk286_code_buffer_coherence_audit_tb.sv'
top = 'spk286_code_buffer_coherence_audit_tb'

def artifact(path):
    path = Path(path)
    data = path.read_bytes()
    return {'path': os.path.relpath(path, root).replace(os.sep, '/'),
            'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

def command(args, log):
    result = subprocess.run(args, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_bytes(result.stdout)
    return result.returncode, result.stdout.decode(errors='replace')

def required_command(args, log):
    code, output = command(args, log)
    if code:
        raise SystemExit(f'AUDIT_INFRASTRUCTURE_FAIL exit={code} log={log}\n{output[-3000:]}')
    return output

versions = {}
for simulator, args in [('iverilog', ['iverilog', '-V']), ('verilator', ['verilator', '--version'])]:
    output = required_command(args, build / f'{simulator}-version.log')
    versions[simulator] = output.splitlines()[0]

required_command(['iverilog', '-g2012', '-s', top, '-o', str(build/'audit_iv'), rtl, tb],
                 build/'iverilog-compile.log')
required_command(['verilator', '--binary', '--timing', '--Wno-fatal', '-j', '2',
                  '--top-module', top, '--Mdir', str(build/'verilator'), rtl, tb],
                 build/'verilator-compile.log')

case_names = ['cpu_odd_upper_last_byte', 'cpu_cancel_idle', 'dma_odd_upper_last_byte']
observations = [
    'AUDIT_ODD_UPPER owner=0 backend_word=cc04',
    'AUDIT_IDLE_CANCEL physical_reads_before=4 after=8 hits=0',
    'AUDIT_ODD_UPPER owner=1 backend_word=cc04',
]
results = []
for simulator, executable in [
    ('iverilog', ['vvp', str(build/'audit_iv')]),
    ('verilator', [str(build/'verilator'/('V'+top))]),
]:
    for case in range(3):
        log = build / f'{simulator}-case-{case}.log'
        code, output = command([*executable, f'+CASE={case}'], log)
        lines = output.splitlines()
        assertion_lines = [line for line in lines if line.startswith('COHERENCE_AUDIT_ASSERT ')]
        if (code != 0 or observations[case] not in lines or assertion_lines or
            f'PRODUCTION_AUDIT_PASS case={case}' not in lines):
            raise SystemExit(f'AUDIT_UNEXPECTED_RESULT simulator={simulator} case={case} exit={code} log={log}\n{output}')
        results.append({'case': case_names[case], 'plusargs': f'+CASE={case}',
                        'simulator': simulator, 'exit_code': code,
                        'result': 'PASS', 'observation': observations[case],
                        'log': artifact(log)})
        print(f'COHERENCE_REGRESSION_PASS simulator={simulator} case={case_names[case]}')

receipt = {
    'schema_version': 1,
    'date': '2026-09-22',
    'baseline_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'scope': 'Positive production regression of the three historical coherence/invalidation failures',
    'production_rtl': artifact(root/rtl),
    'production_unchanged_vs_head': subprocess.run(['git', '-c', 'core.safecrlf=false', 'diff', '--quiet', 'HEAD', '--', rtl], cwd=root).returncode == 0,
    'testbench': artifact(root/tb),
    'runner': artifact(root/'scripts/test_code_buffer_coherence_audit.sh'),
    'simulators': versions,
    'compile_logs': [artifact(build/'iverilog-compile.log'), artifact(build/'verilator-compile.log')],
    'results': results,
    'limitations': [
        'Registered-command abstract backend, not SDRAM pin simulation.',
        'IDLE cancellation violates P03-R15; retaining that unchanged data does not demonstrate corruption by itself.',
        'No causal link to Windows startup, no synthesis or hardware validation.'
    ],
}
model = root/'sim/spk286_integration/spk286_at_multiline_code_buffer_model.sv'
if model.exists():
    receipt['experimental_model_snapshot'] = artifact(model)
(build/'receipt.json').write_text(json.dumps(receipt, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')
print('COHERENCE_REGRESSION_PASS cases=6')
PY
