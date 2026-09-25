#!/usr/bin/env python3
"""Check the real scaler's coefficient stream and adaptive metadata CDC."""
from pathlib import Path
import sys

signals = set('poly_clk o_clk poly_wr at_poly_active poly_wr_mode poly_a poly_a2 poly_tdw '
              'o_h_poly_adaptive o_v_poly_adaptive poly_adaptive_local o_run o_vsv '
              'o_hmode o_vmode o_h_poly_use_adaptive o_v_poly_use_adaptive '
              'o_r o_g o_b o_de o_brd'.split())
mail_signals = set('payload_q req_q ack_q ack_sync dst_data'.split())
signals.update('mail_'+s for s in mail_signals)
scope, names, values = [], {}, {}
counts = dict(words=0, ram_writes=0, transactions=0, publications=0, captures=0)
banks = {i: 0 for i in range(4)}
applied = []
pixels = {i: 0 for i in range(3)}
pipeline_bank = None
last_publication = None
capture_delays = []


def verify(before, after, time):
    global pipeline_bank, last_publication
    def n(key, old=False):
        return (before if old else after).get(key)
    def rise(key):
        return n(key, True) == 0 and n(key) == 1
    def changed(key):
        return n(key, True) is not None and n(key) != n(key, True)
    if not time:
        return
    if changed('at_poly_active') and n('at_poly_active') == 0:
        counts['transactions'] += 1
    if rise('poly_clk'):
        mode = n('poly_wr_mode', True)
        if pipeline_bank is not None:
            assert mode == (1 if pipeline_bank % 2 == 0 else 2) + (4 if pipeline_bank >= 2 else 0), (time, 'write pipeline bank')
            counts['ram_writes'] += 1
            banks[pipeline_bank] += 1
        else:
            assert mode in (None, 0), (time, 'spurious coefficient write')
        pipeline_bank = n('poly_a', True) // 1024 if n('poly_wr', True) == 1 else None
        if pipeline_bank is not None:
            counts['words'] += 1
        # Changes in either flag at the writer must follow the actual RAM bank.
        if mode in (1, 5):
            assert n('o_h_poly_adaptive') == (mode == 5), (time, 'horizontal writer flag')
        if mode in (2, 6):
            assert n('o_v_poly_adaptive') == (mode == 6), (time, 'vertical writer flag')
        if changed('mail_req_q'):
            assert n('at_poly_active', True) == 0 and n('poly_wr', True) == 0 and mode == 0, (time, 'partial transaction published')
            pair = n('o_h_poly_adaptive', True) + 2*n('o_v_poly_adaptive', True)
            assert n('mail_payload_q') == pair, (time, 'incoherent adaptive pair')
            counts['publications'] += 1
            last_publication = time
        if n('mail_req_q', True) != n('mail_ack_sync', True):
            assert n('mail_payload_q') == n('mail_payload_q', True), (time, 'payload changed before acknowledgement')
    if rise('o_clk'):
        if changed('mail_ack_q'):
            assert n('mail_dst_data') == n('mail_payload_q', True), (time, 'wrong captured pair')
            counts['captures'] += 1
            assert last_publication is not None, (time, 'capture without publication')
            capture_delays.append(time-last_publication)
        if changed('poly_adaptive_local'):
            vs = n('o_vsv', True)
            blank_edge = vs is not None and bool(vs & (1 << 10)) and not bool(vs & (1 << 11))
            assert n('o_run', True) == 0 or blank_edge, (time, 'adaptive flags changed during visible raster')
            assert n('poly_adaptive_local') == n('mail_dst_data', True), (time, 'apply bypassed mailbox')
            applied.append(n('poly_adaptive_local'))
        local = n('poly_adaptive_local', True)
        for axis, bit in [('h', 0), ('v', 1)]:
            mode = n(f'o_{axis}mode', True)
            if mode is not None and local is not None:
                assert n(f'o_{axis}_poly_use_adaptive') == int(bool(mode & 7) and bool(local & (1 << bit))), (time, axis, 'adaptive consumer bypasses local configuration')
        if time > 200_000_000_000 and n('o_de') == 1 and n('o_brd') == 0:
            if (n('o_r'), n('o_g'), n('o_b')) == (85, 85, 85):
                pixels[n('poly_adaptive_local')] += 1


with Path(sys.argv[1]).open() as stream:
    for line in stream:
        parts = line.split()
        if not parts:
            continue
        if parts[0] == '$scope':
            scope.append(parts[2])
        elif parts[0] == '$upscope':
            scope.pop()
        elif parts[0] == '$var':
            name = parts[4].split('[')[0]
            if scope == ['at_scaler_avalon_tb', 'dut'] and name in signals:
                names[parts[3]] = name
            elif scope == ['at_scaler_avalon_tb', 'dut', 'g_at_poly_control', 'poly_adaptive_config'] and name in mail_signals:
                names[parts[3]] = 'mail_'+name
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

assert counts['words'] == counts['ram_writes'] == 8192, counts
assert banks == {0: 3072, 1: 3072, 2: 1024, 3: 1024}, banks
assert counts['transactions'] == 4 and applied == [1, 2, 0], (counts, applied)
assert all(pixels[i] > 100 for i in range(3)), pixels
assert capture_delays and min(capture_delays) > 5_000_000, 'Payload lacks the 5 ns SDC settling margin'
print('AT_SCALER_FILTER_PASS', counts, 'banks=', banks,
      'applied=', applied, 'identity_pixels=', pixels,
      f'min_capture_ns={min(capture_delays)/1e6:.3f}',
      'partial_transaction=1 source_pause=1 receiver_pause=1')
