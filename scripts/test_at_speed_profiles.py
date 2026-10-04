#!/usr/bin/env python3
"""Run the real composed AT diagnostic boundary in every reset-applied profile.

The existing ROM checks its own architectural/device results. This is focused
functional integration coverage, not a benchmark, full OS boot or regression.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    output = a.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    names = set(re.findall(r'SYSTEMVERILOG_FILE "([^"]+)"',
                          (ROOT/'rtl/spk286_integration/spk286_integration.qip').read_text()))
    names |= {p.relative_to(ROOT).as_posix() for directory in ('rtl', 'sys')
              for p in (ROOT/directory).rglob('*') if p.is_file() and p.suffix in ('.sv','.v','.svh','.vh','.hex')}
    names |= {'config.tcl', 'PCAT-286.sv', 'rtl/spk286_integration/spk286_integration.qip',
              'scripts/test_at_machine_boundary.sh', 'scripts/test_at_speed_profiles.py',
              'sim/spk286_integration/spk286_at_machine_tb.sv',
              'sim/spk286_integration/spk286_at_machine_pic_model.sv',
              'sim/spk286_integration/dpram_model.sv', 'tests/firmware/pcat286_event_diag.rom',
              'scripts/build_p06_profile_cpu.py'}
    sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
    before = {name:sha(ROOT/name) for name in sorted(names)}
    env = dict(os.environ, PCAT_BUILD_DIR=str(output/'machine'), AT_SYSTEM_MAX_CYCLES='20000000')
    with (output/'compile-and-max.log').open('w') as log:
        subprocess.run(['bash','scripts/test_at_machine_boundary.sh'], cwd=ROOT,
                       env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    executable = output/'machine/verilator-obj/at_machine_vlt'
    measurements = []
    for profile in range(8):
        path = output/f'profile-{profile}.log'
        with path.open('w') as log:
            subprocess.run([str(executable), f'+ROM={ROOT}/tests/firmware/pcat286_event_diag.rom',
                            f'+CPU_PROFILE={profile}', '+MAX_CYCLES=20000000'],
                           cwd=ROOT/'rtl/video', stdout=log, stderr=subprocess.STDOUT,
                           timeout=120, check=True)
        text = path.read_text()
        marker = next(line for line in text.splitlines() if line.startswith('AT_SYSTEM_BOUNDARY_PASS'))
        measurements.append(dict(profile=profile, marker=marker, log_sha256=sha(path)))
        print(f'AT_SPEED_PROFILE_PASS profile={profile} {marker}', flush=True)
    assert before == {name:sha(ROOT/name) for name in sorted(names)}, 'Sources changed during integration validation'
    receipt = dict(status='AT_SPEED_PROFILES_DIRECTED_PASS', source_sha256=before,
                   scope='One production CPU plus AT bridge/arbiter/devices, diagnostic ROM, all 8 profiles. No complete OS/regression/timing-accuracy claim.',
                   results=measurements)
    (output/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(receipt['status'])


if __name__ == '__main__':
    main()
