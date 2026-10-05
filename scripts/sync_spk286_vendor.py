#!/usr/bin/env python3
"""Mirror committed portable SPK286 sources while preserving PCAT's overlay.

Only tracked regular blobs from a clean, pinned upstream HEAD are imported.
Canonical Git bytes avoid checkout line-ending differences. Historical import
manifests are immutable; current provenance is recorded separately.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BLOCKED_PARTS = {'.git', '.cache', '__pycache__', 'build', 'obj_dir', 'db', 'incremental_db', 'node_modules'}
OVERLAY = 'rtl/timed/'
PROVENANCE = 'docs/imports/current-spk286.json'
POLICY = ('PCAT owns the complete vendor/spk286/rtl/timed overlay and the root '
          'scripts/build_p06_profile_cpu.py generator. The mirrored CPU-only '
          'vendor/scripts/build_p06_profile_cpu.py has an upstream default '
          'output of rtl/timed: do not invoke it with that default in the vendor '
          'tree. Upstream check_p06_profile_cpu.py checks its standalone installed '
          'variant; use PCAT root profile checks for the downstream overlay.')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(source, *arguments, input_bytes=None):
    result = subprocess.run(['git', '-C', str(source), *arguments], input=input_bytes,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise ValueError('Git failed: ' + result.stderr.decode(errors='replace').strip())
    return result.stdout


def safe_name(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or '\\' in name or ':' in name or any(
            part in ('.', '..') or part.casefold() in BLOCKED_PARTS for part in path.parts):
        raise ValueError('Unsafe or cache source path: ' + name)
    if path.as_posix() != name:
        raise ValueError('Noncanonical source path: ' + name)
    return name


def unique_names(names):
    folded = {}
    for name in names:
        key = name.casefold()
        if key in folded:
            raise ValueError('Case-colliding source paths are unsafe on Windows: ' + folded[key] + ' / ' + name)
        folded[key] = name


def is_overlay(name):
    return name.casefold().startswith(OVERLAY)


def snapshot(source, root):
    source, root = source.resolve(strict=True), root.resolve(strict=True)
    vendor = root / 'vendor/spk286'
    if source == root or source == vendor or source.is_relative_to(vendor) or vendor.is_relative_to(source):
        raise ValueError('Upstream source must be separate from the PCAT/vendor tree')
    top = Path(git(source, 'rev-parse', '--show-toplevel').decode().strip()).resolve(strict=True)
    if top != source:
        raise ValueError('Source must identify the upstream repository root')
    if git(source, 'status', '--porcelain=v1', '-z', '--untracked-files=normal'):
        raise ValueError('Upstream must be clean, including untracked source files')
    head = git(source, 'rev-parse', 'HEAD').decode().strip()
    object_format = git(source, 'rev-parse', '--show-object-format').decode().strip()
    rows = git(source, 'ls-tree', '-r', '-z', head)
    entries = {}
    for row in rows.split(b'\0'):
        if not row:
            continue
        header, raw_name = row.split(b'\t', 1)
        mode, kind, blob = header.decode().split()
        name = safe_name(raw_name.decode())
        if kind != 'blob' or mode not in ('100644', '100755'):
            raise ValueError('Only tracked regular source files are supported: ' + name)
        entries[name] = {'blob': blob, 'mode': mode}
    unique_names(entries)
    # One batch reads exact canonical blobs; no working-tree filters or archive
    # export-ignore attributes can silently omit a tracked file.
    blobs = list(dict.fromkeys(entry['blob'] for entry in entries.values()))
    output = git(source, 'cat-file', '--batch', input_bytes=('\n'.join(blobs) + '\n').encode())
    objects, position = {}, 0
    for expected in blobs:
        newline = output.index(b'\n', position)
        blob, kind, size = output[position:newline].decode().split()
        size = int(size)
        start = newline + 1
        data = output[start:start + size]
        if blob != expected or kind != 'blob' or len(data) != size or output[start + size:start + size + 1] != b'\n':
            raise ValueError('Malformed canonical Git blob batch')
        actual = hashlib.new(object_format, b'blob ' + str(size).encode() + b'\0' + data).hexdigest()
        if actual != blob:
            raise ValueError('Canonical source blob identity failed')
        objects[blob] = data
        position = start + size + 1
    if position != len(output):
        raise ValueError('Trailing canonical Git blob data')
    return source, head, entries, objects


def source_tree(vendor):
    files = {}
    if not vendor.exists():
        return files
    if vendor.is_symlink() or (hasattr(vendor, 'is_junction') and vendor.is_junction()):
        raise ValueError('Vendor source root links are unsupported')
    for current, directories, names in os.walk(vendor, topdown=True, followlinks=False):
        directories[:] = [name for name in directories if name.casefold() not in BLOCKED_PARTS]
        for name in [*directories, *names]:
            path = Path(current) / name
            relative = path.relative_to(vendor)
            if path.is_symlink() or (hasattr(path, 'is_junction') and path.is_junction()):
                raise ValueError('Vendor source links are unsupported: ' + relative.as_posix())
            if path.is_file():
                files[relative.as_posix()] = {'sha256': digest(path.read_bytes()), 'bytes': path.stat().st_size}
    return files


def destination(vendor, name):
    path = vendor / safe_name(name)
    if not path.resolve().is_relative_to(vendor.resolve()):
        raise ValueError('Destination escapes vendor root: ' + name)
    for ancestor in (path, *path.parents):
        if ancestor == vendor.parent:
            break
        if ancestor.is_symlink() or (hasattr(ancestor, 'is_junction') and ancestor.is_junction()):
            raise ValueError('Destination source links are unsupported: ' + name)
    return path


def synchronize(source, *, apply=False, root=ROOT, revision=None):
    source, head, entries, objects = snapshot(Path(source), Path(root))
    if revision is not None and revision != head:
        raise ValueError('Upstream HEAD does not match the requested revision')
    root = Path(root).resolve(strict=True)
    vendor, provenance = root / 'vendor/spk286', root / PROVENANCE
    before = source_tree(vendor)
    imported = {name: entry for name, entry in entries.items() if not is_overlay(name)}
    unique_names(before)
    existing_case = {name.casefold(): name for name in before}
    for name in imported:
        if name.casefold() in existing_case and existing_case[name.casefold()] != name:
            raise ValueError('Existing vendor path case differs from source: ' + name)
    overlay = {name: item for name, item in before.items() if is_overlay(name)}
    extras = {name: item for name, item in before.items() if name not in imported and not is_overlay(name)}
    records = {name: {'git_blob': entry['blob'], 'git_mode': entry['mode'],
                      'sha256': digest(objects[entry['blob']]), 'bytes': len(objects[entry['blob']])}
               for name, entry in sorted(imported.items())}
    excluded = {name: {'git_blob': entry['blob'], 'git_mode': entry['mode']}
                for name, entry in sorted(entries.items()) if is_overlay(name)}
    if apply:
        vendor.mkdir(parents=True, exist_ok=True)
        for name, entry in imported.items():
            path = destination(vendor, name)
            data = objects[entry['blob']]
            if not path.is_file() or path.read_bytes() != data:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
    else:
        if not provenance.is_file():
            raise ValueError('Current SPK286 provenance is missing; run --sync first')
        recorded = json.loads(provenance.read_text())
        for key, expected in (('schema_version', 1), ('upstream_head', head), ('imported', records),
                              ('upstream_excluded', excluded), ('downstream_overlay', overlay), ('retained_vendor_only', extras)):
            if recorded.get(key) != expected:
                raise ValueError('Stale or modified SPK286 provenance: ' + key)
    after = source_tree(vendor)
    for name, record in records.items():
        if after.get(name) != {'sha256': record['sha256'], 'bytes': record['bytes']}:
            raise ValueError('Imported source is missing or modified: ' + name)
    if {name: item for name, item in after.items() if is_overlay(name)} != overlay:
        raise ValueError('Downstream timing overlay changed during synchronization')
    if {name: item for name, item in after.items() if name not in imported and not is_overlay(name)} != extras:
        raise ValueError('Retained vendor-only source changed during synchronization')
    if git(source, 'rev-parse', 'HEAD').decode().strip() != head or git(
            source, 'status', '--porcelain=v1', '-z', '--untracked-files=normal'):
        raise ValueError('Upstream HEAD or working tree changed during synchronization')
    if apply:
        record = {'schema_version': 1, 'upstream_repository': str(source), 'upstream_head': head,
                  'canonical_bytes': 'Git blob bytes, SHA256 plus upstream Git object identity',
                  'imported': records, 'upstream_excluded': excluded,
                  'downstream_overlay': overlay, 'retained_vendor_only': extras,
                  'ownership_policy': POLICY, 'historical_import_manifests': 'Preserved unchanged',
                  'validation': 'All imported bytes verified; overlay/extras unchanged; upstream clean and HEAD pinned before/after'}
        provenance.parent.mkdir(parents=True, exist_ok=True)
        provenance.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n', newline='\n')
    return {'status': 'SPK286_VENDOR_SYNC_PASS' if apply else 'SPK286_VENDOR_CHECK_PASS',
            'upstream_head': head, 'imported_files': len(records),
            'downstream_overlay_files': len(overlay), 'retained_vendor_only_files': len(extras),
            'imported_bytes': sum(record['bytes'] for record in records.values()),
            'upstream_executable_paths': [name for name, record in records.items() if record['git_mode'] == '100755']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--revision', help='Require this exact full upstream HEAD commit identity')
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--sync', action='store_true')
    action.add_argument('--check', action='store_true')
    arguments = parser.parse_args()
    try:
        print(json.dumps(synchronize(arguments.source, apply=arguments.sync, revision=arguments.revision), indent=2))
    except (ValueError, OSError) as error:
        parser.exit(1, 'SPK286_VENDOR_SYNC_FAIL: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
