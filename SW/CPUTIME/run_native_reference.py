#!/usr/bin/env python3
"""Run T286REF on an owned Linux 86Box native-286 process and private DOS disk.

Requires pyfatfs and an unstripped local 86Box reference executable. The input
disk, reference executable, profile and ROMs are read only. Keyboard requests
are explicit control.json files, used only to acknowledge observed BIOS screens.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import shutil
import signal
import struct
import subprocess
import time
import warnings

from pyfatfs.PyFatFS import PyFatFS
from validate_t286ref import validate_csv


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fat(image, writable=False):
    with image.open('rb') as stream:
        sector = stream.read(512)
    if sector[510:512] != b'\x55\xaa' or sector[450] not in (1, 4, 6, 14):
        raise ValueError('Expected a DOS FAT partition in the first MBR entry')
    return PyFatFS(str(image), offset=struct.unpack_from('<I', sector, 454)[0]*512,
                   read_only=not writable)


class Keyboard(ctypes.Structure):
    # Local 86Box src/include/86box/keyboard.h atkbc_dev_t through ignore.
    _fields_ = [('name', ctypes.c_void_p)] + [(n, ctypes.c_uint8) for n in
        ('type', 'command', 'last_scan_code', 'state', 'resolution', 'rate',
         'cmd_queue_start', 'cmd_queue_end', 'queue_start', 'queue_end')] + [
        ('flags', ctypes.c_uint16), ('cmd_queue', ctypes.c_uint8*16),
        ('queue', ctypes.c_uint8*64)] + [(n, ctypes.c_int) for n in
        ('fifo_mask', 'mode', 'x', 'y', 'z', 'b', 'ignore')]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--disk', type=Path, required=True)
    p.add_argument('--profile', type=Path, required=True)
    p.add_argument('--program', type=Path, required=True)
    p.add_argument('--exe', type=Path, required=True)
    p.add_argument('--roms', type=Path, required=True)
    p.add_argument('--hz', type=int, choices=(6000000, 12500000), required=True)
    p.add_argument('--memory-wait-states', type=int, choices=(0, 1, 2),
        help='Visible 86Box wait-state count; omitted means Automatic (config 0)')
    p.add_argument('--seconds', type=int, default=300)
    a = p.parse_args()
    waitstates_config = 0 if a.memory_wait_states is None else a.memory_wait_states+1
    out, source = a.output.resolve(), a.disk.resolve()
    if out.exists():
        p.error('Use a fresh output directory; results cannot be overwritten')
    out.mkdir(parents=True)
    source_hash = sha(source)
    label = '6' if a.hz == 6000000 else '12.5'
    image = out/'dos-test.img'
    shutil.copyfile(source, image)
    warnings.filterwarnings('ignore', category=UserWarning, module='pyfatfs')
    fs = fat(image, True)
    try:
        fs.makedirs('/CPUTIME', recreate=True)
        fs.makedirs('/RESULTS', recreate=True)
        for n in fs.listdir('/RESULTS'):
            if fs.isfile('/RESULTS/'+n):
                fs.remove('/RESULTS/'+n)
        fs.writebytes('/CPUTIME/T286REF.COM', a.program.read_bytes())
        fs.writebytes('/CONFIG.SYS', b'FILES=20\r\nBUFFERS=10\r\n')
        batch = ('@ECHO OFF\r\nCD \\CPUTIME\r\n'
                 'ECHO BEGIN>C:\\RESULTS\\STATUS.TXT\r\n'
                 f'T286REF {label} > C:\\RESULTS\\REF.CSV\r\n'
                 'IF ERRORLEVEL 1 GOTO ERROR\r\n'
                 'ECHO RC0>>C:\\RESULTS\\STATUS.TXT\r\nGOTO DONE\r\n'
                 ':ERROR\r\nECHO NONZERO>>C:\\RESULTS\\STATUS.TXT\r\n'
                 ':DONE\r\nECHO ALL_DONE>>C:\\RESULTS\\STATUS.TXT\r\n')
        fs.writebytes('/AUTOEXEC.BAT', batch.encode('ascii'))
    finally:
        fs.close()
    cfg = (a.profile/'86box.cfg').read_text()
    cfg = re.sub(r'^cpu_speed\s*=.*$', f'cpu_speed = {a.hz}', cfg, flags=re.M)
    cfg = re.sub(r'^hdd_01_fn\s*=.*$', 'hdd_01_fn = dos-test.img', cfg, flags=re.M)
    cfg = re.sub(r'^cpu_waitstates[ \t]*=.*\n?', '', cfg, flags=re.M)
    assert cfg.count('[Machine]\n') == 1
    cfg = cfg.replace('[Machine]\n', f'[Machine]\ncpu_waitstates = {waitstates_config}\n', 1)
    assert re.search(r'^cpu_family\s*=\s*286\s*$', cfg, re.M)
    assert re.search(r'^cpu_use_dynarec\s*=\s*0\s*$', cfg, re.M)
    assert re.search(rf'^cpu_waitstates[ \t]*=[ \t]*{waitstates_config}$', cfg, re.M)
    (out/'86box.cfg').write_text(cfg)
    (out/'global.cfg').write_text('')
    shutil.copytree(a.profile/'nvr', out/'nvr')
    shutil.copytree(a.profile/'nvr', out/'nvr-initial')
    exe = out/'86Box-native'
    shutil.copy2(a.exe, exe)
    listing = subprocess.check_output(['nm', '-S', str(exe)], text=True)
    names = ('ram', 'cpu_s', 'cpu_exec', 'exec386_2386', 'cpu_waitstates',
             'cpu_prefetch_cycles', 'cpu_cycles_read', 'cpu_cycles_write',
             'cpu_isa_speed', 'isa_cycles', 'timing_rr', 'tsc',
             'SavedKbd', 'keyboard_mode', 'keyboard_scan',
             'cpu_cache_int_enabled', 'cpu_cache_ext_enabled')
    symbols = {n: int(next(l.split()[0] for l in listing.splitlines()
                          if l.endswith(' '+n)), 16) for n in names}
    master, slave = pty.openpty()
    env = dict(os.environ, SDL_VIDEODRIVER='offscreen', SDL_AUDIODRIVER='dummy',
               ALSOFT_DRIVERS='null')
    command = [str(exe), '-P', str(out), '-O', str(out/'global.cfg'), '-R',
               str(a.roms.resolve()), '-L', str(out/'86box.log'), '-V', 'T286REF '+label]
    proc = subprocess.Popen(command, cwd=out, env=env, stdin=slave, stdout=slave,
                            stderr=subprocess.STDOUT)
    os.close(slave)
    os.set_blocking(master, False)
    log = (out/'console.log').open('wb')
    receipt = dict(hz=a.hz, cpu_label=label,
        requested_visible_wait_states=a.memory_wait_states,
        cpu_waitstates_config=waitstates_config, binary_sha256=sha(exe),
        program_sha256=sha(a.program), runner_sha256=sha(Path(__file__)),
        validator_sha256=sha(Path(__file__).with_name('validate_t286ref.py')),
        source_disk_sha256=source_hash, image_sha256_before=sha(image),
        initial_config_sha256=sha(out/'86box.cfg'),
        initial_nvr_sha256={f.name:sha(f) for f in (out/'nvr-initial').iterdir()},
        command=command, pid=proc.pid, samples=[], keyboard_events=[])
    (out/'start.json').write_text(json.dumps(receipt, indent=2)+'\n')
    (out/'pid').write_text(str(proc.pid))

    def send(value):
        os.write(master, (value+'\n').encode())

    def drain():
        try:
            while True:
                data = os.read(master, 65536)
                if not data:
                    break
                log.write(data)
                log.flush()
        except (BlockingIOError, OSError):
            pass

    def sample(key=None):
        os.kill(proc.pid, signal.SIGSTOP)
        try:
            for _ in range(200):
                states = [f.read_text().split('State:', 1)[1].splitlines()[0].strip()
                          for f in Path(f'/proc/{proc.pid}/task').glob('*/status')]
                if states and all(s.startswith('T') for s in states):
                    break
                time.sleep(.005)
            else:
                raise RuntimeError('Could not stop every owned emulator thread')
            maps = Path(f'/proc/{proc.pid}/maps').read_text().splitlines()
            base = int(next(l.split('-')[0] for l in maps
                            if l.endswith(str(exe)) and l.split()[2]=='00000000'), 16)
            fd = os.open(f'/proc/{proc.pid}/mem', os.O_RDWR if key else os.O_RDONLY)
            try:
                def integer(addr, size):
                    data = os.pread(fd, size, addr)
                    assert len(data)==size
                    return int.from_bytes(data, 'little')
                cpu = integer(base+symbols['cpu_s'], 8)
                if not cpu:
                    assert key is None, 'Cannot inject keys before CPU initialization'
                    return None
                state = {n:integer(base+symbols[n], 4) for n in names[4:11]}
                state.update({n:integer(base+symbols[n], 4) for n in
                    ('cpu_cache_int_enabled', 'cpu_cache_ext_enabled')})
                state.update(cpu_hz_actual=integer(cpu+24, 4),
                    dispatcher=integer(base+symbols['cpu_exec'], 8)-base,
                    tsc=integer(base+symbols['tsc'], 8))
                if state['dispatcher']==-base and state['tsc']==0:
                    assert key is None, 'Cannot inject keys before native dispatch initialization'
                    return None
                assert state['cpu_hz_actual']==a.hz
                assert state['dispatcher']==symbols['exec386_2386'], (state, symbols['exec386_2386'])
                assert state['cpu_waitstates']==waitstates_config
                if a.memory_wait_states is not None:
                    assert state['cpu_cache_int_enabled']==state['cpu_cache_ext_enabled']==0
                    assert state['cpu_prefetch_cycles']==state['cpu_cycles_read']==state['cpu_cycles_write']==a.memory_wait_states+2
                if key:
                    pointer = integer(base+symbols['SavedKbd'], 8)
                    mode = integer(base+symbols['keyboard_mode'], 1)&3
                    assert pointer and integer(base+symbols['keyboard_scan'], 4)
                    kbd = Keyboard.from_buffer_copy(os.pread(fd, ctypes.sizeof(Keyboard), pointer))
                    assert mode in (1, 2) and kbd.fifo_mask in (15, 31, 63)
                    code = (0x1c if mode==1 else 0x5a) if key=='enter' else (0x44 if mode==1 else 0x09)
                    payload = [code, code|0x80] if mode==1 else [code, 0xf0, code]
                    used = (kbd.queue_end-kbd.queue_start)&kbd.fifo_mask
                    assert used+len(payload)<=kbd.fifo_mask
                    tail = kbd.queue_end
                    for byte in payload:
                        os.pwrite(fd, bytes([byte]), pointer+Keyboard.queue.offset+tail)
                        tail = (tail+1)&kbd.fifo_mask
                    os.pwrite(fd, bytes([tail]), pointer+Keyboard.queue_end.offset)
                    os.pwrite(fd, b'\0'*4, pointer+Keyboard.ignore.offset)
                    receipt['keyboard_events'].append(dict(key=key, payload=payload,
                        mode=mode, host_elapsed_seconds=round(time.monotonic()-started, 3)))
                return state
            finally:
                os.close(fd)
        finally:
            os.kill(proc.pid, signal.SIGCONT)

    def results():
        fs = fat(image)
        try:
            result = {}
            for n in fs.listdir('/RESULTS'):
                if fs.isfile('/RESULTS/'+n):
                    data = fs.readbytes('/RESULTS/'+n)
                    (out/n).write_bytes(data)
                    result[n] = data.decode('cp437')
            return result
        finally:
            fs.close()

    started = time.monotonic()
    next_sample, fast, completed, failure = 8, False, False, None
    print('START', a.hz, proc.pid, out, flush=True)
    try:
        while proc.poll() is None:
            drain()
            elapsed = time.monotonic()-started
            if elapsed>=2 and not fast:
                send('fastfwd')
                fast = True
            control = out/'control.json'
            if control.exists():
                value = json.loads(control.read_text())
                control.unlink()
                if 'key' in value:
                    assert value['key'] in ('enter', 'f10')
                    sample(value['key'])
                if value.get('screenshot'):
                    send('screenshot')
            if elapsed>=next_sample:
                next_sample = elapsed+5
                state = sample()
                if state is None:
                    next_sample = elapsed+1
                    receipt.setdefault('startup_probes', []).append(round(elapsed, 3))
                    print('STARTUP native CPU dispatcher not initialized', flush=True)
                else:
                    state['host_elapsed_seconds'] = round(elapsed, 3)
                    receipt['samples'].append(state)
                    (out/'samples.json').write_text(json.dumps(receipt['samples'], indent=2)+'\n')
                    result = results()
                    print('STATE', json.dumps(state), 'STATUS', repr(result.get('STATUS.TXT', '')), flush=True)
                    if 'ALL_DONE' in result.get('STATUS.TXT', ''):
                        completed = True
                        break
            if elapsed>=a.seconds:
                failure = 'host_time_limit'
                break
            time.sleep(.2)
    except Exception as error:
        failure = repr(error)
        raise
    finally:
        if proc.poll() is None:
            if completed:
                receipt['teardown_policy'] = 'pause_after_guest_completion_then_exit'
                send('pause')
                time.sleep(.5)
                drain()
            send('exit')
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.terminate()
                proc.wait(timeout=10)
        drain()
        log.close()
        os.close(master)
        result = results()
        validated = None
        if completed and 'RC0' in result.get('STATUS.TXT', ''):
            try:
                validated = validate_csv(result.get('REF.CSV', ''), label)
            except (ValueError, UnicodeError) as error:
                failure = 'csv_validation: '+str(error)
        assert sha(a.program)==receipt['program_sha256'], 'Program changed during run'
        assert sha(exe)==receipt['binary_sha256'], 'Executable changed during run'
        assert sha(Path(__file__))==receipt['runner_sha256'], 'Runner changed during run'
        assert sha(Path(__file__).with_name('validate_t286ref.py'))==receipt['validator_sha256'], 'Validator changed during run'
        receipt.update(completed=completed, failure=failure,
            emulator_returncode=proc.returncode,
            guest_success=validated is not None, csv_validation=validated,
            guest_output=result, image_sha256_after=sha(image),
            host_elapsed_seconds=round(time.monotonic()-started, 3),
            source_disk_sha256_after=sha(source))
        assert receipt['source_disk_sha256_after']==source_hash
        (out/'measurement.json').write_text(json.dumps(receipt, indent=2)+'\n')
        print('FINISH', receipt['guest_success'], out, flush=True)
    if not receipt['guest_success'] or proc.returncode!=0:
        raise SystemExit(1)


if __name__=='__main__':
    main()
