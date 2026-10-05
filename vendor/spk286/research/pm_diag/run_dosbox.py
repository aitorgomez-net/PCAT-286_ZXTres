"""DOS loader/output smoke in DOSBox-X's dummy SDL driver, never PM validation."""
import argparse
import os
import subprocess
from pathlib import Path


def run(executable, directory):
    directory = directory.resolve()
    config = directory / 'smoke.conf'
    config.write_text('[sdl]\noutput=surface\nfullscreen=false\n'
                      '[cpu]\ncore=normal\ncputype=286\ncycles=fixed 12000\n'
                      '[mixer]\nnosound=true\n'
                      '[autoexec]\n@echo off\n'
                      f'mount c "{directory}"\nc:\n'
                      'pm286 /s > smoke286.txt\npmrom /s > smokerom.txt\nexit\n',
                      encoding='utf-8')
    env = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy')
    flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
    with (directory/'dosbox.log').open('wb') as log:
        subprocess.run([executable, '-conf', str(config), '-noconsole', '-fastlaunch'],
                       env=env, stdout=log, stderr=log, timeout=45,
                       creationflags=flags, check=True)
    for name in ('SMOKE286.TXT', 'SMOKEROM.TXT'):
        matches = [p for p in directory.iterdir() if p.name.upper() == name]
        if not matches or 'PM286 UI SMOKE PASS' not in matches[0].read_text(errors='replace'):
            raise RuntimeError(f'Missing successful DOS smoke: {name}')
        print(matches[0].read_text(errors='replace'))
    print('DOSBOX_X_DOS_SMOKE_PASS (no protected-mode validation)')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dosbox', required=True)
    parser.add_argument('--directory', required=True, type=Path)
    args = parser.parse_args()
    run(args.dosbox, args.directory)
