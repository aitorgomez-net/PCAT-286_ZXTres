"""Run a diagnostic floppy in a private terminal-backed Bochs process on Linux."""
import argparse
import fcntl
import hashlib
import json
import os
import pty
import struct
import subprocess
import termios
import time
from pathlib import Path


def run(prefix, image, output, seconds=20):
    prefix, image, output = prefix.resolve(), image.resolve(), output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    config = output/'bochsrc'
    config.write_text(f'romimage: file={prefix}/usr/share/bochs/BIOS-bochs-legacy\n'
                      f'vgaromimage: file={prefix}/usr/share/vgabios/vgabios.bin\n'
                      'megs: 16\nboot: a\ndisplay_library: term\n'
                      'cpu: model=pentium, ips=10000000, reset_on_triple_fault=0\n'
                      f'floppya: 1_44={image}, status=inserted\n'
                      f'log: {output}/bochs.log\n'
                      'panic: action=fatal\nerror: action=report\n'
                      'info: action=report\ndebug: action=ignore\n'
                      'port_e9_hack: enabled=1\n', encoding='utf-8')
    rc = output/'debugger.rc'
    rc.write_text('c\n', encoding='ascii')
    executable = prefix/'usr/bin/bochs-bin'
    env = dict(os.environ, TERM='xterm',
               LTDL_LIBRARY_PATH=str(prefix/'usr/lib/x86_64-linux-gnu/bochs/plugins'))
    command = ['stdbuf', '-oL', str(executable), '-q', '-f', str(config), '-rc', str(rc)]
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 25, 80, 0, 0))
    started = time.monotonic()
    trace = output/'console.log'
    with trace.open('wb') as log, (output/'stderr.log').open('wb') as errors:
        proc = subprocess.Popen(command, env=env, stdin=slave, stdout=log, stderr=errors)
        try:
            while proc.poll() is None and time.monotonic()-started < seconds:
                if 'Task counters A/B (expected 0019/0019):' in trace.read_text(errors='replace'):
                    time.sleep(.2)
                    break
                time.sleep(.1)
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
            os.close(master)
            os.close(slave)
    text = trace.read_text(errors='replace')
    result = {'emulator': 'Bochs (see bochs.log)', 'cpu': 'Pentium (not a physical 286 oracle)',
              'complete': 'COMPLETE failures=0000' in text,
              'image_sha256': hashlib.sha256(image.read_bytes()).hexdigest(),
              'elapsed_seconds': round(time.monotonic()-started, 2), 'command': command}
    (output/'result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(text[-4000:])
    print(json.dumps(result, indent=2))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', required=True, type=Path)
    parser.add_argument('--image', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = run(args.prefix, args.image, args.output)
    raise SystemExit(0 if result['complete'] else 1)
