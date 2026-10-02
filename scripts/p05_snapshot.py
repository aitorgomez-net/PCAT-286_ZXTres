#!/usr/bin/env python3
"""Preserve build inputs, Git state and optionally a fitted Quartus database.

The destination must be new. No build ever writes to the reference snapshot.
Run inside WSL so symlinks and file names match the Quartus container.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--with-fit', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    dest = args.destination.resolve()
    dest.mkdir(parents=True, exist_ok=False)
    work = dest / 'work'
    work.mkdir()
    def git(*argv):
        result = subprocess.run(['git', '-C', str(root), *argv], capture_output=True)
        if result.stderr:
            with (dest / 'git-diagnostics.log').open('ab') as log:
                log.write(result.stderr)
        if result.returncode:
            raise subprocess.CalledProcessError(result.returncode, result.args,
                                                result.stdout, result.stderr)
        return result.stdout
    (dest / 'tracked.patch').write_bytes(git('diff', 'HEAD', '--binary'))
    (dest / 'git-status.txt').write_bytes(git('status', '--short', '--branch'))
    # Capture whole source directories, including generated PLL/Qsys inputs.
    # Exclude only build caches; never substitute a clean HEAD for dirty RTL.
    ignore = shutil.ignore_patterns('.git', '__pycache__', 'build', 'db',
                                   'incremental_db', 'obj_dir')
    for directory in ('rtl', 'sys', 'vendor', 'scripts', 'sim', 'SW'):
        shutil.copytree(root / directory, work / directory, ignore=ignore)
    shutil.copytree(root / 'tests' / 'firmware', work / 'tests' / 'firmware')
    for src in root.iterdir():
        if src.is_file() and src.suffix.lower() in (
                '.sv', '.v', '.vh', '.qsf', '.qpf', '.qip', '.sdc', '.tcl',
                '.mif', '.mem', '.hex'):
            shutil.copy2(src, work / src.name)
    source_files = {str(p.relative_to(work)): digest(p)
                    for p in sorted(work.rglob('*')) if p.is_file()}
    fit_files = {}
    if args.with_fit:
        for directory in ('db', 'incremental_db'):
            source = root / directory
            if source.exists():
                shutil.copytree(source, work / directory)
        # QSF is authoritative; output directory names need not match revision.
        import re
        qsf = (root / (args.revision + '.qsf')).read_text()
        match = re.search(r'-name PROJECT_OUTPUT_DIRECTORY\s+([^\s]+)', qsf)
        if not match:
            raise RuntimeError('No explicit PROJECT_OUTPUT_DIRECTORY in revision')
        output = root / match.group(1).strip('"')
        shutil.copytree(output, work / output.name)
        for p in sorted((work / output.name).rglob('*')):
            if p.is_file():
                fit_files[str(p.relative_to(work))] = digest(p)
        for p in sorted((work / 'db').glob(args.revision + '.cmp.*')):
            if p.is_file():
                fit_files[str(p.relative_to(work))] = digest(p)
    manifest = dict(created_utc=datetime.now(timezone.utc).isoformat(),
                    source_root=str(root), revision=args.revision,
                    head=git('rev-parse', 'HEAD').decode().strip(),
                    branch=git('branch', '--show-current').decode().strip(),
                    source_sha256=source_files, fit_sha256=fit_files,
                    identity_note=('Existing fit and current sources recorded separately; '
                                   'no claim that this older fit was built from this HEAD.'
                                   if args.with_fit else 'Inputs frozen before compilation.'))
    (dest / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'P05_SNAPSHOT {dest} sources={len(source_files)} fit_files={len(fit_files)}', flush=True)


if __name__ == '__main__':
    main()
