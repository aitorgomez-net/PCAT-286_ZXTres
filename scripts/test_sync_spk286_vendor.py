#!/usr/bin/env python3
"""Directed synchronization checks in private repositories below build/."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

import sync_spk286_vendor as sync

ROOT = Path(__file__).resolve().parents[1]


def command(repo, *arguments):
    result = subprocess.run(['git', '-C', str(repo), *arguments], capture_output=True)
    assert result.returncode == 0, result.stderr.decode(errors='replace')
    return result.stdout


def rejected(action, message):
    try:
        action()
    except ValueError as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError('Unsafe synchronization unexpectedly accepted: ' + message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    out = parser.parse_args().output.resolve()
    assert out.is_relative_to((ROOT / 'build').resolve())
    out.mkdir(parents=True, exist_ok=False)
    upstream, downstream = out / 'upstream', out / 'pcat'
    upstream.mkdir(); downstream.mkdir()
    command(upstream, 'init', '-q')
    command(upstream, 'config', 'core.autocrlf', 'false')
    for name, data in {'rtl/cpu.sv': b'module cpu; endmodule\n',
                       'rtl/timed/profiled.sv': b'upstream old timed wrapper\n',
                       'docs/contract.md': b'# Contract\n'}.items():
        path = upstream / name
        path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
    command(upstream, 'add', '.')
    command(upstream, '-c', 'user.name=Synchronization fixture', '-c', 'user.email=fixture@example.invalid',
            'commit', '-q', '-m', 'Fixture source')
    vendor = downstream / 'vendor/spk286'
    overlay = vendor / 'rtl/timed/profiled.sv'
    overlay.parent.mkdir(parents=True, exist_ok=True); overlay.write_bytes(b'PCAT selected timed wrapper\n')
    extra = vendor / 'rtl/legacy_extra.sv'; extra.write_bytes(b'legacy vendor extra\n')
    untouched = vendor / 'rtl/cpu.sv'; untouched.write_bytes((upstream / 'rtl/cpu.sv').read_bytes())
    timestamp = untouched.stat().st_mtime_ns
    cache = vendor / 'build/ignored.bin'; cache.parent.mkdir(); cache.write_bytes(b'local ignored build output')
    historical = downstream / 'docs/imports/historical.sha256'
    historical.parent.mkdir(parents=True); historical.write_bytes(b'preserve original import\n')
    first = sync.synchronize(upstream, apply=True, root=downstream)
    assert first['imported_files'] == 2 and first['downstream_overlay_files'] == 1
    assert first['retained_vendor_only_files'] == 1
    assert untouched.stat().st_mtime_ns == timestamp, 'Equal portable RTL must not be rewritten'
    assert overlay.read_bytes() == b'PCAT selected timed wrapper\n' and extra.read_bytes() == b'legacy vendor extra\n'
    assert cache.read_bytes() == b'local ignored build output' and historical.read_bytes() == b'preserve original import\n'
    assert not (vendor / '.git').exists()
    assert sync.synchronize(upstream, root=downstream)['status'] == 'SPK286_VENDOR_CHECK_PASS'
    rejected(lambda: sync.synchronize(upstream, apply=True, root=downstream, revision='0' * 40), 'requested revision')
    rejected(lambda: sync.unique_names(['rtl/cpu.sv', 'RTL/CPU.sv']), 'Case-colliding')
    assert sync.is_overlay('RTL/TiMeD/profiled.sv')
    # Every guarded identity is independently checked, including retained files.
    for path, message in ((untouched, 'Imported source is missing or modified'),
                          (overlay, 'downstream_overlay'), (extra, 'retained_vendor_only')):
        data = path.read_bytes(); path.write_bytes(data + b'mutated\n')
        rejected(lambda: sync.synchronize(upstream, root=downstream), message)
        path.write_bytes(data)
    rogue = vendor / 'rtl/unknown.sv'; rogue.write_bytes(b'unrecorded extra\n')
    rejected(lambda: sync.synchronize(upstream, root=downstream), 'retained_vendor_only'); rogue.unlink()
    contract = upstream / 'docs/contract.md'; data = contract.read_bytes(); contract.write_bytes(data + b'dirty\n')
    rejected(lambda: sync.synchronize(upstream, apply=True, root=downstream), 'Upstream must be clean')
    contract.write_bytes(data)
    untracked = upstream / 'untracked.md'; untracked.write_bytes(b'untracked')
    rejected(lambda: sync.synchronize(upstream, apply=True, root=downstream), 'Upstream must be clean'); untracked.unlink()
    rejected(lambda: sync.synchronize(downstream, apply=True, root=downstream), 'must be separate')
    for name in ('../escape', '/absolute', 'C:/absolute', 'rtl/../../escape', 'rtl\\escape',
                 '.git/config', '.cache/data', 'build/temp', 'rtl//noncanonical'):
        rejected(lambda name=name: sync.safe_name(name), 'path')
    # A concurrent source commit is detected at the post-copy HEAD check.
    ordinary_git = sync.git
    changed = False
    def racing_git(source, *arguments, **kwargs):
        nonlocal changed
        if arguments == ('cat-file', '--batch') and not changed:
            result = ordinary_git(source, *arguments, **kwargs)
            command(upstream, '-c', 'user.name=Synchronization fixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '-q', '--allow-empty', '-m', 'Concurrent source commit')
            changed = True
            return result
        return ordinary_git(source, *arguments, **kwargs)
    sync.git = racing_git
    rejected(lambda: sync.synchronize(upstream, apply=True, root=downstream), 'Upstream HEAD or working tree changed')
    sync.git = ordinary_git
    rejected(lambda: sync.synchronize(upstream, root=downstream), 'upstream_head')
    sync.synchronize(upstream, apply=True, root=downstream)
    assert sync.synchronize(upstream, root=downstream)['status'] == 'SPK286_VENDOR_CHECK_PASS'
    sources = [ROOT / 'scripts/sync_spk286_vendor.py', Path(__file__).resolve()]
    receipt = {'status': 'SPK286_VENDOR_SYNC_FIXTURE_PASS',
               'sources_sha256': {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
               'checks': ['canonical tracked import', 'unchanged portable RTL not rewritten', 'overlay excluded and unchanged',
                          'vendor-only extras retained', 'cache/history untouched', 'check-mode import/overlay/extra mutations rejected',
                          'dirty and untracked upstream rejected', 'unsafe source/destination names rejected',
                          'wrong requested revision rejected', 'Windows case collisions rejected and overlay prefix case-insensitive',
                          'concurrent upstream HEAD change rejected', 'stale provenance rejected', 'resynchronization check passed'],
               'temporary_scope': out.relative_to(ROOT).as_posix(), 'cleanup': 'Root archives receipt before removing this owned directory'}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n', newline='\n')
    print('SPK286_VENDOR_SYNC_FIXTURE_PASS', flush=True)


if __name__ == '__main__':
    main()
