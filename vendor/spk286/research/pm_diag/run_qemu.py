"""Run a diagnostic floppy headlessly and retain the full port-E9 transcript.

QEMU uses a later CPU, not a physical 286 oracle. This checks the executable
mechanics and reports literal-ROM compatibility separately.
"""
import argparse
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path


def run(qemu, image, output, seconds=15):
    output.mkdir(parents=True, exist_ok=True)
    log = output/'debug.log'
    log.write_text('', encoding='ascii')
    command = [str(qemu), '-machine', 'pc', '-accel', 'tcg', '-cpu', '486',
               '-m', '16', '-display', 'none', '-serial', 'none', '-monitor', 'stdio',
               '-no-reboot', '-no-shutdown', '-boot', 'a',
               '-drive', f'file={image.resolve()},format=raw,if=floppy,readonly=on',
               '-debugcon', f'file:{log.resolve()}', '-global', 'isa-debugcon.iobase=0xe9']
    flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
    started = time.monotonic()
    with (output/'stderr.log').open('wb') as errors:
        proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=errors,
                                stderr=errors, creationflags=flags)
        try:
            while time.monotonic()-started < seconds and proc.poll() is None:
                transcript = log.read_text(errors='replace')
                if 'Task counters A/B' in transcript and transcript.endswith('\n'):
                    break
                time.sleep(.1)
            if proc.poll() is None:
                screenshot = output.resolve()/'screen.png'
                proc.stdin.write(f'screendump "{screenshot.as_posix()}" -f png\n'.encode())
                proc.stdin.flush()
                capture_started = time.monotonic()
                while not screenshot.exists() and time.monotonic()-capture_started < 2:
                    time.sleep(.05)
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)
    transcript = log.read_text(errors='replace')
    result = {'emulator': subprocess.check_output([str(qemu), '--version'], text=True).splitlines()[0],
              'cpu': '486 (not a 286 oracle)',
              'image_sha256': hashlib.sha256(image.read_bytes()).hexdigest(),
              'complete': 'COMPLETE failures=0000' in transcript,
              'fail': ' FAIL ' in transcript, 'exception': ' EXCEPTION ' in transcript,
              'elapsed_seconds': round(time.monotonic()-started, 2), 'command': command}
    (output/'result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(transcript)
    print(json.dumps(result, indent=2))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qemu', type=Path, required=True)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=15)
    args = parser.parse_args()
    result = run(args.qemu, args.image, args.output, args.seconds)
    raise SystemExit(0 if result['complete'] else 1)
