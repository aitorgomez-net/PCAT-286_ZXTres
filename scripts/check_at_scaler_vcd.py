#!/usr/bin/env python3
"""Scoreboard real scaler source commands against accepted Avalon transactions.

Also check payload hold windows and event synchronizer sequencing. Digital
simulation does not model metastability or replace post-fit timing analysis.
"""
from collections import deque
from pathlib import Path
import sys

signals = {
    'i_clk', 'o_clk', 'avl_clk', 'i_reset_na', 'o_reset_na', 'avl_reset_na',
    'i_write', 'i_wadrs', 'i_wbase', 'i_walt', 'i_wline_mem',
    'cdc_i_ibuf0', 'cdc_i_ibuf1', 'o_read_pre', 'o_read_pending', 'o_readack',
    'o_read_address_q', 'o_read_base_q', 'o_adrs', 'o_rline', 'o_obuf0', 'o_obuf1',
    'o_frame_base_q', 'cdc_o_fb_ena', 'avl_read', 'avl_write', 'avl_waitrequest',
    'avl_address', 'avl_wadrs', 'avl_wbase', 'avl_walt', 'avl_radrs', 'avl_rbase',
}
pipes = [
    ('avl_clk', 'avl_reset_na', 'avl_write_sync', 'avl_write_sync2', 'avl_write_seen', 'avl_write_pulse'),
    ('avl_clk', 'avl_reset_na', 'avl_read_sync', 'avl_read_sync2', 'avl_read_seen', 'avl_read_pulse'),
    ('o_clk', 'o_reset_na', 'o_readack_sync', 'o_readack_sync2', 'o_readack_seen', 'o_readack'),
    ('o_clk', 'o_reset_na', 'o_readdataack_sync', 'o_readdataack_sync2', 'o_readdataack_seen', 'o_readdataack'),
]
for pipe in pipes:
    signals.update(pipe)
source_reads, source_writes, reads, writes = (deque() for _ in range(4))
counts = dict(reads=0, writes=0, sync_edges=0, held_reads=0)
banks, read_bases = set(), set()
capture_delays = []
write_intervals = []
last_write_time = None
write_beat = 0
scope, names, values = [], {}, {}


def verify(before, after, time):
    global last_write_time, write_beat
    def n(key, old=False):
        return (before if old else after).get(key)
    def rise(key):
        return n(key, True) == 0 and n(key) == 1
    def changed(key):
        return n(key, True) is not None and n(key) != n(key, True)
    def tup(keys, old=False):
        return tuple(n(k, old) for k in keys.split())
    if not time:
        return
    for clk, reset, meta, sync, seen, pulse in pipes:
        if rise(clk) and n(reset, True) == 1:
            assert n(sync) == n(meta, True), (time, sync)
            assert n(seen) == n(sync, True), (time, seen)
            a, b = n(sync, True), n(seen, True)
            if a is not None and b is not None:
                assert n(pulse) == a ^ b, (time, pulse, 'event bypasses stage two')
            counts['sync_edges'] += 1
    if n('i_reset_na') == 1 and changed('i_write'):
        command = tup('i_wadrs i_wbase i_walt')
        assert None not in command or time < 100_000_000_000, (time, 'unknown command after startup')
        bank = n('cdc_i_ibuf0' if n('i_wline_mem', True) == 0 else 'cdc_i_ibuf1', True)
        assert command[1] == 0x20000000 + bank * 0x800000, (time, 'write bank')
        assert not source_writes, (time, 'write payload overwritten before capture')
        source_writes.append((command, time))
        if last_write_time is not None:
            write_intervals.append(time-last_write_time)
        last_write_time = time
        banks.add(bank)
    if rise('o_clk') and n('o_reset_na', True) == 1:
        if n('o_read_pending', True) == 1 and n('o_readack', True) == 0:
            assert tup('o_read_address_q o_read_base_q') == tup('o_read_address_q o_read_base_q', True), (time, 'read payload changed before ack')
            counts['held_reads'] += 1
        if changed('o_read_pre'):
            command = tup('o_read_address_q o_read_base_q')
            if n('cdc_o_fb_ena', True):
                base = n('o_frame_base_q', True)
            else:
                bank = n('o_obuf0' if n('o_rline', True) == 0 else 'o_obuf1', True)
                base = 0x20000100 + bank * 0x800000
            assert command == (n('o_adrs', True), base), (time, 'read command not coherent')
            assert not source_reads, (time, 'read command overwritten')
            source_reads.append((command, time))
            read_bases.add(base)
    if rise('avl_clk') and n('avl_reset_na', True) == 1:
        if n('avl_write_pulse', True) == 1:
            command, launch = source_writes.popleft()
            assert tup('i_wadrs i_wbase i_walt', True) == command, (time, 'write payload not held')
            captured = tup('avl_wadrs avl_wbase avl_walt')
            masked = command[0] & 0x7fffff if command[0] is not None else None
            assert captured == (masked, command[1], command[2]), (time, 'write capture')
            writes.append((captured[0] + captured[1]) >> 4 if captured[0] is not None else None)
            capture_delays.append(time-launch)
        if n('avl_read_pulse', True) == 1:
            command, launch = source_reads.popleft()
            assert tup('avl_radrs avl_rbase') == command, (time, 'read capture')
            reads.append(sum(command) >> 4)
            capture_delays.append(time-launch)
        if n('avl_waitrequest', True) == 0:
            if n('avl_read', True) == 1:
                assert n('avl_address', True) == reads.popleft(), (time, 'wrong Avalon read address')
                counts['reads'] += 1
            if n('avl_write', True) == 1:
                assert writes and n('avl_address', True) == writes[0], (time, 'wrong Avalon write address')
                write_beat = (write_beat+1) % 16
                if not write_beat:
                    writes.popleft()
                    counts['writes'] += 1


with Path(sys.argv[1]).open() as stream:
    for line in stream:
        parts = line.split()
        if not parts:
            continue
        if parts[0] == '$scope':
            scope.append(parts[2])
        elif parts[0] == '$upscope':
            scope.pop()
        elif parts[0] == '$var' and scope == ['at_scaler_avalon_tb', 'dut']:
            name = parts[4].split('[')[0]
            if name in signals:
                names[parts[3]] = name
        elif parts[0] == '$enddefinitions':
            break
    assert set(names.values()) == signals, signals - set(names.values())
    before, time = {}, 0
    for line in stream:
        if line.startswith('#'):
            verify(before, values, time)
            before = values.copy()
            time = int(line[1:])
        elif line.startswith(('b', 'B')):
            value, key = line[1:].split()
            if key in names:
                values[names[key]] = int(value, 2) if set(value) <= {'0', '1'} else None
        elif line and line[0] in '01xXzZuU':
            key = line[1:].strip()
            if key in names:
                values[names[key]] = int(line[0]) if line[0] in '01' else None
    verify(before, values, time)

assert counts['reads'] > 100 and counts['writes'] > 100 and counts['held_reads'] > 1000, counts
assert banks == {0, 1, 2}, banks
assert {0x24000000, 0x24800000} <= read_bases, read_bases
assert min(capture_delays) > 10_000_000, 'Payload lacks the 10 ns SDC settling margin'
assert min(write_intervals) >= 6 * 17_460_000, 'Write stability contract violated'
assert not source_reads and not source_writes and not reads and not writes, 'Undrained commands'
print('AT_SCALER_SCOREBOARD_PASS', counts,
      f'min_capture_ns={min(capture_delays)/1e6:.3f}',
      f'min_write_hold_ns={min(write_intervals)/1e6:.3f}',
      'banks=0,1,2 framebuffer_bases=24000000,24800000')
